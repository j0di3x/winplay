// WinPlay: runs Windows games and apps on Apple silicon Macs through Wine + Apple D3DMetal (GPTK).
// Each program gets its own "bottle" (a Windows prefix cloned from a clean template).
// Build: see build.sh next to this file.
import SwiftUI
import AppKit
import IOKit
import IOKit.hid
import GameController
import UniformTypeIdentifiers

/// Looks a string up in the bundle's Localizable.strings (English text is the key).
func L(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

struct WinPlayError: LocalizedError {
    let text: String
    init(_ t: String) { text = t }
    var errorDescription: String? { text }
}

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent("Library/Application Support/WinPlay")
    static let wine = root.appendingPathComponent("wine")
    static let gptk = root.appendingPathComponent("gptk")
    static let template = root.appendingPathComponent("template")
    static let bottles = root.appendingPathComponent("bottles")
    static let downloads = root.appendingPathComponent("downloads")
    static let bin = root.appendingPathComponent("bin")
    static let logs = root.appendingPathComponent("logs")
}

// MARK: - Shell helpers

@discardableResult
func runScript(_ script: String, _ args: [String] = [], env: [String: String] = [:]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [Paths.bin.appendingPathComponent(script).path] + args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// APFS clone: an instant copy that shares disk space until either side changes.
func cloneItem(_ src: URL, to dst: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/cp")
    p.arguments = ["-cR", src.path, dst.path]
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

// MARK: - Bottles

struct Bottle: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// A Mac path (/Users/.../Game.exe) or a Windows path inside the bottle (C:\Program Files\...).
    var program: String
    var arguments = ""
    var metal4 = true
    var fpsCounter = false
    var d3dmetal = true
    var windowsVersion = "win10"
    var kind = "program"          // "program" or "steam"
    var added = Date()
    // Optional so bottle.json files from 0.1.0 still load.
    /// Set when this tile runs in another game's bottle (a second program an installer added there).
    var host: String? = nil
    /// Every .exe already seen in this bottle (Windows paths), so only new ones are offered.
    var knownPrograms: [String]? = nil
    /// Removed from the library, but its bottle was kept. Shown under Add → Removed games.
    var hidden: Bool? = nil

    var folder: URL { Paths.bottles.appendingPathComponent(id) }
    /// The folder of the bottle the program runs in: its own, or its host's.
    var bottleFolder: URL { host.map { Paths.bottles.appendingPathComponent($0) } ?? folder }
    var prefix: URL { bottleFolder.appendingPathComponent("prefix") }
    var cDrive: URL { prefix.appendingPathComponent("drive_c") }
    var log: URL { bottleFolder.appendingPathComponent("last-run.log") }
    var isHidden: Bool { hidden ?? false }
    var iconFile: URL { folder.appendingPathComponent("icon.png") }

    /// The program as a Mac file, wherever it lives (Mac path, or C:\ inside the bottle).
    var programFile: URL? {
        if program.hasPrefix("/") { return URL(fileURLWithPath: program) }
        let p = program.replacingOccurrences(of: "\\", with: "/")
        guard p.lowercased().hasPrefix("c:/") else { return nil }
        return cDrive.appendingPathComponent(String(p.dropFirst(3)))
    }
    var programExists: Bool { programFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? !program.isEmpty }

    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        try? e.encode(self).write(to: folder.appendingPathComponent("bottle.json"))
    }
    static func load(_ folder: URL) -> Bottle? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("bottle.json")) else { return nil }
        return try? d.decode(Bottle.self, from: data)
    }
}

// MARK: - Icons from .exe files

/// Reads the main icon out of a Windows .exe (its PE resources) and returns it as an image.
enum ExeIcon {
    static func image(for exe: URL) -> NSImage? {
        guard let d = try? Data(contentsOf: exe, options: .mappedIfSafe), d.count > 0x40 else { return nil }
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? u16(o) | u16(o + 2) << 16 : 0 }
        let pe = u32(0x3C)
        guard pe > 0, pe + 24 < d.count, u32(pe) == 0x4550 else { return nil }
        let sections = u16(pe + 6), optSize = u16(pe + 20), opt = pe + 24
        let dirs = opt + (u16(opt) == 0x20B ? 112 : 96)
        let resRVA = u32(dirs + 2 * 8)
        guard resRVA != 0 else { return nil }
        var table: [(va: Int, size: Int, raw: Int)] = []
        let sec = opt + optSize
        for i in 0..<sections {
            let s = sec + i * 40
            table.append((u32(s + 12), max(u32(s + 8), u32(s + 16)), u32(s + 20)))
        }
        func off(_ rva: Int) -> Int? {
            for t in table where rva >= t.va && rva < t.va + t.size { return rva - t.va + t.raw }
            return nil
        }
        guard let base = off(resRVA) else { return nil }
        // entries of a resource directory: (id, offset, isDirectory)
        func entries(_ dir: Int) -> [(id: Int, target: Int, isDir: Bool)] {
            let n = u16(dir + 12) + u16(dir + 14)
            return (0..<min(n, 4096)).map { i in
                let e = dir + 16 + i * 8
                let t = u32(e + 4)
                return (u32(e) & 0x7FFF_FFFF, t & 0x7FFF_FFFF, t & 0x8000_0000 != 0)
            }
        }
        /// first data blob under a type (and optionally a specific id)
        func data(type: Int, id: Int? = nil) -> Data? {
            guard let t = entries(base).first(where: { $0.id == type && $0.isDir }) else { return nil }
            let names = entries(base + t.target)
            guard let n = (id == nil ? names.first : names.first(where: { $0.id == id })), n.isDir,
                  let lang = entries(base + n.target).first, !lang.isDir else { return nil }
            let de = base + lang.target
            guard let o = off(u32(de)), o + u32(de + 4) <= d.count else { return nil }
            return d.subdata(in: o..<(o + u32(de + 4)))
        }
        guard let group = data(type: 14), group.count >= 6 else { return nil }   // RT_GROUP_ICON
        let g = [UInt8](group)
        let count = Int(g[4]) | Int(g[5]) << 8
        // pick the largest image
        var best: (w: Int, bits: Int, entry: Int)? = nil
        for i in 0..<count where 6 + i * 14 + 14 <= g.count {
            let e = 6 + i * 14
            let w = g[e] == 0 ? 256 : Int(g[e])
            let bits = Int(g[e + 6]) | Int(g[e + 7]) << 8
            if best == nil || w > best!.w || (w == best!.w && bits > best!.bits) { best = (w, bits, e) }
        }
        guard let b = best else { return nil }
        let iconID = Int(g[b.entry + 12]) | Int(g[b.entry + 13]) << 8
        guard let img = data(type: 3, id: iconID) else { return nil }        // RT_ICON
        // rebuild a one-image .ico that NSImage can read
        var ico = Data([0, 0, 1, 0, 1, 0])
        ico.append(contentsOf: g[b.entry..<(b.entry + 8)])
        withUnsafeBytes(of: UInt32(img.count).littleEndian) { ico.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(22).littleEndian) { ico.append(contentsOf: $0) }
        ico.append(img)
        return NSImage(data: ico)
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Library model

@MainActor
final class Library: ObservableObject {
    @Published var bottles: [Bottle] = []
    @Published var running: Set<String> = []
    @Published var icons: [String: NSImage] = [:]
    @Published var message = ""
    @Published var busy = false
    @Published var downloadTitle = ""
    @Published var downloadFraction = 0.0
    @Published var downloading = false

