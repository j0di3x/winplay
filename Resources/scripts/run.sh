#!/bin/zsh
# run.sh <bottle folder> <program> [arguments...]
# <program> is a Mac path or a Windows path (C:\...). Settings come from the environment:
# WP_METAL4=1 (Metal 4), WP_HUD=1 (FPS counter), WP_D3DMETAL=0 (use Wine's own OpenGL renderer instead)
R="$HOME/Library/Application Support/WinPlay"
B="$1"; shift; EXE="$1"; shift
W="$R/wine"; GPTK="$R/gptk/current"
export WINEPREFIX="$B/prefix" WINEARCH=win64 WINEMSYNC=1 WINEDEBUG="${WINEDEBUG:--all}"
export DYLD_FALLBACK_LIBRARY_PATH="$W/lib:$W/lib/wine/x86_64-unix" PATH="$W/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="${WP_LANG:-en_US.UTF-8}"
if [ "${WP_D3DMETAL:-1}" = 1 ] && [ -f "$GPTK/external/libd3dshared.dylib" ]; then
  export WINEDLLPATH="$GPTK/wine" WINE_GPTK_LIBD3DSHARED_PATH="$GPTK/external/libd3dshared.dylib"
fi
[ "$WP_METAL4" = 1 ] && export D3DM_MTL4=1
[ "$WP_HUD" = 1 ] && export MTL_HUD_ENABLED=1
LOG="$B/last-run.log"
echo "== $(date) $EXE $* (d3dmetal=${WP_D3DMETAL:-1} metal4=$WP_METAL4 hud=$WP_HUD)" > "$LOG"
if [[ "$EXE" == /* ]]; then cd "${EXE:h}"; else cd "$B/prefix/drive_c"; fi
case "${EXE:e:l}" in
  # .msi and .bat/.cmd aren't programs: Windows' start opens them with msiexec or cmd
  msi|bat|cmd)
    if [[ "$EXE" == /* ]]; then "$W/bin/wine" start /wait /unix "$EXE" "$@" >> "$LOG" 2>&1
    else "$W/bin/wine" start /wait "$EXE" "$@" >> "$LOG" 2>&1; fi ;;
  *) "$W/bin/wine" "$EXE" "$@" >> "$LOG" 2>&1 ;;
esac
"$W/bin/wineserver" -w
