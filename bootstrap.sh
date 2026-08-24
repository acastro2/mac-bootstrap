#!/usr/bin/env bash
# bootstrap.sh — one-shot macOS workstation setup
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/acastro2/mac-bootstrap/main/bootstrap.sh | bash
#   ./bootstrap.sh
#   ./bootstrap.sh --skip=macos-defaults,auth,shell  --only=brew,mise
#   ./bootstrap.sh --clean                     # remove managed artifacts before a fresh re-run
#   ./bootstrap.sh --export-sessions           # pack session data to ~/Desktop for airdrop
#   ./bootstrap.sh --export-workspace          # pack ~/Developer (minus org repos) for airdrop
#   ./bootstrap.sh --import-sessions=<file>    # restore session data from tarball
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
# Defaults — override by creating config.env next to this script.
OP_VAULT=""
GIT_NAME=""
GIT_EMAIL=""
REPO_URL="https://github.com/acastro2/mac-bootstrap.git"
REPO_DIR="${HOME}/Developer/github/acastro2/mac-bootstrap"
OPENCODE_CONFIG_REPO=""
OPENCODE_SKILLS_REPO=""
CLAUDE_CONFIG_REPO=""
PI_CONFIG_REPO=""

# Source personal config if present (gitignored, not committed).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/config.env"
fi

TTY="/dev/tty"

should_run() {
  local name="$1"
  [[ -n "$ONLY" ]] && [[ ",$ONLY," != *",$name,"* ]] && return 1
  [[ -n "$SKIP" ]] && [[ ",$SKIP," == *",$name,"* ]] && return 1
  return 0
}

log()   { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m==>\033[0m %s\n" "$*"; }
prompt(){ printf "\n\033[1;35m??\033[0m %s\n" "$*"; }
die()   { printf "\033[1;31m==>\033[0m %s\n" "$*"; exit 1; }
section(){ printf "\n\033[1;37m━━━ %s ━━━\033[0m\n" "$*"; }

# ── Selective re-run flags ──────────────────────────────────────────
SKIP=""
ONLY=""
CLEAN=false
EXPORT_SESSIONS=false
EXPORT_WORKSPACE=false
IMPORT_SESSIONS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip=*) SKIP="${1#*=}"; shift ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    -s|--skip) SKIP="$2"; shift 2 ;;
    -o|--only) ONLY="$2"; shift 2 ;;
    --clean) CLEAN=true; shift ;;
    --export-sessions) EXPORT_SESSIONS=true; shift ;;
    --export-workspace) EXPORT_WORKSPACE=true; shift ;;
    --import-sessions=*) IMPORT_SESSIONS="${1#*=}"; shift ;;
    --import-sessions) IMPORT_SESSIONS="$2"; shift 2 ;;
    *) warn "Unknown argument: $1"; shift ;;
  esac
done

