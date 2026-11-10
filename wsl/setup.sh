#!/usr/bin/env bash
# wsl/setup.sh — WSL2 (Ubuntu) workstation setup, NO sudo needed. Safe to re-run.
# The WSL counterpart of bootstrap.sh: apt-free, user-space installs via mise,
# configs deployed from wsl/files, dotfiles from home/ via chezmoi.
#
#   bash wsl/setup.sh                      # everything
#   bash wsl/setup.sh configs doctor       # run only some steps
#   sudo bash wsl/setup-root.sh            # optional root extras (see that file)
#
# Steps: configs zsh libs mise agents browser dotfiles windows doctor
set -uo pipefail

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
step() { [[ -z "${STEPS:-}" || " $STEPS " == *" $1 "* ]]; }
STEPS="${*:-}"
[[ $EUID -ne 0 ]] || { echo "Run as your user, not root." >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f $HERE/config.env ]] && source "$HERE/config.env"
REPO_DIR="$HERE"   # this checkout, not config.env's Mac path
FILES="$REPO_DIR/wsl/files"
WINHOME="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')" 2>/dev/null || echo "/mnt/c/Users/$USER")"
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.opencode/bin:$PATH"
export BROWSER="$HOME/.local/bin/wsl-open"

# ── Configs (deploy wsl/files; an existing different file is backed up) ──
deploy() { # src dest [mode]
  local src="$1" dest="$2" mode="${3:-644}"
  mkdir -p "$(dirname "$dest")"
  if [[ -f $dest ]] && ! cmp -s "$src" "$dest"; then cp -p "$dest" "$dest.bak-$(date +%Y%m%d-%H%M%S)"; fi
  install -m "$mode" "$src" "$dest"
  echo "  $dest"
}
if step configs; then
  log "Configs"
  deploy "$FILES/mise.toml"          "$HOME/.config/mise/config.toml"
  deploy "$FILES/zshenv"             "$HOME/.zshenv"
  tmp="$(mktemp)"; sed "s|@WINHOME@|$WINHOME|" "$FILES/local.zsh" > "$tmp"
  deploy "$tmp"                      "$HOME/.config/zsh/local.zsh"; rm -f "$tmp"
  deploy "$FILES/bin/wsl-open"         "$HOME/.local/bin/wsl-open" 755
  deploy "$FILES/bin/op-sync-api-keys" "$HOME/.local/bin/op-sync-api-keys" 755
  deploy "$FILES/ssh-agent.service"  "$HOME/.config/systemd/user/ssh-agent.service"
  systemctl --user daemon-reload && systemctl --user enable --now ssh-agent.service || warn "ssh-agent unit failed"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  [[ -f $HOME/.ssh/config ]] || deploy "$FILES/ssh_config" "$HOME/.ssh/config" 600
  ssh-keyscan github.com 2>/dev/null | cat - "$HOME/.ssh/known_hosts" 2>/dev/null | sort -u > "$HOME/.ssh/known_hosts.tmp" \
    && mv "$HOME/.ssh/known_hosts.tmp" "$HOME/.ssh/known_hosts"
  [[ -f $HOME/.config/zsh/.api-keys.zsh ]] || install -m 600 /dev/null "$HOME/.config/zsh/.api-keys.zsh"
  touch "$HOME/.config/zsh/local.zsh"
  grep -q '>>> zsh handoff' "$HOME/.profile" 2>/dev/null || { echo; cat "$FILES/profile-handoff.sh"; } >> "$HOME/.profile"
  mkdir -p "$HOME/.config/chezmoi"
  printf 'sourceDir = "%s/home"\n' "$REPO_DIR" > "$HOME/.config/chezmoi/chezmoi.toml"

  log "Git config"
  [[ -n ${GIT_NAME:-} ]]  && git config --global user.name "$GIT_NAME"
  [[ -n ${GIT_EMAIL:-} ]] && git config --global user.email "$GIT_EMAIL"
  git config --global init.defaultBranch main
  git config --global pull.rebase true
  git config --global rerere.enabled true
  git config --global core.autocrlf input

  log "Windows: .wslconfig + Windows Terminal"
  deploy "$FILES/wslconfig" "$WINHOME/.wslconfig"
  WT_SETTINGS="$WINHOME/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
  if [[ -f $WT_SETTINGS ]]; then
    python3 -I "$REPO_DIR/wsl/windows-terminal.py" "$WT_SETTINGS" || warn "Windows Terminal config failed"
  else
    warn "Windows Terminal settings not found; open it once, then re-run: bash wsl/setup.sh configs"
  fi
fi

