# Brewfile — declarative package list
# Apply with: brew bundle --file=Brewfile

# ── Shell & Toolchains ────────────────────────────────────────────────
brew "git"
brew "gh"
brew "fish"
brew "fisher"          # fish plugin manager
brew "mise"            # toolchain manager (Go, Node, Python, etc.)
brew "llhttp"          # mise Node dep — prevent brew cleanup from breaking node
brew "chezmoi"         # dotfiles
brew "uv"              # fast Python package manager + uvx
brew "fzf"
brew "pre-commit"
brew "gitleaks"

# ── CLI Utilities ──────────────────────────────────────────────────────
brew "jq"
brew "yq"
brew "ripgrep"
brew "fd"
brew "bat"
brew "eza"             # modern ls
brew "repomix"        # pack a repo into a single file for LLM context
brew "neovim"
brew "doggo"           # DNS client (dig alternative)
brew "mas"             # Mac App Store CLI

# ── Platform / Infra ───────────────────────────────────────────────────
tap "terraform-linters/tap"
brew "kubectl"
brew "k9s"
brew "helm"
brew "awscli"
brew "colima"          # Docker runtime (no Docker Desktop)
brew "docker"          # Docker CLI
brew "crane"           # inspect/copy container images without pulling
brew "ffmpeg"          # Playwright video recording / trace viewer media
brew "snowflake-cli"
brew "pgcli"
brew "postgresql@16", restart_service: false
brew "redis", restart_service: false

# ── Apps ───────────────────────────────────────────────────────────────
cask "1password"
cask "1password-cli"
cask "claude"          # Claude Desktop app (CLI installed separately via native installer in bootstrap.sh)
cask "ghostty"
cask "visual-studio-code@insiders"
cask "zed"
cask "tflint"
cask "copilot-cli"     # GitHub Copilot CLI
cask "jumpcut"
cask "beyond-compare"
cask "keepingyouawake" # Amphetamine alternative

# ── Fonts ──────────────────────────────────────────────────────────────
cask "font-jetbrains-mono-nerd-font"
cask "font-geist-mono"
