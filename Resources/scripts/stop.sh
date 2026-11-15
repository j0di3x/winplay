#!/bin/zsh
# stop.sh <bottle folder>: ends every Windows program in that bottle
R="$HOME/Library/Application Support/WinPlay"
WINEPREFIX="$1/prefix" DYLD_FALLBACK_LIBRARY_PATH="$R/wine/lib" "$R/wine/bin/wineserver" -k 2>/dev/null
exit 0
