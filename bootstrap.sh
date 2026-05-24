#!/usr/bin/env bash
# bootstrap.sh — one-shot macOS workstation setup
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/acastro2/mac-bootstrap/main/bootstrap.sh | bash
#   # or after cloning:
#   ./bootstrap.sh
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
REPO_URL="https://github.com/acastro2/mac-bootstrap.git"
REPO_DIR="${HOME}/mac-bootstrap"
TTY="/dev/tty"

# ── Selective re-run flags ──────────────────────────────────────────
#   ./bootstrap.sh --skip apps,fonts    ← skip named sections
#   ./bootstrap.sh --only mise,chezmoi  ← run only named sections
SKIP=""
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip=*) SKIP="${1#*=}"; shift ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    -s|--skip) SKIP="$2"; shift 2 ;;
    -o|--only) ONLY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

should_run() {
  local name="$1"
  [[ -n "$ONLY" ]] && [[ ",$ONLY," != *",$name,"* ]] && return 1
  [[ -n "$SKIP" ]] && [[ ",$SKIP," == *",$name,"* ]] && return 1
  return 0
}
OP_VAULT="Private"
GIT_NAME="Alexandre Castro"
GIT_EMAIL="alexandre.castro@outlook.com"
OPENCODE_CONFIG_REPO="git@github.com:acastro2/opencode_config.git"
OPENCODE_SKILLS_REPO="git@github.com:acastro2/alex-skills.git"

