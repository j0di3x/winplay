#!/bin/zsh
# Sets up WinPlay's runtime: Wine (imported from BeamNG Launcher or GameHub), Apple's D3DMetal if
# BeamNG Launcher already has it, and a clean Windows 10 template every game's bottle is cloned from.
set -e
R="$HOME/Library/Application Support/WinPlay"
mkdir -p "$R/gptk" "$R/bottles" "$R/logs"

# 1. Wine: BeamNG Launcher's copy first (already tested with GPTK 4), else GameHub's
if [ ! -x "$R/wine/bin/wine" ]; then
  SRC=""
  for d in "$HOME/Library/Application Support/BeamNG-GPTK4"/containers/wine_installations/*(N/) \
           "$HOME/Library/Application Support/com.gamemac.www/wine-engine/containers"/wine_installations/*(N/); do
    [ -x "$d/bin/wine" ] && { SRC="$d"; break; }
  done
  [ -n "$SRC" ] || { echo "No Wine found. Install GameHub and run any Windows game in it once, then try again."; exit 1; }
  rm -rf "$R/wine"; cp -cR "$SRC" "$R/wine"
  echo "Wine: imported from ${SRC:h:h:h:t}"
fi

# 2. D3DMetal: reuse BeamNG Launcher's installs (APFS clones take no extra space)
for v in "$HOME/Library/Application Support/BeamNG-GPTK4"/gptk/*(N/); do
  n=${v:t}; [ "$n" = current ] && continue
  [ -d "$R/gptk/$n" ] || cp -cR "$v" "$R/gptk/$n"
done
if [ ! -e "$R/gptk/current" ]; then
  latest=$(ls "$R/gptk" | grep -v current | sort -V | tail -1)
  [ -n "$latest" ] && ln -sfn "$latest" "$R/gptk/current"
fi

# 3. Template bottle: a fresh Windows 10 prefix
if [ ! -f "$R/template/system.reg" ]; then
  rm -rf "$R/template"
  export WINEPREFIX="$R/template" WINEARCH=win64 WINEDEBUG=-all WINEMSYNC=1
  export DYLD_FALLBACK_LIBRARY_PATH="$R/wine/lib:$R/wine/lib/wine/x86_64-unix" PATH="$R/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  cd /tmp
  "$R/wine/bin/wine" wineboot --init > "$R/logs/template.log" 2>&1
  "$R/wine/bin/wineserver" -w
  # drives other than C: and Z: (DVDs, USB sticks) are machine-specific; Wine re-adds them when needed
  for l in "$R/template/dosdevices"/*(N@); do case ${l:t} in c:|z:) ;; *) rm -f "$l" ;; esac; done
  [ -f "$R/template/system.reg" ] || { echo "Creating the Windows template failed. See logs/template.log."; exit 1; }
  echo "Windows template created"
fi
echo "Runtime ready"
