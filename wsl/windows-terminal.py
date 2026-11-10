#!/usr/bin/env python3
"""Configure Windows Terminal for this WSL distro. Idempotent; backs up first.

  python3 -I wsl/windows-terminal.py /mnt/c/Users/<you>/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json

- New tabs/windows open the WSL distro ($WSL_DISTRO_NAME), starting in ~
- Ghostty-like look: iTerm2 Dark Background, JetBrainsMono Nerd Font, padding
- Browser-style tabs: Ctrl+T new (same folder), Ctrl+W close, Ctrl+1..8 / Ctrl+9 last,
  Ctrl+Tab / Ctrl+Shift+Tab next/prev
"""
import json
import os
import shutil
import sys
import time

path = sys.argv[1]
distro = os.environ.get("WSL_DISTRO_NAME", "Ubuntu-24.04")
shutil.copy2(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
s = json.load(open(path, encoding="utf-8-sig"))

profiles = s["profiles"]["list"] if isinstance(s.get("profiles"), dict) else s["profiles"]
wsl = next((p for p in profiles if p.get("name") == distro), None)
if wsl is None:
    sys.exit(f"No Windows Terminal profile named {distro!r}; open Windows Terminal once so it generates one.")

s["defaultProfile"] = wsl["guid"]
s["copyOnSelect"] = True                              # ghostty: copy-on-select
s["firstWindowPreference"] = "persistedWindowLayout"  # ghostty: window-save-state
s["warning.confirmCloseAllTabs"] = False              # ghostty: confirm-close-surface=false
wsl.update({
    "startingDirectory": "~",
    "colorScheme": "iTerm2 Dark Background",
    "font": {"face": "JetBrainsMono Nerd Font", "size": 11},
    "padding": "12",
    "opacity": 97,
    "useAcrylic": True,
    "cursorShape": "filledBox",
    "intenseTextStyle": "bright",
})

scheme = {
    "name": "iTerm2 Dark Background",
    "background": "#000000", "foreground": "#C7C7C7",
    "cursorColor": "#C7C7C7", "selectionBackground": "#C1DEFF",
    "black": "#000000", "red": "#C91B00", "green": "#00C200", "yellow": "#C7C400",
    "blue": "#0225C7", "purple": "#CA30C7", "cyan": "#00C5C7", "white": "#C7C7C7",
    "brightBlack": "#686868", "brightRed": "#FF6E67", "brightGreen": "#5FFA68",
    "brightYellow": "#FFFC67", "brightBlue": "#6871FF", "brightPurple": "#FF77FF",
    "brightCyan": "#60FDFF", "brightWhite": "#FFFFFF",
}
s["schemes"] = [x for x in s.get("schemes", []) if x.get("name") != scheme["name"]] + [scheme]

acts = {
    # duplicateTab, not newTab: reuses the folder the shell reports via OSC 9;9
    # (local.zsh), so new tabs open where you are, like Ghostty.
    "User.newTab":  ({"action": "duplicateTab"}, "ctrl+t"),
    "User.close":   ({"action": "closePane"}, "ctrl+w"),  # closes the tab when it has one pane
    "User.lastTab": ({"action": "switchToTab", "index": 4294967295}, "ctrl+9"),
    "User.nextTab": ({"action": "nextTab"}, "ctrl+tab"),
    "User.prevTab": ({"action": "prevTab"}, "ctrl+shift+tab"),
}
for i in range(8):
    acts[f"User.tab{i + 1}"] = ({"action": "switchToTab", "index": i}, f"ctrl+{i + 1}")
keys = {k for _, k in acts.values()}
s["actions"] = [a for a in s.get("actions", []) if a.get("id") not in acts] + \
               [{"command": c, "id": i} for i, (c, _) in acts.items()]
s["keybindings"] = [b for b in s.get("keybindings", []) if b.get("keys") not in keys and b.get("id") not in acts] + \
                   [{"id": i, "keys": k} for i, (_, k) in acts.items()]

json.dump(s, open(path, "w", encoding="utf-8"), indent=4)
print(f"Windows Terminal: default profile {distro}, theme + tab keys applied.")
