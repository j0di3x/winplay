#!/usr/bin/env python3
"""Lists every launcher string (the L("...") keys in Sources/main.swift), plus the game values shown through L(variable)."""
import re, json, sys, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[2]
src = "\n".join(p.read_text() for p in sorted((ROOT / "Sources").glob("*.swift")))
keys = []
for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', src):
    k = m.group(1).encode().decode("unicode_escape").encode("latin-1").decode("utf-8")
    if k not in keys:
        keys.append(k)
# values passed as L(variable): presets, quality levels, connections
for k in ["USB", "Bluetooth", "Wireless", "Gamepad", "Steering wheel", "Joystick"]:
    if k not in keys:
        keys.append(k)
if __name__ == "__main__":
    json.dump(keys, sys.stdout, ensure_ascii=False, indent=1)
