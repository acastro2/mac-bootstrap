# ~/.config/fish/config.fish — managed by chezmoi

# ── Homebrew ─────────────────────────────────────────────────────────
if test -x /opt/homebrew/bin/brew
  eval (/opt/homebrew/bin/brew shellenv)
else if test -x /usr/local/bin/brew
  eval (/usr/local/bin/brew shellenv)
end

# ── History ──────────────────────────────────────────────────────────
set -g fish_history_size 50000

# ── Toolchain managers ───────────────────────────────────────────────
mise activate fish | source

# Tide prompt — installed by fisher (bootstrap.sh)

# ── fzf ──────────────────────────────────────────────────────────────
test -f (brew --prefix)/opt/fzf/shell/key-bindings.fish && source (brew --prefix)/opt/fzf/shell/key-bindings.fish

# ── Aliases ──────────────────────────────────────────────────────────
alias ls='eza --icons --group-directories-first'
alias ll='eza -lh --icons --git --group-directories-first'
alias la='eza -la --icons --git --group-directories-first'
alias cat='bat --paging=never'
alias k='kubectl'
alias g='git'
alias gst='git status'
alias code='code-insiders'
function cd-dev;      cd ~/Developer; end
function cd-down;     cd ~/Downloads; end
function cd-skills;   cd ~/.agents/skills; end
function cd-bootstrap; cd ~/Developer/github/acastro2/mac-bootstrap; end

# ── opencode ──────────────────────────────────────────────────────────
fish_add_path $HOME/.opencode/bin
# uv tool-installed binaries land here
fish_add_path $HOME/.local/bin
# Enables in-development features (e.g. newer model support, beta UI flags).
set -gx OPENCODE_EXPERIMENTAL true

# ── AWS helper ───────────────────────────────────────────────────────
function awssso --argument profile
  set -q profile[1]; or set profile default
  aws sso login --profile $profile
  set -gx AWS_PROFILE $profile
end

# ── Local overrides (not version controlled) ─────────────────────────
test -f $HOME/.config/fish/config.local.fish && source $HOME/.config/fish/config.local.fish
