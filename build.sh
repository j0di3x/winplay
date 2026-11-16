#!/bin/zsh
# Builds "WinPlay.app" into ./build.  Pass --install to copy it to ~/Applications.
set -e
cd "${0:A:h}"
# Build and sign outside the repo: folders like Documents (iCloud) add extended attributes that codesign rejects.
WORK=$(mktemp -d)
APP="$WORK/WinPlay.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos14 \
  -framework SwiftUI -framework AppKit -framework IOKit -framework GameController -framework CryptoKit \
  Sources/*.swift -o "$APP/Contents/MacOS/WinPlay"
ditto --norsrc --noextattr Resources/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noextattr Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto --norsrc --noextattr Resources/scripts "$APP/Contents/Resources/scripts"
for l in Resources/*.lproj(N); do ditto --norsrc --noextattr "$l" "$APP/Contents/Resources/${l:t}"; done
chmod +x "$APP/Contents/Resources/scripts/"*.sh
xattr -cr "$APP"
codesign --force --deep -s - "$APP"
rm -rf build; mkdir -p build; ditto "$APP" "build/WinPlay.app"
echo "Built build/WinPlay.app"
if [ "$1" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/WinPlay.app"
  ditto "$APP" "$HOME/Applications/WinPlay.app"
  echo "Installed to ~/Applications/WinPlay.app"
fi
rm -rf "$WORK"