# ── zsh (user-space build; apt's zsh wins once setup-root.sh runs) ────────
if step zsh; then
  log "zsh"
  if [[ -x /usr/bin/zsh || -x $HOME/.local/bin/zsh ]]; then
    echo "already installed"
  else
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/romkatv/zsh-bin/master/install)" -- -d "$HOME/.local" -e no -q \
      || warn "zsh-bin install failed"
  fi
fi

# ── Unpack system libs without root (Chromium, psql, redis-cli) ────────
# Skipped if apt already has them (i.e. after setup-root.sh).
if step libs; then
  log "User-space shared libs"
  if ldconfig -p | grep -q libnss3.so && ldconfig -p | grep -q libatomic.so.1; then
    echo "system has them; removing user copies"; rm -rf "$HOME/.local/lib/userdebs" "$HOME/.local/opt/userdebs"
  elif [[ -e $HOME/.local/lib/userdebs/libnss3.so ]]; then
    echo "already unpacked"
  else
    D="$(mktemp -d)"
    ( cd "$D" && apt-get download libnss3 libnspr4 libasound2t64 libasound2-data libpq5 \
        postgresql-client-16 redis-tools liblzf1 libjemalloc2 libatomic1 \
      && for f in *.deb; do dpkg -x "$f" x; done \
      && mkdir -p "$HOME/.local/lib/userdebs" "$HOME/.local/opt/userdebs" \
      && cp -a x/usr/lib/x86_64-linux-gnu/. "$HOME/.local/lib/userdebs/" \
      && cp -a x/usr/lib/postgresql x/usr/bin/redis-cli "$HOME/.local/opt/userdebs/" ) \
      || warn "lib unpack failed"
    rm -rf "$D"
    ln -sf "$HOME/.local/opt/userdebs/postgresql/16/bin/psql" "$HOME/.local/bin/psql"
    ln -sf "$HOME/.local/opt/userdebs/redis-cli" "$HOME/.local/bin/redis-cli"
  fi
fi
[[ -d $HOME/.local/lib/userdebs ]] && export LD_LIBRARY_PATH="$HOME/.local/lib/userdebs"

# ── mise ───────────────────────────────────────────────────────────────
if step mise; then
  log "mise"
  command -v mise >/dev/null || curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh
  mise trust "$HOME/.config/mise/config.toml"

  log "gh first, so the rest of mise installs authenticated (avoids GitHub rate limits)"
  mise install aqua:cli/cli
  if ! gh auth status >/dev/null 2>&1; then
    echo "A browser opens on Windows. Choose SSH and let gh generate + upload a key."
    gh auth login --web --git-protocol ssh -h github.com || warn "gh auth login failed; re-run later."
  fi
  gh auth setup-git 2>/dev/null || true
  # setup-git pins gh's versioned install dir, which breaks on the next gh
  # upgrade. Point the helper at the stable mise shim instead.
  for h in https://github.com https://gist.github.com; do
    git config --global --unset-all "credential.$h.helper" 2>/dev/null || true
    git config --global --add "credential.$h.helper" ''
    git config --global --add "credential.$h.helper" "!$HOME/.local/share/mise/shims/gh auth git-credential"
  done
  export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"

  log "Installing all mise tools (first run takes a while)"
  mise install || warn "Some mise tools failed — re-run: mise install"
  mise reshim
fi

# ── AI agents ──────────────────────────────────────────────────────────
if step agents; then
  log "Claude Code"
  [[ -x $HOME/.local/bin/claude ]] && echo "already installed: $(claude --version 2>/dev/null)" \
    || curl -fsSL https://claude.ai/install.sh | bash

  log "OpenCode (v2)"
  [[ -x $HOME/.opencode/bin/opencode ]] && echo "already installed" \
    || curl -fsSL https://opencode.ai/v2/install | bash
  if command -v opencode >/dev/null; then
    oc="$HOME/.config/zsh/opencode-completions.zsh"
    if opencode --completions zsh > "$oc.tmp" 2>/dev/null && grep -q -- '###-begin-opencode-completions-###' "$oc.tmp"; then
      mv "$oc.tmp" "$oc"
    else
      rm -f "$oc.tmp"
    fi
  fi

  log "Snowflake Cortex Code CLI"
  [[ -x $HOME/.local/bin/cortex ]] && echo "already installed" \
    || curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | sh

  log "Config + skills repos (cloned over HTTPS as acastro2: the active gh/SSH"
  log "identity may be a work account that can't see these private repos)"
  ACASTRO2_TOKEN="$(gh auth token --user acastro2 2>/dev/null || true)"
  [[ -n $ACASTRO2_TOKEN ]] || warn "gh has no acastro2 login; run: gh auth login (then re-run: bash wsl/setup.sh agents)"
  clone() { # repo dest
    if [[ -d $2/.git ]]; then GH_TOKEN="$ACASTRO2_TOKEN" git -C "$2" pull --ff-only || true
    elif [[ -e $2 && -n "$(ls -A "$2" 2>/dev/null)" ]]; then warn "$2 exists and isn't a git repo; skipped"
    else rmdir "$2" 2>/dev/null; GH_TOKEN="$ACASTRO2_TOKEN" git clone "https://github.com/$1.git" "$2" || warn "clone $1 failed"; fi
  }
  clone acastro2/opencode_config "$HOME/.config/opencode"
  clone acastro2/.pi             "$HOME/.pi"
  clone acastro2/alex-skills     "$HOME/.agents/skills"
