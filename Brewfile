# Brewfile — the Mac list. The VM uses Brewfile.linux.
# Apply with: den up --only=packages
# The Mac is the window, the keys and the browser; coding happens in the VM.

# ── Both: shell, repos, CLI utilities ─────────────────────────────────
brew "git"
brew "gh"
brew "carapace"
brew "starship"        # cross-shell prompt
brew "chezmoi"         # dotfiles
brew "fzf"
brew "jq"
brew "yq"
brew "ripgrep"
brew "fd"
brew "bat"
brew "eza"             # modern ls
brew "mcat"            # modern cat
brew "neovim"
brew "gum"             # den's UI
brew "uv"              # scribe's Python tools
brew "ffmpeg"          # scribe audio

# ── Mac: the VM host and the shell/text tools ─────────────────────────
brew "lima"            # VM for coding agents; sized by the vm phase from this Mac
brew "shellcheck"
brew "bats-core"
tap "openclaw/tap"
brew "peekaboo"        # screenshots and screen inspection
brew "pam-reattach"    # Touch ID for sudo inside tmux and ssh

# ── Apps ───────────────────────────────────────────────────────────────
# Casks go to ~/Applications. A standard (non-admin) user cannot write to
# /Applications, so self-updating apps there prompt for admin on every update.
cask_args appdir: "~/Applications"
# 1Password is the one exception: it must live in /Applications for browser
# integration. Install it with: brew install --cask --appdir=/Applications 1password
cask "1password", args: { appdir: "/Applications" }
cask "1password-cli"
cask "visual-studio-code"
tap "anomalyco/tap"
cask "obsidian"
cask "rectangle"
cask "hex"             # scribe's speech-to-text, on the Apple GPU
cask "jumpcut"
cask "beyond-compare"
cask "keepingyouawake" # Amphetamine alternative

# ── Fonts ──────────────────────────────────────────────────────────────
cask "font-jetbrains-mono-nerd-font"
cask "font-geist-mono"

# Rex Agent Restore: resumes agent chats after a Rex restart (community, MIT).
# Its repo is not homebrew-*, so the tap needs the URL.
tap "pattont/rex-agent-restore", "https://github.com/pattont/RexAgentRestore"
brew "pattont/rex-agent-restore/rex-agent-restore"