    // setup
    @Published var wineOK = false
    @Published var gptkVersion = ""
    @Published var templateOK = false

    /// Bottles removed from the library whose Windows setup was kept.
    @Published var keptBottles: [Bottle] = []
    /// New programs found in a bottle, waiting for the user to pick which to add.
    @Published var newPrograms: NewPrograms? = nil
    @Published var editing: Bottle? = nil

    // controllers
    @Published var devices: [InputDevice] = []

    private var processes: [String: Process] = [:]
    private var downloadTask: URLSessionDownloadTask?
    private var progressTimer: Timer?
    private var timer: Timer?

    var ready: Bool { wineOK && templateOK }

    init() {
        installScripts()
        refreshSetup()
        loadBottles()
        devices = ControllerScanner.scan()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.devices = ControllerScanner.scan() }
        }
    }

    func installScripts() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("scripts") else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.bin, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
            let dst = Paths.bin.appendingPathComponent(f)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src.appendingPathComponent(f), to: dst)
            chmod(dst.path, 0o755)
        }
    }

    func refreshSetup() {
        let fm = FileManager.default
        wineOK = fm.isExecutableFile(atPath: Paths.wine.appendingPathComponent("bin/wine").path)
        templateOK = fm.fileExists(atPath: Paths.template.appendingPathComponent("system.reg").path)
        let cur = Paths.gptk.appendingPathComponent("current")
        gptkVersion = fm.fileExists(atPath: cur.appendingPathComponent("external/libd3dshared.dylib").path)
            ? ((try? fm.destinationOfSymbolicLink(atPath: cur.path)) ?? "") : ""
    }

    func loadBottles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.bottles, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: Paths.bottles, includingPropertiesForKeys: nil)) ?? []
        let all = dirs.compactMap(Bottle.load).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        bottles = all.filter { !$0.isHidden }
        keptBottles = all.filter(\.isHidden)
        for b in all where icons[b.id] == nil { loadIcon(b) }
    }

    /// The bottle record that owns the Windows setup a tile runs in (may be a kept, hidden one).
    func owner(of b: Bottle) -> Bottle {
        guard let h = b.host else { return b }
        return (bottles + keptBottles).first { $0.id == h } ?? b
    }

    /// Tiles that run in `b`'s bottle (besides `b` itself).
    func guests(of b: Bottle) -> [Bottle] { (bottles + keptBottles).filter { $0.host == b.id } }

    private func store(_ b: Bottle) {
        b.save()
        if let i = bottles.firstIndex(where: { $0.id == b.id }) { bottles[i] = b }
        if let i = keptBottles.firstIndex(where: { $0.id == b.id }) { keptBottles[i] = b }
    }

    func loadIcon(_ b: Bottle) {
        if let img = NSImage(contentsOf: b.iconFile) { icons[b.id] = img; return }
        guard let exe = b.programFile else { return }
        Task.detached {
            guard let img = ExeIcon.image(for: exe), let png = ExeIcon.png(img) else { return }
            try? png.write(to: b.iconFile)
            await MainActor.run { self.icons[b.id] = NSImage(data: png) }
        }
    }

    func update(_ b: Bottle) {
        b.save()
        if let i = bottles.firstIndex(where: { $0.id == b.id }) {
            if bottles[i].program != b.program { try? FileManager.default.removeItem(at: b.iconFile); icons[b.id] = nil }
            if bottles[i].windowsVersion != b.windowsVersion { setWindowsVersion(b) }
            bottles[i] = b
        }
        loadIcon(b)
    }

    // MARK: setup

    func runSetup() {
        busy = true; message = L("Setting up Windows… (the first time takes about 30 seconds)")
        Task.detached {
            let (code, out) = runScript("setup-runtime.sh")
            await MainActor.run {
                self.busy = false
                let lines = out.split(whereSeparator: \.isNewline).map(String.init)
                self.message = code == 0 ? L("Ready. Add a Windows game or app.") : (lines.last ?? L("Setup failed."))
                self.refreshSetup()
            }
        }
    }

    func installGPTK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.message = L("Choose Apple's \"Evaluation environment for Windows games\" .dmg")
        panel.directoryURL = Paths.home.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; message = L("Installing GPTK…")
        Task.detached {
            let (code, out) = runScript("install-gptk.sh", [url.path])
            await MainActor.run {
                self.busy = false
                self.message = code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : L("GPTK install failed: %@", out)
                self.refreshSetup()
            }
        }
    }

    // MARK: adding programs

    private func newBottle(name: String, program: String, kind: String = "program") throws -> Bottle {
        guard ready else { throw WinPlayError(L("Finish setup first.")) }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        var b = Bottle(id: id, name: name, program: program, kind: kind)
        try FileManager.default.createDirectory(at: b.folder, withIntermediateDirectories: true)
        guard cloneItem(Paths.template, to: b.prefix) else {
            try? FileManager.default.removeItem(at: b.folder)
            throw WinPlayError(L("Couldn't create a Windows bottle."))
        }
        b.added = Date()
        b.knownPrograms = Library.programs(in: b).map { Library.windowsPath($0, in: b) }
        b.save()
        bottles.append(b)
        bottles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return b
    }

    static let exeTypes: [UTType] = [UTType(filenameExtension: "exe"), UTType(filenameExtension: "msi"),
                                     UTType(filenameExtension: "bat"), UTType(filenameExtension: "cmd")].compactMap { $0 }

    /// A game or app that's already installed or portable: just point at its .exe.
    func addProgram() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Library.exeTypes.filter { $0.preferredFilenameExtension != "msi" }
        panel.message = L("Choose the game's or app's .exe")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProgram(url)
    }

    @discardableResult
    func addProgram(_ url: URL) -> Bottle? {
        do {
            let b = try newBottle(name: Library.niceName(url), program: url.path)
            loadIcon(b)
            message = L("Added %@. Press Play.", b.name)
            return b
        } catch { message = error.localizedDescription; return nil }
    }

    /// Runs a Windows installer in a new bottle. When it closes, WinPlay offers the programs it added.
    func runInstaller() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Library.exeTypes
        panel.message = L("Choose the Windows installer (setup.exe or .msi)")
        panel.directoryURL = Paths.home.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runInstaller(url)
    }

    func runInstaller(_ url: URL) {
        do {
            let b = try newBottle(name: Library.niceName(url), program: "")
            update(b)
            message = L("Running the installer. Finish it in its window…")
            launch(b, program: url.path, extra: []) { [weak self] in
                self?.checkForNewPrograms(b, afterInstaller: true)
            }
        } catch { message = error.localizedDescription }
    }

    /// Looks for .exe files that appeared in a bottle since the last check (an installer, or a launcher
    /// like Steam that installs games) and asks which ones to add to the library.
    func checkForNewPrograms(_ tile: Bottle, afterInstaller: Bool = false, manual: Bool = false) {
        guard newPrograms == nil else { return }      // one question at a time; the next check finds the rest
        let o = owner(of: tile)
        Task.detached {
            let found = Library.programs(in: o)
            await MainActor.run {
                var o = self.owner(of: tile)
                let paths = found.map { Library.windowsPath($0, in: o) }
                guard let known = o.knownPrograms else {
                    // a bottle from WinPlay 0.1.0: remember what's there now, ask from the next time on
                    o.knownPrograms = paths; self.store(o); return
                }
                let inLibrary = Set(([o] + self.guests(of: o)).map { $0.program.lowercased() })
                let knownSet = Set(known.map { $0.lowercased() })
                let new = zip(found, paths).filter { !knownSet.contains($0.1.lowercased()) && !inLibrary.contains($0.1.lowercased()) }.map(\.0)
                if new.isEmpty {
                    if afterInstaller && o.program.isEmpty {
                        self.message = L("The installer didn't add a program. Choose one in the game's settings, or remove it.")
                    } else if manual {
                        self.message = L("No new programs in %@.", o.name)
                    }
                    return
                }
                self.newPrograms = NewPrograms(owner: o, candidates: Array(new.prefix(40)), afterInstaller: afterInstaller)
            }
        }
    }

    /// The user's answer to the "new programs" question.
    func addNewPrograms(_ chosen: [URL]) {
        guard let q = newPrograms else { return }
        newPrograms = nil
        var o = owner(of: q.owner)
        o.knownPrograms = Array(Set((o.knownPrograms ?? []) + q.candidates.map { Library.windowsPath($0, in: o) }))
        var rest = chosen
        // an installer's own tile has no program yet: the first pick becomes its program
        if o.program.isEmpty, let first = rest.first {
            rest.removeFirst()
            o.program = Library.windowsPath(first, in: o); o.name = Library.niceName(first)
            try? FileManager.default.removeItem(at: o.iconFile); icons[o.id] = nil
        }
        store(o)
        loadIcon(o)
        for u in rest { addGuest(u, in: o) }
        if chosen.isEmpty {
            message = o.program.isEmpty ? L("The installer didn't add a program. Choose one in the game's settings, or remove it.") : ""
        } else {
            message = chosen.count == 1 ? L("Added %@. Press Play.", Library.niceName(chosen[0]))
                                        : L("Added %ld programs to your library.", chosen.count)
        }
    }

    /// Adds a tile for a program that lives inside another game's bottle (and runs there).
    @discardableResult
    func addGuest(_ u: URL, in o: Bottle) -> Bottle {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        var g = Bottle(id: id, name: Library.niceName(u), program: Library.windowsPath(u, in: o))
        g.host = o.id
        g.metal4 = o.metal4; g.d3dmetal = o.d3dmetal; g.windowsVersion = o.windowsVersion; g.added = Date()
        try? FileManager.default.createDirectory(at: g.folder, withIntermediateDirectories: true)
        g.save()
        bottles.append(g)
        bottles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loadIcon(g)
        return g
    }

    // MARK: opening files from Finder

    static let shared = Library()

    /// Windows files opened with WinPlay (double-click, Open With, or dropped on the Dock icon).
    func open(files: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        for u in files { openFile(u) }
    }

    private func openFile(_ url: URL) {
        guard ready else { message = L("Finish setup first."); return }
        let path = url.standardizedFileURL.path
        // already in the library: just play it
        if let t = bottles.first(where: { $0.programFile?.standardizedFileURL.path == path }) { play(t); return }
        let ext = url.pathExtension.lowercased()
        // a program inside one of WinPlay's bottles: give it a tile in that bottle
        if ext != "msi", let o = (bottles + keptBottles).first(where: { $0.host == nil && path.hasPrefix($0.cDrive.path + "/") }) {
            play(addGuest(url, in: o)); return
        }
        switch ext {
        case "msi": runInstaller(url)
        case "bat", "cmd": if let b = addProgram(url) { play(b) }
        default:
            // an .exe can be an installer or the game itself; ask, with the likely answer first
            let n = url.deletingPathExtension().lastPathComponent.lowercased()
            let looksLikeInstaller = ["setup", "install", "installer"].contains(where: n.contains)
            let a = NSAlert()
            a.messageText = L("Open %@ with WinPlay", url.lastPathComponent)
            a.informativeText = L("Is it an installer, or the game or app itself? An installer runs in a new bottle, and WinPlay then offers what it installed.")
            let install = L("Run the installer"), add = L("Add as a game or app")
            for t in looksLikeInstaller ? [install, add] : [add, install] { a.addButton(withTitle: t) }
            a.addButton(withTitle: L("Cancel"))
            let r = a.runModal()
            guard r != .alertThirdButtonReturn else { return }
            let first = r == .alertFirstButtonReturn
            if first == looksLikeInstaller { runInstaller(url) } else if let b = addProgram(url) { play(b) }
        }
    }

    /// Makes WinPlay the app that opens .exe, .msi, .bat and .cmd files (macOS asks to confirm).
    func makeDefaultOpener() {
        let app = Bundle.main.bundleURL
        let types = ["com.microsoft.windows-executable", "com.microsoft.windows-installer", "com.microsoft.windows-batch-file"]
            .compactMap { UTType($0) }
        Task {
            var failed = false
            for t in types {
                do { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t) } catch { failed = true }
            }
            message = failed ? L("macOS didn't change the default app. You can also do it in Finder: Get Info → Open with → Change All.")
                             : L("WinPlay now opens .exe, .msi, .bat and .cmd files.")
        }
    }

    /// Programs in a bottle's Program Files folders (and the other usual install places), biggest first.
    nonisolated static func programs(in b: Bottle) -> [URL] {
        let fm = FileManager.default
        let skip = ["unins", "uninstall", "setup", "install", "crash", "report", "redist", "vcredist", "dxsetup",
                    "dotnet", "update", "helper", "launcherpatcher", "unitycrash", "ue4prereq", "easyanticheat_setup",
                    "steamwebhelper", "steamerrorreporter", "steamservice", "driverquery"]
        var roots = ["Program Files", "Program Files (x86)", "ProgramData", "Games"].map { b.cDrive.appendingPathComponent($0) }
        roots += ((try? fm.contentsOfDirectory(at: b.cDrive.appendingPathComponent("users"), includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("AppData/Local/Programs") }
        var out: [(URL, Int)] = []
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let u as URL in en where u.pathExtension.lowercased() == "exe" {
                let n = u.deletingPathExtension().lastPathComponent.lowercased()
                if skip.contains(where: { n.contains($0) }) { continue }
                let p = u.path
                if ["/Windows NT/", "/Internet Explorer/", "/Windows Media Player/", "/Common Files/"].contains(where: p.contains) { continue }
                // Steam's own files are its business; games it installs live in steamapps/common
                if p.contains("/Steam/") && !p.contains("/steamapps/common/") { continue }
                out.append((u, (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
                if out.count > 2000 { break }
            }
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The folder a program was installed into (C:\Program Files\<this>), to tell programs apart.
    static func installFolder(_ u: URL, in b: Bottle) -> String {
        let parts = Array(u.path.dropFirst(b.cDrive.path.count).split(separator: "/").map(String.init).dropLast())
        let roots: Set = ["program files", "program files (x86)", "programdata", "games", "programs", "common"]
        if let i = parts.lastIndex(where: { roots.contains($0.lowercased()) }), i + 1 < parts.count { return parts[i + 1] }
        return parts.last ?? ""
    }

    static func windowsPath(_ url: URL, in b: Bottle) -> String {
        let c = b.cDrive.path
        guard url.path.hasPrefix(c) else { return url.path }
        return "C:" + url.path.dropFirst(c.count).replacingOccurrences(of: "/", with: "\\")
    }

    static func niceName(_ url: URL) -> String {
        var n = url.deletingPathExtension().lastPathComponent
        for junk in ["-setup", "_setup", " setup", "setup_", "Setup", "-Win64-Shipping", "-Win64", "_x64", "64"] where n.count > junk.count + 2 {
            if n.hasSuffix(junk) { n = String(n.dropLast(junk.count)) }
            if n.hasPrefix(junk) { n = String(n.dropFirst(junk.count)) }
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        // generic names like "game.exe" or "launcher.exe": the folder says more
        if ["game", "launcher", "start", "play", "main", "client", "app"].contains(n.lowercased()), !parent.isEmpty { n = parent }
        return n.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Steam

    func installSteam() {
        if let s = bottles.first(where: { $0.kind == "steam" }) { message = L("Steam is already in your library."); editing = nil; play(s); return }
        Task {
            do {
                let setup = try await downloadOnce(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!,
                                                   name: "SteamSetup.exe", title: "Steam")
                var b = try newBottle(name: "Steam", program: Library.steamExe, kind: "steam")
                b.metal4 = false            // Steam's client crashes with D3DM_MTL4 under GPTK 4 beta 3
                update(b)
                message = L("Installing Steam…")
                launch(b, program: setup.path, extra: ["/S"]) { [weak self] in
                    guard let self else { return }
                    if b.programExists {
                        self.loadIcon(b)
                        self.message = L("Steam installed. Press Play and sign in; the first start updates Steam and takes a few minutes.")
                        self.checkForNewPrograms(b)
                    } else {
                        self.message = L("Steam's installer didn't finish. Try again, or remove the Steam tile.")
                    }
                }
            } catch { message = error.localizedDescription }
        }
    }
    static let steamExe = "C:\\Program Files (x86)\\Steam\\steam.exe"
    /// Steam's web-based windows (CEF) need these under Wine on macOS. (Not -noverifyfiles: on a fresh
    /// install it skips downloading the client and Steam hangs.)
    static let steamArgs = ["-cef-disable-gpu", "-cef-disable-sandbox"]

    // MARK: runtime fixes

    func installVCRedist(_ b: Bottle) {
        Task {
            do {
                let x64 = try await downloadOnce(URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!, name: "vc_redist.x64.exe", title: "Visual C++ (64-bit)")
                let x86 = try await downloadOnce(URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!, name: "vc_redist.x86.exe", title: "Visual C++ (32-bit)")
                message = L("Installing Visual C++ runtimes…")
                launch(b, program: x64.path, extra: ["/install", "/quiet", "/norestart"]) { [weak self] in
                    self?.launch(b, program: x86.path, extra: ["/install", "/quiet", "/norestart"]) {
                        self?.message = L("Visual C++ runtimes installed in %@.", b.name)
                    }
                }
            } catch { message = error.localizedDescription }
        }
    }

    func setWindowsVersion(_ b: Bottle) {
        launch(b, program: "winecfg", extra: ["-v", b.windowsVersion]) {}
    }

    func openWineSettings(_ b: Bottle) { launch(b, program: "winecfg", extra: []) {} }

    // MARK: running

    func play(_ b: Bottle) {
        guard !running.contains(b.id) else { return }
        guard b.programExists else { message = L("%@ can't be found. Choose its program in the settings.", b.name); editing = b; return }
        var extra = b.arguments.split(separator: " ").map(String.init)
        if b.kind == "steam" { extra = Library.steamArgs + extra }
        message = L("Starting %@…", b.name)
        launch(b, program: b.program, extra: extra) { [weak self] in
            self?.message = L("%@ closed.", b.name)
            // a game launcher or Steam may have installed something new
            self?.checkForNewPrograms(b)
        }
    }

    /// Runs a program in a bottle; `done` runs on the main actor when every program in it has exited.
    func launch(_ b: Bottle, program: String, extra: [String], done: @escaping @MainActor () -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [Paths.bin.appendingPathComponent("run.sh").path, b.bottleFolder.path, program] + extra
        var env = ProcessInfo.processInfo.environment
        env["WP_METAL4"] = b.metal4 ? "1" : "0"
        env["WP_HUD"] = b.fpsCounter ? "1" : "0"
        env["WP_D3DMETAL"] = b.d3dmetal ? "1" : "0"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            Task { @MainActor in
                self.processes[b.id] = nil
                self.running.remove(b.id)
                done()
            }
        }
        do {
            try p.run()
            processes[b.id] = p
            running.insert(b.id)
        } catch { message = error.localizedDescription }
    }

    func stop(_ b: Bottle) {
        message = L("Closing %@…", b.name)
        Task.detached { runScript("stop.sh", [b.bottleFolder.path]) }
    }

    /// Removes a tile. For a game with its own bottle, asks whether to keep the bottle (to bring the
    /// game back later) or delete it.
    func remove(_ b: Bottle) {
        let a = NSAlert()
        a.messageText = L("Remove %@ from your library?", b.name)
        if b.host != nil {
            // a second program in another game's bottle: nothing of its own to delete
            a.informativeText = L("It's installed in the Windows bottle of %@, so its files stay there.", owner(of: b).name)
            a.addButton(withTitle: L("Remove")); a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            try? FileManager.default.trashItem(at: b.folder, resultingItemURL: nil)
            bottles.removeAll { $0.id == b.id }; icons[b.id] = nil
            message = L("Removed %@.", b.name)
            return
        }
        let guests = guests(of: b)
        var text = L("Do you also want to delete its Windows bottle? That's its own sandbox, with everything installed in it, its settings and its saves.")
        text += "\n\n" + L("Keep it to bring %@ back later from Add → Removed games. Delete it to free the space; it goes to the Trash.", b.name)
        if b.program.hasPrefix("/") { text += " " + L("The game's own files stay where they are.") }
        if !guests.isEmpty {
            text += "\n\n" + L("Also in this bottle: %@. Those stay if you keep it, and are removed if you delete it.",
                               guests.map(\.name).joined(separator: ", "))
        }
        a.informativeText = text
        a.addButton(withTitle: L("Keep the bottle"))
        let del = a.addButton(withTitle: L("Delete the bottle")); del.hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        switch a.runModal() {
        case .alertFirstButtonReturn:
            var k = b; k.hidden = true; k.save()
            bottles.removeAll { $0.id == b.id }
            keptBottles.append(k)
            message = L("Removed %@. Its bottle was kept.", b.name)
        case .alertSecondButtonReturn:
            deleteBottle(b)
            message = L("Removed %@ and deleted its bottle.", b.name)
        default: return
        }
    }

    /// Puts a bottle (and the tiles that run in it) in the Trash.
    private func deleteBottle(_ b: Bottle) {
        let tiles = [b] + guests(of: b)
        if tiles.contains(where: { running.contains($0.id) }) { runScript("stop.sh", [b.folder.path]) }
        for t in tiles {
            try? FileManager.default.trashItem(at: t.folder, resultingItemURL: nil)
            icons[t.id] = nil
        }
        let ids = Set(tiles.map(\.id))
        bottles.removeAll { ids.contains($0.id) }
        keptBottles.removeAll { ids.contains($0.id) }
    }

    /// Brings a removed game back from its kept bottle.
    func restore(_ b: Bottle) {
        var r = b; r.hidden = nil; r.save()
        keptBottles.removeAll { $0.id == b.id }
        bottles.append(r)
        bottles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loadIcon(r)
        message = L("%@ is back in your library.", b.name)
    }

    /// Deletes a kept bottle for good (to the Trash), after asking.
    func deleteKept(_ b: Bottle) {
        let a = NSAlert()
        a.messageText = L("Delete the bottle of %@?", b.name)
        var text = L("Everything installed in it, its settings and its saves go to the Trash.")
        let guests = guests(of: b)
        if !guests.isEmpty {
            text += "\n\n" + L("Also in this bottle, and removed with it: %@.", guests.map(\.name).joined(separator: ", "))
        }
        a.informativeText = text
        let del = a.addButton(withTitle: L("Delete the bottle")); del.hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        deleteBottle(b)
        message = L("Deleted the bottle of %@.", b.name)
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    // MARK: downloads

    /// Downloads into WinPlay's downloads folder once and reuses the file afterwards.
    func downloadOnce(_ url: URL, name: String, title: String) async throws -> URL {
        let dst = Paths.downloads.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        downloading = true; downloadTitle = title; downloadFraction = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let t = self?.downloadTask, t.countOfBytesExpectedToReceive > 0 {
                    self?.downloadFraction = Double(t.countOfBytesReceived) / Double(t.countOfBytesExpectedToReceive)
                }
            }
        }
        defer { downloading = false; progressTimer?.invalidate(); progressTimer = nil; downloadTask = nil }
        let tmp: URL = try await withCheckedThrowingContinuation { cont in
            var req = URLRequest(url: url)
            req.setValue("WinPlay", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.downloadTask(with: req) { loc, resp, err in
                if let err = err as? URLError, err.code == .cancelled { cont.resume(throwing: WinPlayError(L("Download cancelled."))); return }
                if let err { cont.resume(throwing: err); return }
                guard let loc, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: WinPlayError(L("The download failed."))); return
                }
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do { try FileManager.default.moveItem(at: loc, to: keep); cont.resume(returning: keep) }
                catch { cont.resume(throwing: error) }
            }
            downloadTask = task
            task.resume()
        }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        return dst
    }

    func cancelDownload() { downloadTask?.cancel() }
}

// MARK: - Controllers (shared with BeamNG Launcher)

struct InputDevice: Identifiable, Hashable {
    enum Kind: String { case gamepad = "Controller", wheel = "Steering wheel", joystick = "Joystick" }
    var id: String
    var name: String
    var kind: Kind
    var connection: String
    var rawName = ""
}

enum ControllerScanner {
    static let wheelVendors: Set<Int> = [0x044f, 0x0eb7, 0x346e, 0x3416, 0x16d0, 0x1dd2, 0x0483]
    static let wheelWords = ["wheel", "racing", "driving force", "g29", "g920", "g923", "g27", "g25", "t300",
                             "t150", "t248", "tmx", "t-gt", "csl", "podium", "moza", "simucube", "fanatec"]
    static let knownNames: [String: String] = [
        "045e:028e": "Xbox 360 controller", "045e:028f": "Xbox 360 wireless controller",
        "045e:02ea": "Xbox One controller", "045e:0b12": "Xbox Series controller",
        "045e:0b13": "Xbox Series controller", "054c:0ce6": "DualSense controller", "054c:09cc": "DualShock 4 controller",
    ]

    static func classify(name: String, vendor: Int, usage: Int) -> InputDevice.Kind {
        let n = name.lowercased()
        if wheelVendors.contains(vendor) && vendor != 0x0483 { return .wheel }
        if wheelWords.contains(where: { n.contains($0) }) { return .wheel }
        if usage == kHIDUsage_GD_Joystick || usage == kHIDUsage_GD_MultiAxisController {
            return n.contains("pad") || n.contains("controller") ? .gamepad : .joystick
        }
        return .gamepad
    }

    static func displayName(_ raw: String, manufacturer: String, vendor: Int, product: Int) -> String {
        let key = String(format: "%04x:%04x", vendor, product)
        var base = knownNames[key] ?? raw
        let looksLikeCode = base.isEmpty || base.range(of: "^[0-9A-Fa-f]{5,}$", options: .regularExpression) != nil
        if looksLikeCode { base = L("Game controller") }
        if !manufacturer.isEmpty && !base.lowercased().contains(manufacturer.lowercased()) && knownNames[key] != nil || looksLikeCode && !manufacturer.isEmpty {
            base += " (\(manufacturer))"
        }
        return base
    }

    static func scan() -> [InputDevice] {
        var found: [String: InputDevice] = [:]

        // 1. HID game controllers, joysticks and wheels
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let usages = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController]
        let matches = usages.map { [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as [String: Any] }
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
            for d in devs {
                func prop(_ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }
                let name = prop(kIOHIDProductKey) as? String ?? ""
                let manu = prop(kIOHIDManufacturerKey) as? String ?? ""
                let v = prop(kIOHIDVendorIDKey) as? Int ?? 0
                let p = prop(kIOHIDProductIDKey) as? Int ?? 0
                let usage = prop(kIOHIDPrimaryUsageKey) as? Int ?? 0
                let transport = prop(kIOHIDTransportKey) as? String ?? "USB"
                let id = String(format: "%04x:%04x", v, p)
                found[id] = InputDevice(id: id, name: displayName(name, manufacturer: manu, vendor: v, product: p),
                                        kind: classify(name: name, vendor: v, usage: usage),
                                        connection: transport.lowercased().contains("bluetooth") ? "Bluetooth" : "USB",
                                        rawName: name)
            }
        }
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

        // 2. Wired Xbox-style (XInput) pads that are not HID devices
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iter) == KERN_SUCCESS {
            var svc = IOIteratorNext(iter)
            while svc != 0 {
                func num(_ e: io_registry_entry_t, _ k: String) -> Int? {
                    IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
                }
                func str(_ e: io_registry_entry_t, _ k: String) -> String? {
                    IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                }
                if num(svc, "bInterfaceClass") == 255 && num(svc, "bInterfaceSubClass") == 93 {
                    var parent: io_registry_entry_t = 0
                    if IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS {
                        let v = num(parent, "idVendor") ?? 0, p = num(parent, "idProduct") ?? 0
                        let id = String(format: "%04x:%04x", v, p)
                        if found[id] == nil {
                            let name = str(parent, "kUSBProductString") ?? str(parent, "USB Product Name") ?? ""
                            let manu = str(parent, "kUSBVendorString") ?? str(parent, "USB Vendor Name") ?? ""
                            found[id] = InputDevice(id: id, name: displayName(name, manufacturer: manu, vendor: v, product: p),
                                                    kind: classify(name: name, vendor: v, usage: kHIDUsage_GD_GamePad), connection: "USB",
                                                    rawName: name)
                        }
                        IOObjectRelease(parent)
                    }
                }
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }

        // 3. Controllers macOS knows through the Game Controller framework (Bluetooth pads)
        for gc in GCController.controllers() {
            let raw = gc.vendorName ?? ""
            let n = raw.lowercased()
            // the same pad is often already listed from USB/HID under its raw product name
            if found.values.contains(where: { !n.isEmpty && ($0.rawName.lowercased() == n || $0.name.lowercased().contains(n)) }) { continue }
            let name = displayName(raw, manufacturer: "", vendor: 0, product: 0)
            found["gc:\(raw)"] = InputDevice(id: "gc:\(raw)", name: name, kind: .gamepad, connection: "Wireless", rawName: raw)
        }
        return found.values.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

}

// MARK: - UI

struct Caption: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct CheckRow: View {
    let ok: Bool; let title: String; let detail: String
    var optional = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "minus.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(ok ? .green : (optional ? .gray : .red))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if !detail.isEmpty { Caption(detail) }
            }
        }
    }
}

struct Tile: View {
    @EnvironmentObject var lib: Library
    let bottle: Bottle
    @State private var hover = false

    var body: some View {
        let isRunning = lib.running.contains(bottle.id)
        VStack(spacing: 8) {
            ZStack {
                if let img = lib.icons[bottle.id] {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: bottle.kind == "steam" ? "cloud.fill" : "gamecontroller.fill")
                        .resizable().scaledToFit().padding(14).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            Text(bottle.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 34, alignment: .top)
            if isRunning {
                Button(role: .destructive) { lib.stop(bottle) } label: { Label(L("Stop"), systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .controlSize(.small)
            } else {
                Button { lib.play(bottle) } label: { Label(L("Play"), systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(bottle.program.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 150, height: 180)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hover ? 0.09 : 0.05)))
        .overlay(alignment: .topTrailing) {
            if isRunning { Circle().fill(.green).frame(width: 9, height: 9).padding(8) }
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if !isRunning { lib.play(bottle) } }
        .contextMenu {
            Button(L("Settings…")) { lib.editing = bottle }
            Button(L("Open C: drive")) { lib.open(bottle.cDrive) }
            if let f = bottle.programFile { Button(L("Show program in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([f]) } }
            Button(L("Open last log")) { lib.open(bottle.log) }
            Button(L("Look for new programs")) { lib.checkForNewPrograms(bottle, manual: true) }
            Divider()
            Button(L("Install Visual C++ runtimes")) { lib.installVCRedist(bottle) }
            Button(L("Wine settings")) { lib.openWineSettings(bottle) }
            Divider()
            Button(L("Remove…")) { lib.remove(bottle) }
        }
        .help(bottle.program)
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var lib: Library
    @State var bottle: Bottle
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let img = lib.icons[bottle.id] { Image(nsImage: img).resizable().frame(width: 40, height: 40) }
                TextField(L("Name"), text: $bottle.name).textFieldStyle(.roundedBorder).font(.title3)
            }
            Form {
                LabeledContent(L("Program")) {
                    HStack {
                        Text(bottle.program.isEmpty ? L("None chosen") : bottle.program)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Choose…")) { chooseProgram() }
                    }
                }
                TextField(L("Launch options"), text: $bottle.arguments, prompt: Text(L("e.g. -windowed")))
                Picker(L("Windows version"), selection: $bottle.windowsVersion) {
                    Text("Windows 11").tag("win11"); Text("Windows 10").tag("win10"); Text("Windows 8.1").tag("win81")
                    Text("Windows 7").tag("win7"); Text("Windows XP").tag("winxp")
                }
                Toggle(isOn: $bottle.d3dmetal) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Apple D3DMetal (DirectX 11/12)"))
                        Caption(L("Best for modern games. Turn it off for very old DirectX 9 or OpenGL games that look wrong."))
                    }
                }
                Toggle(L("Metal 4"), isOn: $bottle.metal4).disabled(!bottle.d3dmetal)
                Toggle(L("Show FPS counter"), isOn: $bottle.fpsCounter)
            }
            .formStyle(.grouped)
            HStack {
                Button(L("Install Visual C++ runtimes")) { lib.installVCRedist(bottle) }
                Button(L("Wine settings")) { lib.openWineSettings(bottle) }
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save")) { lib.update(bottle); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    func chooseProgram() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Library.exeTypes
        panel.directoryURL = bottle.programFile?.deletingLastPathComponent() ?? bottle.cDrive
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bottle.program = Library.windowsPath(url, in: bottle)
        if bottle.name.isEmpty || bottle.name == "Setup" { bottle.name = Library.niceName(url) }
    }
}

/// Programs that showed up in a bottle, waiting for an answer.
struct NewPrograms: Identifiable {
    let id = UUID()
    let owner: Bottle
    let candidates: [URL]       // biggest first
    let afterInstaller: Bool
}

struct NewProgramsSheet: View {
    @EnvironmentObject var lib: Library
    let found: NewPrograms
    @State private var picked: Set<URL> = []
    @State private var icons: [URL: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(found.afterInstaller ? L("The installer added new programs") : L("New programs in %@", found.owner.name))
                .font(.headline)
            Caption(L("Add the ones you want to your library. The biggest program in each folder is usually the game or app itself."))
            List(found.candidates, id: \.self) { u in
                Toggle(isOn: Binding(get: { picked.contains(u) }, set: { if $0 { picked.insert(u) } else { picked.remove(u) } })) {
                    HStack {
                        Group {
                            if let img = icons[u] { Image(nsImage: img).resizable() }
                            else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
                        }
                        .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Library.niceName(u))
                            Caption(Library.windowsPath(u, in: found.owner)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(height: 240)
            HStack {
                Text(L("%ld selected", picked.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Don't add")) { lib.addNewPrograms([]) }
                Button(L("Add to library")) { lib.addNewPrograms(found.candidates.filter(picked.contains)) }
                    .keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(20).frame(width: 540)
        .onAppear {
            // preselect the biggest program of each install folder (the list is biggest first)
            var seen = Set<String>()
            for u in found.candidates where seen.insert(Library.installFolder(u, in: found.owner).lowercased()).inserted {
                picked.insert(u)
            }
            let list = found.candidates
            Task.detached {
                for u in list { if let img = ExeIcon.image(for: u) { await MainActor.run { icons[u] = img } } }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        VStack(spacing: 0) {
            if !lib.ready || lib.gptkVersion.isEmpty { setupBox.padding(16) }
            if lib.bottles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 150), spacing: 14)], spacing: 14) {
                        ForEach(lib.bottles) { Tile(bottle: $0) }
                    }
                    .padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("Add a game or app (.exe)…")) { lib.addProgram() }
                    Button(L("Run a Windows installer…")) { lib.runInstaller() }
                    Divider()
                    Button(L("Install Steam")) { lib.installSteam() }
                    if !lib.keptBottles.isEmpty {
                        Divider()
                        Menu(L("Removed games")) {
                            ForEach(lib.keptBottles) { k in
                                Menu(k.name) {
                                    Button(L("Bring back")) { lib.restore(k) }
                                    Button(L("Delete the bottle…")) { lib.deleteKept(k) }
                                }
                            }
                        }
                    }
                } label: { Label(L("Add"), systemImage: "plus") }
                .disabled(!lib.ready || lib.busy || lib.downloading)
            }
        }
        .sheet(item: $lib.editing) { SettingsSheet(bottle: $0) }
        .sheet(item: $lib.newPrograms) { NewProgramsSheet(found: $0).interactiveDismissDisabled() }
    }

    var setupBox: some View {
        GroupBox(L("Setup")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CheckRow(ok: lib.ready, title: L("Wine and a Windows template"),
                             detail: lib.ready ? L("Ready") : L("Imported from BeamNG Launcher or GameHub (run any game in GameHub once)"))
                    Spacer()
                    Button(L("Set up")) { lib.runSetup() }.disabled(lib.busy || lib.ready)
                }
                HStack {
                    CheckRow(ok: !lib.gptkVersion.isEmpty, title: L("Apple Game Porting Toolkit"),
                             detail: lib.gptkVersion.isEmpty ? L("Needed for DirectX 11/12 games. Download \"Evaluation environment for Windows games\" from Apple.") : lib.gptkVersion,
                             optional: true)
                    Spacer()
                    Button(L("Get from Apple")) { lib.open(URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!) }
                    Button(L("Install .dmg…")) { lib.installGPTK() }.disabled(lib.busy)
                }
            }
            .padding(6)
        }
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.grid.2x2").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(L("Your Windows games and apps show up here")).font(.title3.weight(.semibold))
            Caption(L("Add a game's .exe, run a Windows installer, or install Steam."))
            HStack {
                Button(L("Add a game or app (.exe)…")) { lib.addProgram() }
                Button(L("Run a Windows installer…")) { lib.runInstaller() }
                Button(L("Install Steam")) { lib.installSteam() }
            }
            .disabled(!lib.ready || lib.busy || lib.downloading)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    var footer: some View {
        HStack(spacing: 10) {
            if lib.downloading {
                Text(L("Downloading %@…", lib.downloadTitle)).font(.caption).lineLimit(1)
                ProgressView(value: lib.downloadFraction).frame(maxWidth: 200)
                Button(L("Cancel")) { lib.cancelDownload() }.controlSize(.small)
            } else {
                if lib.busy { ProgressView().controlSize(.small) }
                Text(lib.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            let pads = lib.devices
            Label(pads.isEmpty ? L("No controller") : pads.map(\.name).joined(separator: ", "),
                  systemImage: pads.isEmpty ? "gamecontroller" : "gamecontroller.fill")
                .font(.caption).foregroundStyle(pads.isEmpty ? .secondary : .primary).lineLimit(1)
                .help(pads.map { "\($0.name) · \(L($0.connection))" }.joined(separator: "\n"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Library.shared.open(files: urls) }
    }
}

@main
struct WinPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var lib = Library.shared
    var body: some Scene {
        // one window: a WindowGroup would open another window for every file opened from Finder
        Window("WinPlay", id: "main") {
            ContentView().environmentObject(lib)
        }
        .defaultSize(width: 760, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Add a game or app (.exe)…")) { lib.addProgram() }.keyboardShortcut("o")
                Button(L("Run a Windows installer…")) { lib.runInstaller() }.keyboardShortcut("i")
            }
            CommandGroup(after: .appSettings) {
                Button(L("Open Windows Programs with WinPlay")) { lib.makeDefaultOpener() }
            }
        }
    }
}
