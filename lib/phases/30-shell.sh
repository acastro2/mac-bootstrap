# shellcheck shell=bash
# 30-shell.sh — zsh, Zim, the login shell and the chezmoi dotfiles, in one phase.

den_phase shell \
  --title "Shell" \
  --about "zsh, Zim, the login shell, and the chezmoi dotfiles" \
  --os any \
  --needs "brew"

phase_shell() {
  local zsh_bin dotfiles config wanted current file smoke oc_bin oc_file oc_tmp
  local expected actual

  zsh_bin=$(command -v zsh 2>/dev/null) || zsh_bin=""
  if [ -z "$zsh_bin" ]; then
    zsh_bin=/bin/zsh
  fi
  if [ ! -x "$zsh_bin" ]; then
    den_fail "zsh is not installed" "brew install zsh, then run den up --only=shell"
  fi
  if ! command -v chezmoi >/dev/null 2>&1; then
    den_skip "chezmoi is not installed" "brew install chezmoi, then run den up --only=shell"
  fi

  dotfiles=${DEN_ROOT:-}/home
  if [ ! -d "$dotfiles" ]; then
    den_fail "no dotfiles at $dotfiles" "restore home/ in the den repo, then run den up --only=shell"
  fi
  config=$HOME/.config/chezmoi/chezmoi.toml
  wanted="sourceDir = \"$dotfiles\""
  current=""
  if [ -f "$config" ]; then
    current=$(cat "$config")
  fi
  if [ "$current" != "$wanted" ]; then
    mkdir -p "$HOME/.config/chezmoi"
    if [ -f "$config" ]; then
      cp -p "$config" "$config.bak"
    fi
    printf '%s\n' "$wanted" > "$config"
    ui_step "chezmoi sourceDir -> $dotfiles"
  fi
  # The repo is the source of truth; per-machine edits go in local.zsh. Back up
  # every file chezmoi would overwrite, then apply without its prompt (a prompt
  # mid-run would break "ask first, then run unattended").
  local changed backup f
  changed=$(chezmoi status 2>/dev/null | awk '{print $NF}') || changed=""
  if [ -n "$changed" ]; then
    backup="$HOME/.local/state/den/snapshots/dotfiles-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup"
    chmod 700 "$HOME/.local/state/den/snapshots" "$backup" 2>/dev/null || true
    for f in $changed; do
      if [ -e "$HOME/$f" ]; then
        mkdir -p "$backup/$(dirname "$f")"
        cp -p "$HOME/$f" "$backup/$f"
      fi
    done
    ui_info "backed up the dotfiles chezmoi replaces to $backup"
  fi
  if ! chezmoi apply --force; then
    den_fail "chezmoi apply failed" "resolve the file chezmoi names, then run den up --only=shell"
  fi
  ui_ok "dotfiles applied from $dotfiles"

  mkdir -p "$HOME/.config/zsh"
  if [ ! -f "$HOME/.config/zsh/.api-keys.zsh" ]; then
    : > "$HOME/.config/zsh/.api-keys.zsh"
  fi
  chmod 600 "$HOME/.config/zsh/.api-keys.zsh"
  if [ ! -f "$HOME/.config/zsh/local.zsh" ]; then
    : > "$HOME/.config/zsh/local.zsh"
  fi

  oc_bin=""
  if command -v opencode >/dev/null 2>&1; then
    oc_bin=$(command -v opencode)
  elif [ -x "$HOME/.opencode/bin/opencode" ]; then
    oc_bin=$HOME/.opencode/bin/opencode
  fi
  if [ -n "$oc_bin" ]; then
    oc_file=$HOME/.config/zsh/opencode-completions.zsh
    oc_tmp=$oc_file.tmp
    if "$oc_bin" --completions zsh > "$oc_tmp" 2>/dev/null &&
      grep -q -- '###-begin-opencode-completions-###' "$oc_tmp"; then
      mv "$oc_tmp" "$oc_file"
    else
      rm -f "$oc_tmp"
      ui_warn "opencode completions were not generated; keeping the previous file"
    fi
  fi

  # Validate every file a new shell reads before the login shell is switched.
  for file in "$HOME/.zshrc" "$HOME/.zimrc" "$HOME/.zshenv" "$HOME/.config/zsh/"*.zsh; do
    if [ ! -e "$file" ]; then
      continue
    fi
    if ! "$zsh_bin" -n "$file"; then
      den_fail "zsh -n failed on $file" "fix that file, then run den up --only=shell"
    fi
  done

  # zimfw downloads on the first start; a broken .zshrc must fail here, not in
  # every new terminal.
  smoke=$("$zsh_bin" -ic 'true' </dev/null 2>&1) ||
    den_fail "zsh failed to start with ~/.zshrc: ${smoke}" \
      "run zsh -i to see the error, fix it, then run den up --only=shell"
  if [ -e "$HOME/.zim/zimfw.zsh" ]; then
    ui_ok "Zim is installed"
  else
    ui_warn "Zim was not downloaded; open a new terminal to retry"
  fi

  # .zshrc drops inherited AWS credentials; a regression must fail here.
  # shellcheck disable=SC2016  # ${VAR:-} belongs to zsh, not Bash.
  if ! env AWS_ACCESS_KEY_ID=den-test AWS_SECRET_ACCESS_KEY=den-test \
    AWS_SESSION_TOKEN=den-test AWS_PROFILE=den-test \
    "$zsh_bin" -ic '[[ -z "${AWS_ACCESS_KEY_ID:-}" && -z "${AWS_SECRET_ACCESS_KEY:-}" \
      && -z "${AWS_SESSION_TOKEN:-}" && -z "${AWS_PROFILE:-}" ]]' </dev/null; then
    den_fail "zsh keeps inherited AWS credentials" \
      "restore the unset line in ~/.zshrc, then run den up --only=shell"
  fi

  if [ "$(den_os)" = macos ]; then
    expected=/bin/zsh
    actual=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}') || actual=""
  else
    expected=$(command -v zsh 2>/dev/null) || expected=""
    actual=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7) || actual=""
  fi
  if [ -z "$expected" ]; then
    den_fail "cannot find the zsh binary" "brew install zsh, then run den up --only=shell"
  fi
  if [ "$actual" = "$expected" ]; then
    ui_ok "login shell is $expected"
    return 0
  fi

  # sudo only when the shell must change (preflight unlocks sudo once when
  # any selected phase needs it; the VM has passwordless sudo).
  if ! sudo -n true 2>/dev/null; then
    den_skip "changing the login shell to $expected needs sudo" "sudo -v, then den up --only=shell"
  fi
  ui_step "switching the login shell from ${actual:-unknown} to $expected"
  if ! grep -qxF "$expected" /etc/shells 2>/dev/null; then
    printf '%s\n' "$expected" | sudo tee -a /etc/shells >/dev/null ||
      den_fail "could not add $expected to /etc/shells" \
        "add $expected to /etc/shells by hand, then run den up --only=shell"
  fi
  if [ "$(den_os)" = macos ]; then
    sudo dscl . -create "/Users/$USER" UserShell "$expected" ||
      den_fail "could not set the login shell" "sudo dscl . -create /Users/$USER UserShell $expected"
    actual=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}') || actual=""
  else
    sudo chsh -s "$expected" "$USER" ||
      den_fail "could not set the login shell" "sudo chsh -s $expected $USER"
    actual=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7) || actual=""
  fi
  if [ "$actual" != "$expected" ]; then
    den_fail "login shell readback is '${actual:-empty}'" "set it by hand: chsh -s $expected"
  fi
  ui_ok "login shell is $expected"
}
