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

# When piped from curl, stdin is the script itself — re-open from the tty so
# interactive prompts (read, sudo, chsh, op signin, gh auth) work in Phase 2.
if [[ ! -t 0 ]]; then
  if [[ -e /dev/tty ]]; then
    exec < /dev/tty
  else
    die "No tty available — run the script from a cloned checkout instead of piping curl."
  fi
fi

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

# =========================================================================
# PHASE 1: Install everything (non-interactive except sudo for chsh)
# =========================================================================

# ── Brewfile ──────────────────────────────────────────────────────────
section "Packages (Brewfile)"
log "Installing packages (this takes a while on a fresh machine)..."
brew bundle --file=Brewfile

# ── Fish shell ────────────────────────────────────────────────────────
section "Shell: fish"
FISH_PATH="$(brew --prefix)/bin/fish"
if ! grep -qxF "$FISH_PATH" /etc/shells 2>/dev/null; then
  log "Adding fish to /etc/shells"
  echo "$FISH_PATH" | sudo tee -a /etc/shells > /dev/null
fi
if [[ "$SHELL" != "$FISH_PATH" ]]; then
  log "Setting fish as default shell"
  chsh -s "$FISH_PATH"
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

# ── agent skills (→ ~/.agents/skills/) ────────────────────────────────
# Uses SSH if OPENCODE_SKILLS_REPO is a git@ URL — requires the 1Password SSH
# agent (Phase 2) to already be enabled in the desktop app, or this clone
# fails. Failure is non-fatal: rerun the script after enabling the agent.
if [[ -n "$OPENCODE_SKILLS_REPO" ]]; then
  log "Cloning skills repo into ~/.agents/skills"
  if [[ ! -d "$HOME/.agents/skills" ]]; then
    git clone "$OPENCODE_SKILLS_REPO" "$HOME/.agents/skills" \
      || warn "Skills clone failed — enable the 1Password SSH agent and rerun the bootstrap."
  else
    git -C "$HOME/.agents/skills" pull --ff-only || true
  fi
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

[settings]
experimental = true
EOF
log "Installing mise toolchains"
mise install || warn "Some mise tools may have failed; run 'mise install' manually later."

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
  read -r
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
  read -r
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
