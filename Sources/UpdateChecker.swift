// Update checker shared by WinPlay, BeamNG Launcher and EarBar (keep the copies the same).
// Once a day at launch, and from "Check for Updates…", it asks GitHub for the latest release
// (pre-releases are left out) and offers to download it when it's newer than this app.
import AppKit

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private var repo = ""          // "owner/name" on GitHub
    private var appName = ""
    private var busy = false
    private let defaults = UserDefaults.standard

    /// The running version. `-UpdateCheckPretendVersion 0.1` on the command line overrides it, for testing.
    var current: String {
        defaults.string(forKey: "UpdateCheckPretendVersion")
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Call once at launch. Checks quietly, at most once a day.
    func start(repo: String, appName: String) {
        self.repo = repo; self.appName = appName
        let last = defaults.object(forKey: "UpdateCheckLast") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // let the app finish starting
            await check(manual: false)
        }
    }

    /// `manual` is the menu command: it also says when there's no update or GitHub can't be reached.
    func check(manual: Bool) async {
        guard !busy, !repo.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let rel = try await Self.latestRelease(repo)
            defaults.set(Date(), forKey: "UpdateCheckLast")
            if Self.isNewer(rel.version, than: current) {
                if !manual && defaults.string(forKey: "UpdateSkipVersion") == rel.version { return }
                offer(rel)
            } else if manual {
                alert(L("%@ is up to date", appName), L("You have the newest version, %@.", current))
            }
        } catch {
            if manual { alert(L("Couldn't check for updates"), L("GitHub didn't answer. Check your internet connection and try again.")) }
        }
    }

    private func offer(_ rel: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("%@ %@ is available", appName, rel.version)
        a.informativeText = L("You have %@. Download the new version, open it and drag %@ onto Applications to replace this one. Your settings are kept.", current, appName)
        a.addButton(withTitle: L("Download"))
        a.addButton(withTitle: L("Later"))
        a.addButton(withTitle: L("Skip This Version"))
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(rel.download ?? rel.page)
        case .alertThirdButtonReturn: defaults.set(rel.version, forKey: "UpdateSkipVersion")
        default: break
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: GitHub

    struct Release { let version: String; let page: URL; let download: URL? }

    nonisolated static func latestRelease(_ repo: String) async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("\(repo.split(separator: "/").last ?? "app")-update-check", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else { throw URLError(.badServerResponse) }
        let dmg = (o["assets"] as? [[String: Any]] ?? [])
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.lowercased().hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, download: dmg)
    }

    /// "1.4.0" > "1.3.1", "1.4.0" > "1.4.0-beta.1"; a leading "v" is ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func split(_ v: String) -> ([Int], Bool) {
            var s = v.lowercased()
            if s.hasPrefix("v") { s.removeFirst() }
            let halves = s.split(separator: "-", maxSplits: 1)
            let nums = (halves.first ?? "").split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
            return (nums, halves.count > 1)
        }
        let (x, xPre) = split(a), (y, yPre) = split(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return yPre && !xPre
    }
}
