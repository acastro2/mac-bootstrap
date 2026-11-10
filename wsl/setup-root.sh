#!/usr/bin/env bash
# wsl/setup-root.sh — OPTIONAL. Only the things that genuinely need root.
# Everything works without it (wsl/setup.sh has no-root fallbacks); this makes
# it native: apt zsh as login shell, full Chromium deps, no Windows PATH.
#
#   sudo bash wsl/setup-root.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
U="${SUDO_USER:?run via sudo from your user}"
H="$(getent passwd "$U" | cut -d: -f6)"
log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

log "apt: zsh + Chromium/Playwright deps + psql/redis clients + WSL utilities"
apt-get update
apt-get install -y zsh libatomic1 build-essential unzip wslu wl-clipboard \
  postgresql-client redis-tools ffmpeg
# Full Playwright Chromium dependency set (fonts, codecs, etc.)
if [[ -x $H/.local/bin/playwright ]]; then
  "$H/.local/bin/playwright" install-deps chromium
else
  apt-get install -y libnss3 libnspr4 libasound2t64 fonts-liberation fonts-noto-color-emoji
fi

log "Login shell → /usr/bin/zsh (the ~/.profile handoff becomes a no-op)"
grep -qxF /usr/bin/zsh /etc/shells || echo /usr/bin/zsh >> /etc/shells
chsh -s /usr/bin/zsh "$U"

log "Remove the user-space copies now that apt provides them"
rm -rf "$H/.local/lib/userdebs" "$H/.local/opt/userdebs" "$H/.local/bin/psql" "$H/.local/bin/redis-cli"

log "/etc/wsl.conf: stop appending the whole Windows PATH (faster zsh lookups;"
log "local.zsh re-adds VS Code, System32, PowerShell and WindowsApps)"
if ! grep -q '^\[interop\]' /etc/wsl.conf; then
  printf '\n[interop]\nappendWindowsPath = false\n' >> /etc/wsl.conf
fi
cat /etc/wsl.conf

echo
echo "Done. From PowerShell: wsl --shutdown, then open a new terminal."