fi

# ── Browser automation ─────────────────────────────────────────────────
if step browser; then
  log "Python Playwright + browser-use (uv tools)"
  uv tool install --upgrade playwright  || warn "playwright install failed"
  uv tool install --upgrade browser-use || warn "browser-use install failed"
  log "Chromium (system deps come from the unpacked libs, or wsl/setup-root.sh)"
  "$HOME/.local/bin/playwright" install chromium || warn "chromium download failed"
  "$HOME/.local/share/uv/tools/playwright/bin/python" - <<'PY' && echo "headless Chromium launches OK" || warn "Chromium failed to launch — run wsl/setup-root.sh (needs sudo) for the full dependency set"
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b = p.chromium.launch(); b.new_page().set_content("<p>ok</p>"); b.close()
PY
fi

# ── Dotfiles + zsh smoke test ──────────────────────────────────────────
if step dotfiles; then
  log "Dotfiles (chezmoi → $REPO_DIR/home)"
  chezmoi apply --verbose || warn "chezmoi apply failed"
  ZSH_BIN="$(command -v zsh || echo "$HOME/.local/bin/zsh")"
  log "First zsh start (downloads zimfw + modules)"
  "$ZSH_BIN" -ic 'true' </dev/null && echo "zsh starts cleanly" || warn "zsh startup reported errors (see above)"
fi

# ── Windows side (user scope, no admin) ────────────────────────────────
if step windows; then
  log "Windows: JetBrainsMono Nerd Font + VS Code Insiders (winget)"
  WG=(winget.exe install --exact --silent --accept-package-agreements --accept-source-agreements)
  "${WG[@]}" --id DEVCOM.JetBrainsMonoNerdFont || warn "Font install failed — get it from https://www.nerdfonts.com/font-downloads"
  "${WG[@]}" --id Microsoft.VisualStudioCode.Insiders --scope user || warn "VS Code Insiders install failed"
  echo "First 'code .' from WSL installs the VS Code WSL server automatically."
fi

# ── Doctor ─────────────────────────────────────────────────────────────
if step doctor; then
  log "Doctor"
  ok=0; bad=0
  for c in zsh mise gh op chezmoi starship carapace fzf eza mcat bat fd rg jq yq nvim doggo \
           uv node go python pnpm dotnet tofu kubectl helm k9s aws az gcx crane tflint \
           snow pgcli psql redis-cli claude opencode cortex pi ctx7 herdr tgrep playwright browser-use docker; do
    if p="$(command -v "$c" 2>/dev/null)"; then printf '  \033[32m✓\033[0m %-12s %s\n' "$c" "${p/#$HOME/~}"; ok=$((ok+1))
    else printf '  \033[31m✗\033[0m %s\n' "$c"; bad=$((bad+1)); fi
  done
  docker compose version >/dev/null 2>&1 && echo "  ✓ docker compose" || echo "  ✗ docker compose"
  [[ -e $HOME/.zim/zimfw.zsh ]] && echo "  ✓ zim" || echo "  ✗ zim"
  systemctl --user is-active -q ssh-agent && echo "  ✓ ssh-agent" || echo "  ✗ ssh-agent"
  echo; echo "$ok found, $bad missing"
fi

cat <<EOF

━━━ Next ━━━
  1. Close all terminals, then in PowerShell:  wsl --shutdown   (applies .wslconfig)
  2. Open Windows Terminal → new tabs are Ubuntu + zsh.
  3. 1Password:  op account add   then   eval "\$(op signin)" && op-sync-api-keys
  4. aws sso login --profile <profile>;  az login --allow-no-subscriptions
  Optional, if you have sudo:  sudo bash $REPO_DIR/wsl/setup-root.sh
EOF
