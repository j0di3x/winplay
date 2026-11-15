#!/bin/zsh
# install-gptk.sh "<Apple Evaluation environment .dmg>"  -> installs D3DMetal and makes it current
set -e
DMG="$1"; R="$HOME/Library/Application Support/WinPlay"
VER=$(basename "$DMG" .dmg | sed -E 's/.*games_//; s/.*games //; s/ beta /b/; s/_beta_/b/; s/[_ ]/./g'); [ -z "$VER" ] && VER=custom
MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null 2>&1
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true' EXIT
LIB=$(find "$MNT" -maxdepth 4 -type d -path "*redist/lib" | head -1)
[ -z "$LIB" ] && { echo "This .dmg has no redist/lib. Use 'Evaluation environment for Windows games'."; exit 1; }
codesign -v "$LIB/external/D3DMetal.framework" 2>/dev/null || { echo "D3DMetal in this .dmg is not signed by Apple."; exit 1; }
rm -rf "$R/gptk/$VER"; mkdir -p "$R/gptk/$VER"
ditto "$LIB/external" "$R/gptk/$VER/external"; ditto "$LIB/wine" "$R/gptk/$VER/wine"
xattr -dr com.apple.quarantine "$R/gptk/$VER" 2>/dev/null || true
ln -sfn "$VER" "$R/gptk/current"
echo "Installed GPTK $VER"