log()   { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m==>\033[0m %s\n" "$*"; }
prompt(){ printf "\n\033[1;35m??\033[0m %s\n" "$*"; }
die()   { printf "\033[1;31m==>\033[0m %s\n" "$*"; exit 1; }
section(){ printf "\n\033[1;37m━━━ %s ━━━\033[0m\n" "$*"; }

# ── Sanity checks ────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "This bootstrap targets macOS only."

# =========================================================================
# PHASE 0: Prerequisites
# =========================================================================

# ── Xcode Command Line Tools ──────────────────────────────────────────
section "Xcode Command Line Tools"
if ! xcode-select -p &>/dev/null; then
  log "Installing Xcode Command Line Tools (a dialog will pop up)"
  xcode-select --install
  warn "Wait for the install to finish, then re-run this script."
  exit 0
fi
log "Already installed."

# ── Homebrew ──────────────────────────────────────────────────────────
section "Homebrew"
if ! command -v brew &>/dev/null; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
log "Homebrew ready: $(brew --version | head -1)"

# ── Clone / pull this repo ────────────────────────────────────────────
section "Repository"
if [[ ! -d "$REPO_DIR" ]]; then
  log "Cloning mac-bootstrap into $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
else
  log "Updating existing repo"
  git -C "$REPO_DIR" pull --ff-only || warn "Could not fast-forward; continuing with local state."
fi
cd "$REPO_DIR"

# ── Workspace directories ──────────────────────────────────────────────
section "Workspace"
mkdir -p "$HOME/Developer" "$HOME/.config" "$HOME/.local/bin" "$HOME/.local/share"
log "Created ~/Developer, ~/.config, ~/.local/bin, ~/.local/share"

# ── macOS defaults ─────────────────────────────────────────────────────
section "macOS defaults"
log "Key repeat: fast, no press-and-hold"
defaults write -g KeyRepeat -int 2
defaults write -g InitialKeyRepeat -int 15
defaults write -g ApplePressAndHoldEnabled -bool false

log "Finder: show extensions, hidden files"
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write com.apple.finder AppleShowAllFiles -bool true

log "Screenshots → ~/Screenshots"
mkdir -p "$HOME/Screenshots"
defaults write com.apple.screencapture location -string "$HOME/Screenshots"

log "Dock: auto-hide, no delay"
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0.3

log "Disable .DS_Store on network volumes"
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

killall Finder 2>/dev/null || true
killall Dock 2>/dev/null || true

# =========================================================================
# PHASE 1: Install everything (non-interactive except sudo for chsh)
# =========================================================================

# ── Brewfile ──────────────────────────────────────────────────────────
section "Packages (Brewfile)"
log "Installing packages (this takes a while on a fresh machine)..."
brew bundle --file=Brewfile

# ── App CLIs (symlink into PATH) ───────────────────────────────────────
section "App CLI commands"
if [[ -d "/Applications/Visual Studio Code - Insiders.app" ]]; then
  ln -sf "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code" /opt/homebrew/bin/code-insiders
  log "code-insiders → PATH"
fi
if [[ -d "/Applications/Zed.app" ]]; then
  ln -sf "/Applications/Zed.app/Contents/MacOS/cli" /opt/homebrew/bin/zed
  log "zed → PATH"
fi

# ── Fish shell ────────────────────────────────────────────────────────
section "Shell: fish"
FISH_PATH="$(brew --prefix)/bin/fish"
if ! grep -qxF "$FISH_PATH" /etc/shells 2>/dev/null; then
  log "Adding fish to /etc/shells"
  echo "$FISH_PATH" | sudo tee -a /etc/shells > /dev/null
fi
if [[ "$SHELL" != "$FISH_PATH" ]]; then
  log "Setting fish as default shell"
  if [[ -t 0 ]] || [[ -e "$TTY" ]]; then
    chsh -s "$FISH_PATH" < "$TTY" 2>/dev/null || warn "chsh failed — run 'chsh -s $FISH_PATH' manually"
  else
    warn "No tty available — run 'chsh -s $FISH_PATH' manually to switch to fish"
  fi
fi
log "Default shell: $FISH_PATH"

# ── fzf key bindings ──────────────────────────────────────────────────
# fish bindings are sourced directly from config.fish; this installs bash/zsh.
log "Installing fzf key bindings"
"$(brew --prefix)/opt/fzf/install" --key-bindings --completion --no-update-rc 2>/dev/null || true

# ── Fisher + Tide ──────────────────────────────────────────────────────
section "Fish plugins (Fisher + Tide)"
log "Installing Tide prompt"
fish -c "fisher install IlanCosman/tide@v6" || warn "Tide install failed"
log "Installing Sponge (clean history)"
fish -c "fisher install meaningful-ooo/sponge" || warn "Sponge install failed"

# ── Git globals ───────────────────────────────────────────────────────
section "Git config"
log "Configuring git globals"
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global rerere.enabled true

# ── SSH → 1Password agent ─────────────────────────────────────────────
section "SSH config"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if ! grep -qF "1Password" "$HOME/.ssh/config" 2>/dev/null; then
  log "Configuring SSH to use 1Password agent"
  cat >> "$HOME/.ssh/config" << 'EOF'

# 1Password SSH agent
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
EOF
fi
chmod 600 "$HOME/.ssh/config"

# ── GitHub CLI settings ───────────────────────────────────────────────
log "Setting gh to use SSH"
gh config set git_protocol ssh 2>/dev/null || true

# ── herdr ─────────────────────────────────────────────────────────────
section "herdr"
if ! command -v herdr &>/dev/null; then
  log "Installing herdr"
  curl -fsSL https://herdr.dev/install.sh | sh
else
  log "Already installed."
fi

# ── opencode ──────────────────────────────────────────────────────────
section "opencode"
if [[ ! -x "$HOME/.opencode/bin/opencode" ]]; then
  log "Installing opencode"
  curl -fsSL https://opencode.ai/install | bash
else
  log "Already installed."
fi

# ── mise ──────────────────────────────────────────────────────────────
section "mise"
log "Writing mise global config"
mkdir -p "$HOME/.config/mise"
cat > "$HOME/.config/mise/config.toml" << 'EOF'
# Global toolchain pins. Override per-project with .mise.toml or .tool-versions.
[tools]
go         = "latest"
node       = "lts"
pnpm       = "10"
python     = "3.12"
dotnet     = "9"
opentofu   = "latest"
terraform  = "latest"
"npm:@playwright/test" = "latest"   # Node CLI for codegen, trace viewer, ad-hoc
"npm:@playwright/mcp"  = "latest"   # Microsoft's official Playwright MCP server

[settings]
experimental = true
EOF
log "Installing mise toolchains"
mise install || warn "Some mise tools may have failed; run 'mise install' manually later."

# ── Browser automation (Playwright + browser-use) ────────────────────
section "Browser automation"

# Python Playwright + browser-use, isolated via uv tool
if command -v uv &>/dev/null; then
  log "Installing Python Playwright via uv tool"
  uv tool install --upgrade playwright || warn "Python Playwright install failed"

  log "Installing browser-use (LLM-driven browser agent)"
  uv tool install --upgrade browser-use || warn "browser-use install failed"
else
  warn "uv not on PATH — skipping Python browser tools"
fi

# Warm browser binary cache (shared between Node and Python Playwright at
# ~/Library/Caches/ms-playwright/). Installing via either CLI covers both.
if command -v playwright &>/dev/null; then
  log "Installing Playwright browsers (chromium, firefox, webkit)"
  playwright install chromium firefox webkit || warn "Browser install failed"
else
  warn "playwright CLI not on PATH yet — run 'mise install' then 'playwright install' manually"
fi

log "Opening System Settings for browser permissions"
log "Grant Accessibility + Screen Recording to: Ghostty, Chromium, Firefox, WebKit"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true

# ── chezmoi ───────────────────────────────────────────────────────────
section "Dotfiles (chezmoi)"
log "Pointing chezmoi at $REPO_DIR/home"
mkdir -p "$HOME/.config/chezmoi"
cat > "$HOME/.config/chezmoi/chezmoi.toml" << EOF
sourceDir = "${REPO_DIR}/home"
EOF
log "Applying dotfiles"
chezmoi apply

# ── API keys → fish conf.d ───────────────────────────────────────────
section "Secrets"
log "Writing API key functions to fish conf.d"
mkdir -p "$HOME/.config/fish/conf.d"
cat > "$HOME/.config/fish/conf.d/secrets.fish" << ENDFISH
# Managed by bootstrap.sh — do not edit by hand.
# Lazy-loaded: call the function to read the key from 1Password.
function opencode-key
  op read "op://${OP_VAULT}/opencode-api-key/password"
end
function anthropic-key
  op read "op://${OP_VAULT}/anthropic-api-key/password"
end
function openai-key
  op read "op://${OP_VAULT}/openai-api-key/password"
end
function context7-key
  op read "op://${OP_VAULT}/context7-api-key/password"
end
function devto-key
  op read "op://${OP_VAULT}/devto-api-key/password"
end
function oreilly-key
  op read "op://${OP_VAULT}/oreilly-api-token/password"
end
function google-key
  op read "op://${OP_VAULT}/google-api-key/password"
end

# Export all keys into the current shell's environment.
# Call once per session (or from config.local.fish) when env vars are needed.
function export-keys
  set -gx OPENCODE_API_KEY   (opencode-key)
  set -gx ANTHROPIC_API_KEY  (anthropic-key)
  set -gx OPENAI_API_KEY     (openai-key)
  set -gx CONTEXT7_API_KEY   (context7-key)
  set -gx DEVTO_API_KEY      (devto-key)
  set -gx OREILLY_API_TOKEN  (oreilly-key)
  set -gx GOOGLE_API_KEY     (google-key)
end
ENDFISH
chmod 600 "$HOME/.config/fish/conf.d/secrets.fish"

# =========================================================================
# PHASE 2: Interactive auth — one prompt at a time
# =========================================================================

section "Authentication"

# ── 1Password ─────────────────────────────────────────────────────────
echo ""
if op account list 2>/dev/null | grep -q .; then
  log "1Password CLI already configured."
else
  prompt "1Password CLI is not configured."
  log "One-time setup in the 1Password desktop app:"
  log "  1. Open 1Password and sign into your account (my.1password.com)"
  log "  2. Settings → Developer → enable:"
  log "       • Integrate with 1Password CLI"
  log "       • Use the SSH agent"
  log "       • Biometric unlock for 1Password CLI"
  log "  3. Then run: eval \"\$(op signin)\""
  echo ""
  prompt "Press Enter after you've completed the steps above..."
  read -r < "$TTY"
fi

log "Signing in to 1Password CLI"
eval "$(op signin)" || warn "1Password sign-in failed; API key functions won't work until you sign in."

# ── GitHub CLI ────────────────────────────────────────────────────────
echo ""
if gh auth status &>/dev/null; then
  log "gh already authenticated."
else
  prompt "GitHub CLI: a browser will open for SSO login."
  prompt "Press Enter to continue..."
  read -r < "$TTY"
  gh auth login --web || warn "gh auth login failed; run it manually with 'gh auth login --web'."
fi

# ── opencode config (private repo — needs auth) ──────────────────────
echo ""
if [[ -n "$OPENCODE_CONFIG_REPO" ]]; then
  log "Cloning opencode config repo"
  if [[ ! -d "$HOME/.local/share/opencode-config" ]]; then
    git clone "$OPENCODE_CONFIG_REPO" "$HOME/.local/share/opencode-config" 2>&1 || warn "Config repo clone failed (check SSH key and repo access)."
  else
    git -C "$HOME/.local/share/opencode-config" pull --ff-only || true
  fi
  if [[ -f "$HOME/.local/share/opencode-config/config.json" ]]; then
    log "Linking opencode config.json"
    mkdir -p "$HOME/.config/opencode"
    ln -sf "$HOME/.local/share/opencode-config/config.json" "$HOME/.config/opencode/config.json"
  fi
fi

# ── agent skills (→ ~/.agents/skills/) ──────────────────────────────
echo ""
if [[ -n "$OPENCODE_SKILLS_REPO" ]]; then
  log "Cloning skills repo into ~/.agents/skills"
  if [[ ! -d "$HOME/.agents/skills" ]]; then
    git clone "$OPENCODE_SKILLS_REPO" "$HOME/.agents/skills" 2>&1 || warn "Skills clone failed (check SSH key)."
  else
    git -C "$HOME/.agents/skills" pull --ff-only || true
  fi
fi

# ── Doctor ──────────────────────────────────────────────────────────────
section "Doctor"
local pass=0 fail=0
check() {
  if command -v "$1" &>/dev/null; then
    printf "  \033[1;32m✓\033[0m %s\n" "$1"
    ((pass++)) || true
  else
    printf "  \033[1;31m✗\033[0m %-24s (not on PATH)\n" "$1"
    ((fail++)) || true
  fi
}
check fish;   check mise;   check op;     check gh
check chezmoi; check herdr; check opencode
check aws;    check kubectl; check helm
check playwright; check uv; check colima

echo ""
if [[ $fail -eq 0 ]]; then
  log "All $pass checks passed."
else
  warn "$pass passed, $fail missing — review the output above."
fi

# =========================================================================
# Done
# =========================================================================
echo ""
section "Bootstrap complete"
log "Open a new terminal to start fish."
echo ""
log "Next steps:"
log "  aws sso login --profile <your-profile>"
log "  mise install   # if any tools need (re)installing"
log "  Sign in to desktop apps (Slack, VS Code, etc.)"