# ── Export sessions (creates a tarball for airdrop) ────────────────────
if $EXPORT_SESSIONS; then
  section "Export sessions"
  EXPORT_DIR="$HOME/Desktop"
  EXPORT_FILE="$EXPORT_DIR/agent-sessions-$(date +%Y%m%d-%H%M%S).tar.gz"

  PATHS_TO_EXPORT=()

  # opencode sessions database
  if [[ -f "$HOME/.local/share/opencode/opencode.db" ]]; then
    PATHS_TO_EXPORT+=(".local/share/opencode/opencode.db")
  fi

  # Claude Code conversations and session index
  if [[ -d "$HOME/.claude/projects" ]]; then
    PATHS_TO_EXPORT+=(".claude/projects")
  fi
  if [[ -f "$HOME/.claude/history.jsonl" ]]; then
    PATHS_TO_EXPORT+=(".claude/history.jsonl")
  fi
  if [[ -d "$HOME/.claude/sessions" ]]; then
    PATHS_TO_EXPORT+=(".claude/sessions")
  fi

  # Claude Code account state (project settings, feature flags)
  if [[ -f "$HOME/.claude.json" ]]; then
    PATHS_TO_EXPORT+=(".claude.json")
  fi

  # Claude Desktop app config
  CLAUDE_DESKTOP="Library/Application Support/Claude"
  if [[ -f "$HOME/$CLAUDE_DESKTOP/claude_desktop_config.json" ]]; then
    PATHS_TO_EXPORT+=("$CLAUDE_DESKTOP/claude_desktop_config.json")
  fi

  # Cortex Code plans (per-project, scattered under ~/Developer)
  if [[ -d "$HOME/Developer" ]]; then
    while IFS= read -r -d '' cortex_dir; do
      rel_path="${cortex_dir#"$HOME/"}"
      PATHS_TO_EXPORT+=("$rel_path")
    done < <(find "$HOME/Developer" -name ".cortex" -type d -print0 2>/dev/null)
  fi
  # Cortex Code sessions, settings, and connection config (skip cache, it rebuilds)
  if [[ -d "$HOME/.snowflake/cortex/conversations" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/conversations")
  fi
  if [[ -f "$HOME/.snowflake/cortex/settings.json" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/settings.json")
  fi
  if [[ -f "$HOME/.snowflake/cortex/cortex.json" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/cortex.json")
  fi
  if [[ -f "$HOME/.snowflake/cortex/permissions.json" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/permissions.json")
  fi
  if [[ -f "$HOME/.snowflake/cortex/skills.json" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/skills.json")
  fi
  if [[ -d "$HOME/.snowflake/cortex/skills" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/skills")
  fi
  if [[ -d "$HOME/.snowflake/cortex/plugins" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/plugins")
  fi
  if [[ -d "$HOME/.snowflake/cortex/commands" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/commands")
  fi
  if [[ -f "$HOME/.snowflake/cortex/thread_goals.sqlite" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/thread_goals.sqlite")
  fi
  if [[ -d "$HOME/.snowflake/cortex/history" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/cortex/history")
  fi
  # Snowflake connection config (shared between cortex and snowflake-cli)
  if [[ -f "$HOME/.snowflake/connections.toml" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/connections.toml")
  fi
  if [[ -f "$HOME/.snowflake/config.toml" ]]; then
    PATHS_TO_EXPORT+=(".snowflake/config.toml")
  fi

  if [[ ${#PATHS_TO_EXPORT[@]} -eq 0 ]]; then
    die "Nothing to export: no session data found."
  fi

  log "Packing ${#PATHS_TO_EXPORT[@]} paths into $EXPORT_FILE"
  tar -czf "$EXPORT_FILE" -C "$HOME" "${PATHS_TO_EXPORT[@]}"
  log "Export complete: $(du -h "$EXPORT_FILE" | cut -f1) → $EXPORT_FILE"
  log "AirDrop this file to the target machine, then run:"
  log "  ./bootstrap.sh --import-sessions=$EXPORT_FILE"
  exit 0
fi

# ── Export workspace (packs ~/Developer minus org repos) ───────────────
# Creates a tarball of personal/non-org projects for airdrop transfer.
# Excludes: Engineering-Attain-Finance, Data-Engineering-Attain-Finance,
# .venv, node_modules, .terraform, __pycache__, .git objects (keeps .git/HEAD + refs)
if $EXPORT_WORKSPACE; then
  section "Export workspace"
  EXPORT_DIR="$HOME/Desktop"
  EXPORT_FILE="$EXPORT_DIR/workspace-$(date +%Y%m%d-%H%M%S).tar.gz"

  log "Packing ~/Developer (excluding org repos and regenerable artifacts)"
  tar -czf "$EXPORT_FILE" -C "$HOME" \
    --exclude="Developer/Engineering-Attain-Finance" \
    --exclude="Developer/Data-Engineering-Attain-Finance" \
    --exclude=".venv" \
    --exclude="node_modules" \
    --exclude=".terraform" \
    --exclude="__pycache__" \
    --exclude=".mypy_cache" \
    --exclude=".pytest_cache" \
    --exclude=".ruff_cache" \
    Developer

  log "Export complete: $(du -h "$EXPORT_FILE" | cut -f1) → $EXPORT_FILE"
  log "AirDrop this file to the target machine, then extract with:"
  log "  tar -xzf $EXPORT_FILE -C \$HOME"
  exit 0
fi

# ── Import sessions (restores from airdrop tarball) ────────────────────
if [[ -n "$IMPORT_SESSIONS" ]]; then
  section "Import sessions"
  if [[ ! -f "$IMPORT_SESSIONS" ]]; then
    die "File not found: $IMPORT_SESSIONS"
  fi

  log "Listing contents of $IMPORT_SESSIONS:"
  tar -tzf "$IMPORT_SESSIONS" | head -20
  echo ""

  # Remove existing session data so the import is a clean replacement
  log "Cleaning existing session data before import"
  rm -f "$HOME/.local/share/opencode/opencode.db" 2>/dev/null || true
  rm -rf "$HOME/.claude/projects" 2>/dev/null || true
  rm -f "$HOME/.claude/history.jsonl" 2>/dev/null || true
  rm -rf "$HOME/.claude/sessions" 2>/dev/null || true
  rm -f "$HOME/.claude.json" 2>/dev/null || true
  rm -rf "$HOME/.snowflake/cortex/conversations" 2>/dev/null || true
  rm -f "$HOME/.snowflake/cortex/settings.json" 2>/dev/null || true
  rm -f "$HOME/.snowflake/cortex/cortex.json" 2>/dev/null || true
  rm -f "$HOME/.snowflake/cortex/permissions.json" 2>/dev/null || true
  rm -f "$HOME/.snowflake/cortex/skills.json" 2>/dev/null || true
  rm -rf "$HOME/.snowflake/cortex/skills" 2>/dev/null || true
  rm -rf "$HOME/.snowflake/cortex/plugins" 2>/dev/null || true
  rm -rf "$HOME/.snowflake/cortex/commands" 2>/dev/null || true
  rm -f "$HOME/.snowflake/cortex/thread_goals.sqlite" 2>/dev/null || true
  rm -rf "$HOME/.snowflake/cortex/history" 2>/dev/null || true
  rm -f "$HOME/.snowflake/connections.toml" 2>/dev/null || true
  rm -f "$HOME/.snowflake/config.toml" 2>/dev/null || true
  # Per-project .cortex dirs: only remove if tarball contains Developer paths
  if tar -tzf "$IMPORT_SESSIONS" | grep -q "^Developer/"; then
    find "$HOME/Developer" -name ".cortex" -type d -exec rm -rf {} + 2>/dev/null || true
  fi

  log "Extracting into $HOME"
  mkdir -p "$HOME/.local/share/opencode" "$HOME/.claude" "$HOME/.snowflake/cortex"
  tar -xzf "$IMPORT_SESSIONS" -C "$HOME"
  log "Import complete. Session data restored."
  exit 0
fi

# ── Cleanup mode ───────────────────────────────────────────────────────
# Removes managed artifacts so re-running the script produces a clean state.
# Does NOT uninstall Homebrew itself or remove ~/Developer.
if $CLEAN; then
  section "Cleanup (preparing for fresh bootstrap)"

  log "Removing Homebrew packages (keeping Homebrew itself)"
  brew_formulae=()
  while IFS= read -r package; do brew_formulae+=("$package"); done < <(brew list --formula)
  brew_casks=()
  while IFS= read -r package; do brew_casks+=("$package"); done < <(brew list --cask)
  ((${#brew_formulae[@]} == 0)) || brew remove --force --ignore-dependencies "${brew_formulae[@]}" 2>/dev/null || true
  ((${#brew_casks[@]} == 0)) || brew remove --force --cask "${brew_casks[@]}" 2>/dev/null || true
  brew cleanup --prune=all 2>/dev/null || true

  log "Removing mise toolchains"
  rm -rf "$HOME/.local/share/mise" "$HOME/.config/mise" 2>/dev/null || true

  log "Removing opencode binary"
  rm -rf "$HOME/.opencode" 2>/dev/null || true

  log "Removing claude code (native + any legacy npm global)"
  rm -rf "$HOME/.local/share/claude" 2>/dev/null || true
  rm -f "$HOME/.local/bin/claude" 2>/dev/null || true
  npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true

  log "Removing herdr"
  rm -f "$(command -v herdr 2>/dev/null)" 2>/dev/null || true

  log "Removing chezmoi state"
  rm -rf "$HOME/.config/chezmoi" 2>/dev/null || true

  log "Removing Zsh/Zim managed files"
  rm -rf "$HOME/.zim" 2>/dev/null || true
  rm -f "$HOME/.zshrc" "$HOME/.zimrc" 2>/dev/null || true
  rm -rf "$HOME/.config/zsh" 2>/dev/null || true
  rm -rf "$HOME/.cache/carapace" 2>/dev/null || true

  log "Removing legacy Nushell configs"
  rm -rf "$HOME/.config/nushell" "$HOME/.local/share/nushell" \
    "$HOME/Library/Application Support/nushell" 2>/dev/null || true

  log "Removing app CLI symlinks"
  rm -f "$HOME/.local/bin/code-insiders" "$HOME/.local/bin/zed" 2>/dev/null || true
  rm -f "$HOME/.docker/cli-plugins/docker-compose" 2>/dev/null || true

  log "Cleanup complete. Re-run without --clean to reinstall."
  exit 0
fi

# ── Sanity checks ────────────────────────────────────────────────────
IS_MACOS=false
[[ "$(uname)" == "Darwin" ]] && IS_MACOS=true
if ! $IS_MACOS; then
  log "Running on non-macOS ($(uname)). macOS-specific sections will be skipped."
fi

# sudo is only needed when the login shell has to change or /etc/shells must
# be edited; it is requested lazily in those branches.

# =========================================================================
# PHASE 0: Prerequisites
# =========================================================================

# ── Xcode Command Line Tools ──────────────────────────────────────────
if should_run xcode && $IS_MACOS; then
section "Xcode Command Line Tools"
if ! xcode-select -p &>/dev/null; then
  log "Installing Xcode Command Line Tools (a dialog will pop up)"
  xcode-select --install
  warn "Wait for the install to finish, then re-run this script."
  exit 0
fi
log "Already installed."
fi

# ── Homebrew ──────────────────────────────────────────────────────────
if should_run brew; then
section "Homebrew"
if ! command -v brew &>/dev/null; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
fi
log "Homebrew ready: $(brew --version | head -1)"
fi

# ── Clone / pull this repo ────────────────────────────────────────────
if should_run repo; then
section "Repository"
if [[ ! -d "$REPO_DIR" ]]; then
  log "Cloning mac-bootstrap into $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
else
  log "Updating existing repo"
  git -C "$REPO_DIR" pull --ff-only || warn "Could not fast-forward; continuing with local state."
fi
fi

if [[ -d "$REPO_DIR" ]]; then
  cd "$REPO_DIR"
fi

# ── Workspace directories ──────────────────────────────────────────────
if should_run workspace; then
section "Workspace"
mkdir -p "$HOME/Developer/github/acastro2" "$HOME/.config" "$HOME/.local/bin" "$HOME/.local/share"
log "Created ~/Developer/github/acastro2, ~/.config, ~/.local/bin, ~/.local/share"
fi

# ── macOS defaults ─────────────────────────────────────────────────────
if should_run macos-defaults && $IS_MACOS; then
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

log "Appearance: dark"
defaults write NSGlobalDomain AppleInterfaceStyle -string Dark

log "Accent color: orange"
defaults write NSGlobalDomain AppleAccentColor -int 1

log "Some changes require logout/login to take full effect."
fi

# =========================================================================
# PHASE 1: Install everything (non-interactive except sudo for chsh)
# =========================================================================

# ── Brewfile ──────────────────────────────────────────────────────────
if should_run packages; then
section "Packages (Brewfile)"
log "Installing packages (this takes a while on a fresh machine)..."
if $IS_MACOS; then
  log "Using Brewfile (macOS)"
  brew bundle --file=Brewfile
else
  log "Using Brewfile.linux"
  brew bundle --file=Brewfile.linux
fi

log "Configuring Docker Compose for Colima"
if command -v docker &>/dev/null; then
  DOCKER_COMPOSE_PLUGIN="$(brew --prefix)/opt/docker-compose/bin/docker-compose"
  if [[ -x "$DOCKER_COMPOSE_PLUGIN" ]]; then
    mkdir -p "$HOME/.docker/cli-plugins"
    ln -sfn "$DOCKER_COMPOSE_PLUGIN" "$HOME/.docker/cli-plugins/docker-compose"
    log "Docker Compose plugin linked for 'docker compose'"
  else
    warn "Docker Compose plugin not found at $DOCKER_COMPOSE_PLUGIN."
  fi
else
  warn "Docker CLI not found after package installation."
fi
fi

# ── App CLIs (symlink into PATH) ───────────────────────────────────────
if should_run app-clis && $IS_MACOS; then
section "App CLI commands"
mkdir -p "$HOME/.local/bin"
if [[ -d "/Applications/Visual Studio Code - Insiders.app" ]]; then
  ln -sf "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code" "$HOME/.local/bin/code-insiders"
  log "code-insiders → PATH"
fi
if [[ -d "/Applications/Zed.app" ]]; then
  ln -sf "/Applications/Zed.app/Contents/MacOS/cli" "$HOME/.local/bin/zed"
  log "zed → PATH"
fi
fi

# ── Shell: Zsh + Zim ──────────────────────────────────────────────────
if should_run zsh; then
section "Shell: Zsh + Zim"
ZSH_BIN="$(command -v zsh || echo /bin/zsh)"
[[ -x "$ZSH_BIN" ]] || die "zsh is not installed at $ZSH_BIN. Run the packages section first."

log "Applying dotfiles before validating the shell"
mkdir -p "$HOME/.config/chezmoi"
cat > "$HOME/.config/chezmoi/chezmoi.toml" << EOF
sourceDir = "${REPO_DIR}/home"
EOF
chezmoi apply

log "Preparing private zsh files"
mkdir -p "$HOME/.config/zsh"
[[ -f "$HOME/.config/zsh/.api-keys.zsh" ]] || : > "$HOME/.config/zsh/.api-keys.zsh"
chmod 600 "$HOME/.config/zsh/.api-keys.zsh"
touch "$HOME/.config/zsh/local.zsh"

if command -v opencode &>/dev/null; then
  log "Caching opencode completions"
  opencode completion zsh > "$HOME/.config/zsh/opencode-completions.zsh" 2>/dev/null \
    || warn "opencode completion generation failed; skipping."
else
  warn "opencode not found yet; its completions will be missing until you re-run this section."
fi

log "Validating zsh files"
while IFS= read -r zsh_file; do
  "$ZSH_BIN" -n "$zsh_file" || die "Invalid zsh file: $zsh_file"
done < <(find "$HOME/.config/zsh" -maxdepth 1 -type f -name '*.zsh' -print; echo "$HOME/.zshrc"; echo "$HOME/.zimrc")

log "Validating zsh starts cleanly with all zim modules (first run downloads zimfw)"
SMOKE_OUT="$("$ZSH_BIN" -ic 'true' </dev/null 2>&1)" \
  || { printf '%s\n' "$SMOKE_OUT"; die "zsh failed to start with ~/.zshrc"; }

log "Validating zsh drops inherited AWS environment state"
# shellcheck disable=SC2016 # ${VAR:-} belongs to zsh, not Bash.
env AWS_ACCESS_KEY_ID=bootstrap-test \
  AWS_SECRET_ACCESS_KEY=bootstrap-test \
  AWS_SESSION_TOKEN=bootstrap-test \
  AWS_PROFILE=bootstrap-test \
  "$ZSH_BIN" -ic '[[ -z "${AWS_ACCESS_KEY_ID:-}" && -z "${AWS_SECRET_ACCESS_KEY:-}" && -z "${AWS_SESSION_TOKEN:-}" && -z "${AWS_PROFILE:-}" ]]' </dev/null \
  || die "zsh retained inherited AWS credentials or profile"

log "zsh configuration validated"
fi

# ── Login shell + Nushell removal ──────────────────────────────────────
if should_run shell; then
section "Login shell"

if $IS_MACOS; then
  EXPECTED_SHELL="/bin/zsh"
  ACCOUNT_SHELL="$(dscl . -read "/Users/$USER" UserShell | awk '{print $2}')"
else
  EXPECTED_SHELL="$(command -v zsh)"
  ACCOUNT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
fi
[[ -n "$EXPECTED_SHELL" ]] || die "zsh binary not found."

if [[ "$ACCOUNT_SHELL" != "$EXPECTED_SHELL" ]]; then
  log "Switching the login shell from '$ACCOUNT_SHELL' to '$EXPECTED_SHELL'"
  if ! grep -qxF "$EXPECTED_SHELL" /etc/shells 2>/dev/null; then
    log "Adding $EXPECTED_SHELL to /etc/shells"
    echo "$EXPECTED_SHELL" | sudo tee -a /etc/shells > /dev/null \
      || die "Could not update /etc/shells."
  fi
  if $IS_MACOS; then
    sudo dscl . -create "/Users/$USER" UserShell "$EXPECTED_SHELL" \
      || die "Could not set the login shell. Nushell is untouched."
    ACCOUNT_SHELL="$(dscl . -read "/Users/$USER" UserShell | awk '{print $2}')"
  else
    sudo chsh -s "$EXPECTED_SHELL" "$USER" \
      || die "Could not set the login shell. Nushell is untouched."
    ACCOUNT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
  fi
  [[ "$ACCOUNT_SHELL" == "$EXPECTED_SHELL" ]] \
    || die "Login shell readback returned '$ACCOUNT_SHELL'. Nushell is untouched."
else
  log "Login shell already $EXPECTED_SHELL"
fi

log "Removing Nushell"
NU_PATH="$(brew --prefix)/bin/nu"
if brew list --formula nushell &>/dev/null; then
  brew uninstall --force nushell || die "Failed to uninstall Nushell"
fi
brew list --formula nushell &>/dev/null && die "Nushell is still installed; keeping its config for recovery"
[[ -x "$NU_PATH" ]] && die "Nushell binary still present at $NU_PATH"
if grep -qxF "$NU_PATH" /etc/shells 2>/dev/null; then
  sudo sed -i.bak "\|^${NU_PATH}\$|d" /etc/shells
  sudo rm -f /etc/shells.bak
fi
rm -rf "$HOME/.config/nushell" "$HOME/.local/share/nushell"
rm -rf "$HOME/Library/Application Support/nushell"
log "Default shell: $ACCOUNT_SHELL"
fi

# ── Git globals ───────────────────────────────────────────────────────
if should_run git; then
section "Git config"
if [[ -n "$GIT_NAME" || -n "$GIT_EMAIL" ]]; then
  log "Configuring git identity"
else
  warn "GIT_NAME/GIT_EMAIL not set in config.env; keeping the current git identity."
fi
[[ -n "$GIT_NAME" ]] && git config --global user.name "$GIT_NAME"
[[ -n "$GIT_EMAIL" ]] && git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global rerere.enabled true
fi

# ── SSH → 1Password agent ─────────────────────────────────────────────
if should_run ssh; then
  section "SSH config"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  { ssh-keyscan github.com 2>/dev/null; [[ -f "$HOME/.ssh/known_hosts" ]] && cat "$HOME/.ssh/known_hosts"; } | sort -u > "$HOME/.ssh/known_hosts.tmp" && mv "$HOME/.ssh/known_hosts.tmp" "$HOME/.ssh/known_hosts"
  if $IS_MACOS; then
    if ! grep -qF "1Password" "$HOME/.ssh/config" 2>/dev/null; then
      log "Configuring SSH to use 1Password agent"
      cat >> "$HOME/.ssh/config" << 'EOF'

# 1Password SSH agent
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
EOF
    fi
  fi
  [[ -f "$HOME/.ssh/config" ]] && chmod 600 "$HOME/.ssh/config"
fi

# ── herdr ─────────────────────────────────────────────────────────────
if should_run herdr; then
section "herdr"
if ! command -v herdr &>/dev/null; then
  log "Installing herdr"
  curl -fsSL https://herdr.dev/install.sh | sh
else
  log "Already installed."
fi
fi

# ── opencode ──────────────────────────────────────────────────────────
if should_run opencode; then
section "opencode"
if [[ ! -x "$HOME/.opencode/bin/opencode" ]]; then
  log "Installing opencode"
  curl -fsSL https://opencode.ai/install | bash
else
  log "Already installed."
fi
fi

# ── Claude Code CLI ───────────────────────────────────────────────────
if should_run claude; then
section "Claude Code CLI"
if ! command -v claude &>/dev/null; then
  log "Installing Claude Code CLI (native installer)"
  # Native install (~/.local/share/claude, launcher ~/.local/bin/claude).
  # Self-updating, no Node dep. Avoid `npm -g` under mise: a node version
  # switch orphans the binary and triggers dual-install / config mismatch.
  curl -fsSL https://claude.ai/install.sh | bash
else
  log "Already installed: $(claude --version 2>/dev/null || echo 'unknown')"
fi
fi

# ── Snowflake Cortex Code CLI ─────────────────────────────────────────
if should_run cortex; then
section "Cortex Code CLI"
if [[ ! -x "$HOME/.local/bin/cortex" ]]; then
  log "Installing Cortex Code CLI"
  curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | sh
else
  log "Already installed."
fi
fi

# ── tgrep ─────────────────────────────────────────────────────────────
if should_run tgrep; then
section "tgrep"
if ! command -v tgrep &>/dev/null; then
  log "Installing tgrep"
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  TGREP_TARGET="aarch64-apple-darwin" ;;
    Darwin-x86_64) TGREP_TARGET="x86_64-apple-darwin" ;;
    Linux-aarch64) TGREP_TARGET="aarch64-unknown-linux-musl" ;;
    Linux-x86_64)  TGREP_TARGET="x86_64-unknown-linux-musl" ;;
    *) TGREP_TARGET="" ;;
  esac
  if [[ -n "$TGREP_TARGET" ]]; then
    TGREP_TMP="$(mktemp -d)"
    if gh release download --repo microsoft/tgrep -p "*${TGREP_TARGET}*" -D "$TGREP_TMP" 2>/dev/null; then
      tar xzf "$TGREP_TMP"/tgrep-*.tar.gz -C "$TGREP_TMP" tgrep
      install -m 755 "$TGREP_TMP/tgrep" "$HOME/.local/bin/tgrep"
      log "Installed tgrep: $("$HOME/.local/bin/tgrep" --version)"
    else
      warn "tgrep download failed (check gh auth); skipping."
    fi
    rm -rf "$TGREP_TMP"
  else
    warn "No tgrep release for $(uname -s)-$(uname -m); skipping."
  fi
else
  log "Already installed: $(tgrep --version 2>/dev/null || echo 'unknown')"
fi
fi

# ── mise ──────────────────────────────────────────────────────────────
if should_run mise; then
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
"npm:@playwright/test" = "latest"   # Node CLI for codegen, trace viewer, ad-hoc
"npm:@playwright/mcp"  = "latest"   # Microsoft's official Playwright MCP server
"npm:ctx7"             = "latest"   # Context7 documentation CLI
# Trust excludes for AWS's 2026-08-14 release batch: those @smithy versions went out via
# aws-sdk-bot without OIDC/provenance, tripping aube's no-downgrade policy. Verified legit.
"npm:@earendil-works/pi-coding-agent" = { version = "latest", trust_policy_excludes = ["@smithy/core@3.33.0", "@smithy/node-http-handler@4.11.0"] }

[settings]
experimental = true
python.github_attestations = false
EOF
log "Trusting mise config so shells start without a prompt"
mise trust "$HOME/.config/mise/config.toml" \
  || warn "mise trust failed; the first shell may prompt to trust the config."
log "Installing mise toolchains"
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || echo '')}"
mise install || warn "Some mise tools may have failed; run 'mise install' manually later."
fi

# ── Browser automation (Playwright + browser-use) ────────────────────
if should_run browser-automation; then
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

# Warm browser binary cache
if command -v playwright &>/dev/null; then
  log "Installing Playwright browser (chromium)"
  playwright install chromium || warn "Browser install failed"
else
  warn "playwright CLI not on PATH yet — run 'mise install' then 'playwright install' manually"
fi

if $IS_MACOS; then
  log "Opening System Settings for browser permissions"
  log "Grant Accessibility + Screen Recording to: Ghostty, Chromium"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true
fi
fi

# ── chezmoi ───────────────────────────────────────────────────────────
if should_run dotfiles; then
section "Dotfiles (chezmoi)"
log "Pointing chezmoi at $REPO_DIR/home"
mkdir -p "$HOME/.config/chezmoi"
cat > "$HOME/.config/chezmoi/chezmoi.toml" << EOF
sourceDir = "${REPO_DIR}/home"
EOF
log "Applying dotfiles"
chezmoi apply
fi

# ── API keys → zsh ───────────────────────────────────────────────────
if should_run secrets; then
  section "Secrets"
  if [[ -n "$OP_VAULT" ]]; then
  log "zsh will load API keys from ~/.config/zsh/.api-keys.zsh"
  else
  log "OP_VAULT not set — skipping API key setup"
  fi
fi

# =========================================================================
# PHASE 2: Interactive auth — one prompt at a time
# =========================================================================

if should_run auth; then
section "Authentication"

# ── 1Password ─────────────────────────────────────────────────────────
echo ""
if [[ -n "$OP_VAULT" ]]; then
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

  # ── Write API keys in zsh syntax ────────────────────────────────────
  if op account list 2>/dev/null | grep -q .; then
    ZSH_BIN="$(command -v zsh || echo /bin/zsh)"
    ZSH_SECRETS="$HOME/.config/zsh/.api-keys.zsh"
    ZSH_SECRETS_TMP="$ZSH_SECRETS.tmp"
    log "Pulling API keys from 1Password → $ZSH_SECRETS"
    mkdir -p "$HOME/.config/zsh"
    : > "$ZSH_SECRETS_TMP"
    while IFS='|' read -r env_name item_name field_name; do
      secret_value="$(op read "op://${OP_VAULT}/${item_name}/${field_name:-password}" 2>/dev/null || true)"
      # jq -Rs emits a JSON string, which is also a valid single-quoted zsh value.
      printf 'export %s=%s\n' "$env_name" "$(printf '%s' "$secret_value" | jq -Rs .)" >> "$ZSH_SECRETS_TMP"
    done << 'EOF'
OPENCODE_API_KEY|opencode-api-key
OPENAI_API_KEY|openai-api-key
CONTEXT7_API_KEY|context7-api-key
DEVTO_API_KEY|devto-api-key
OREILLY_API_TOKEN|oreilly-api-token
GOOGLE_API_KEY|google-api-key
AZURE_DEVOPS_PAT|ado-pat
GRAFANA_SERVICE_ACCOUNT_TOKEN|grafana-service-account-token
EXA_API_KEY|EXA API Key
RESEND_API_KEY|Resend API Credential|credential
EOF
    chmod 600 "$ZSH_SECRETS_TMP"
    "$ZSH_BIN" -n "$ZSH_SECRETS_TMP" || die "Generated zsh secrets file is invalid"
    mv "$ZSH_SECRETS_TMP" "$ZSH_SECRETS"
  fi
else
  log "OP_VAULT not set — skipping 1Password setup"
fi

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
log "Setting gh to use SSH"
gh config set git_protocol ssh 2>/dev/null || true
log "Configuring gh as git credential helper"
gh auth setup-git 2>/dev/null || true

# ── opencode config (private repo — needs auth) ──────────────────────
echo ""
if [[ -n "$OPENCODE_CONFIG_REPO" ]]; then
  log "Cloning opencode config repo into ~/.config/opencode"
  if [[ ! -d "$HOME/.config/opencode/.git" ]]; then
    gh repo clone "$OPENCODE_CONFIG_REPO" "$HOME/.config/opencode" 2>&1 || warn "Config repo clone failed (check gh auth)."
  else
    git -C "$HOME/.config/opencode" pull --ff-only || true
  fi
fi

# ── Claude Code config (private repo — needs auth) ───────────────────
echo ""
if [[ -n "$CLAUDE_CONFIG_REPO" ]]; then
  log "Cloning Claude Code config repo into ~/.claude"
  if [[ ! -d "$HOME/.claude/.git" ]]; then
    gh repo clone "$CLAUDE_CONFIG_REPO" "$HOME/.claude" 2>&1 || warn "Claude config repo clone failed (check gh auth)."
  else
    git -C "$HOME/.claude" pull --ff-only || true
  fi
fi

# ── Pi config (private repo — needs auth) ────────────────────────────
echo ""
if [[ -n "$PI_CONFIG_REPO" ]]; then
  log "Syncing Pi config repo into ~/.pi"
  if [[ -d "$HOME/.pi/.git" ]]; then
    git -C "$HOME/.pi" pull --ff-only || true
  elif [[ -e "$HOME/.pi" ]]; then
    warn "$HOME/.pi exists and is not a git repo; skipping clone to avoid overwriting it."
  else
    gh repo clone "$PI_CONFIG_REPO" "$HOME/.pi" 2>&1 || warn "Pi config repo clone failed (check gh auth)."
  fi
fi

# ── agent skills (→ ~/.agents/skills/) ──────────────────────────────
echo ""
if [[ -n "$OPENCODE_SKILLS_REPO" ]]; then
  log "Cloning skills repo into ~/.agents/skills"
  if [[ ! -d "$HOME/.agents/skills" ]]; then
    git clone "$OPENCODE_SKILLS_REPO" "$HOME/.agents/skills" 2>&1 || warn "Skills clone failed."
  else
    git -C "$HOME/.agents/skills" pull --ff-only || true
  fi
fi
fi  # auth

# ── Doctor ──────────────────────────────────────────────────────────────
if should_run doctor; then
section "Doctor"
pass=0; fail=0
check() {
  local cmd="$1"
  if command -v "$cmd" &>/dev/null; then
    printf "  \033[1;32m✓\033[0m %s\n" "$cmd"
    pass=$((pass + 1))
  else
    printf "  \033[1;31m✗\033[0m %-24s (not found)\n" "$cmd"
    fail=$((fail + 1))
  fi
}
check_file() {
  if [[ -e "$1" ]]; then
    printf "  \033[1;32m✓\033[0m %s\n" "$2"
    pass=$((pass + 1))
  else
    printf "  \033[1;31m✗\033[0m %-24s (missing)\n" "$2"
    fail=$((fail + 1))
  fi
}
check zsh; check starship; check mise; [[ -n "$OP_VAULT" ]] && check op; check gh
check chezmoi; check herdr; check opencode; check claude; check cortex; check pi; check ctx7; check tgrep
check aws; check az; check gcx; check kubectl; check helm
check playwright; check uv; check colima; check docker
if docker compose version &>/dev/null; then
  printf "  \033[1;32m✓\033[0m docker compose\n"
  pass=$((pass + 1))
else
  printf "  \033[1;31m✗\033[0m %-24s (plugin unavailable)\n" "docker compose"
  fail=$((fail + 1))
fi
check_file "$HOME/.zim/zimfw.zsh" "zim"

if $IS_MACOS; then
  ACCOUNT_SHELL="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
  EXPECTED_SHELL="/bin/zsh"
else
  ACCOUNT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
  EXPECTED_SHELL="$(command -v zsh)"
fi
if [[ "$ACCOUNT_SHELL" == "$EXPECTED_SHELL" ]]; then
  printf "  \033[1;32m✓\033[0m login shell\n"
  pass=$((pass + 1))
else
  printf "  \033[1;31m✗\033[0m %-24s (%s)\n" "login shell" "$ACCOUNT_SHELL"
  fail=$((fail + 1))
fi

echo ""
if [[ $fail -eq 0 ]]; then
  log "All $pass checks passed."
else
  warn "$pass passed, $fail missing — review the output above."
fi
fi

# =========================================================================
# Done
# =========================================================================
echo ""
section "Bootstrap complete"
log "Open a new terminal to start zsh."
echo ""
log "Next steps:"
log "  aws sso login --profile <your-profile>"
log "  mise install   # if any tools need (re)installing"
log "  Sign in to desktop apps (Slack, VS Code, etc.)"
