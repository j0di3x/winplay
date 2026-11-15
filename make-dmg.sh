#!/bin/zsh
# Builds the app and packs it into dist/WinPlay-<version>.dmg with a styled
# drag-to-Applications window (background from Tools/make-dmg-background.swift).
set -e
cd "${0:A:h}"
./build.sh
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
VOL="WinPlay"
WORK=$(mktemp -d)
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "build/WinPlay.app" "$STAGE/WinPlay.app"
ln -s /Applications "$STAGE/Applications"
ditto --norsrc --noextattr Resources/dmg-background.tiff "$STAGE/.background/background.tiff"

# writable image → lay out the window in Finder → compress
[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" >/dev/null
sleep 2
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    try
      set pathbar visible of container window to false
    end try
    set the bounds of container window to {200, 120, 840, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "WinPlay.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    update without registering applications
    delay 1
    close
    open
    set the bounds of container window to {200, 120, 840, 568}
    delay 1
    close
  end tell
end tell
OSA
# wait for Finder to write the window settings (.DS_Store) before ejecting
for i in {1..20}; do [ -f "/Volumes/$VOL/.DS_Store" ] && break; sleep 0.5; done
sleep 1; sync
hdiutil detach "/Volumes/$VOL" >/dev/null
mkdir -p dist
OUT="dist/WinPlay-$VER.dmg"
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$WORK"
shasum -a 256 "$OUT"
