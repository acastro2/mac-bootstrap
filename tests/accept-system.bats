#!/usr/bin/env bats
# Lane A acceptance: Brewfiles, dotfiles, registry, Touch ID sudo.
# Contract: docs/den/CONTRACT.md ("Host vs VM", "Additions decided").

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export DEN_UI=plain DEN_PROBE_NET=ok DEN_STATE_DIR="$TMP/state"
  export CALLS="$TMP/calls.log"
  mkdir -p "$HOME" "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin"
}

teardown() { /bin/rm -rf "$TMP"; }

macos_only() { [ "$(uname)" = "Darwin" ] || skip "macOS only"; }

entries() { # entries FILE: one token per brew/cask/tap line
  sed -n -E 's/^(brew|cask|tap) "([^"]+)".*/\1 \2/p' "$1" | sed -E 's#^(brew|cask) .*/#\1 #'
}

@test "Mac Brewfile: has the Mac list, none of the removed or VM-only tools" {
  e="$(entries "$REPO/Brewfile")"
  for want in "brew lima" "brew gum" "brew mcat" "brew uv" "brew ffmpeg" "brew shellcheck" \
              "brew bats-core" "brew peekaboo" "cask 1password" "cask 1password-cli" \
              "cask visual-studio-code" "cask obsidian" "cask rectangle" "cask hex" \
              "brew rex-agent-restore"; do
    grep -qx "$want" <<<"$e" || { echo "missing: $want"; return 1; }
  done
  for gone in "cask zed" "cask ghostty" "cask claude" "cask cursor-cli" "cask copilot-cli" \
              "brew colima" "brew docker" "brew docker-compose" "brew mise" "brew mas" \
              "cask tflint" "brew kubectl" "brew awscli" "brew helm" "brew k9s" \
              "brew pre-commit" "brew gitleaks" "brew repomix" "brew snowflake-cli"; do
    ! grep -qx "$gone" <<<"$e" || { echo "should be gone: $gone"; return 1; }
  done
  ! grep -E '^brew "postgresql@1[0-6]"' "$REPO/Brewfile"
}

@test "Linux Brewfile: VM list, latest Postgres, no docker or colima" {
  e="$(entries "$REPO/Brewfile.linux")"
  for want in "brew gum" "brew mcat" "brew uv" "brew ffmpeg" "brew asdf" "brew opentunnel" \
              "brew kubectl" "brew helm" "brew awscli"; do
    grep -qx "$want" <<<"$e" || { echo "missing: $want"; return 1; }
  done
  for gone in "brew docker" "brew docker-compose" "brew colima" "brew lima" "brew tflint" "brew mas"; do
    ! grep -qx "$gone" <<<"$e" || { echo "should be gone: $gone"; return 1; }
  done
  grep -E '^brew "postgresql(@1[7-9]|@[2-9][0-9])?"' "$REPO/Brewfile.linux"
}

@test "dotfiles: cat=mcat only when mcat exists; zshenv; no probes or dead PATHs" {
  grep -E '\(\( \$\+commands\[mcat\] \)\) && alias cat=' "$REPO/home/dot_zshrc"
  ! grep -E "^alias cat='?mcat" "$REPO/home/dot_zshrc"
  ! grep -i 'startup probe' "$REPO/home/dot_zshrc"
  ! grep -i 'SnowflakeCLI' "$REPO/home/dot_zprofile"
  [ -f "$REPO/home/dot_zshenv" ]
  grep -F '.local/bin' "$REPO/home/dot_zshenv"
  zsh -n "$REPO/home/dot_zshrc" "$REPO/home/dot_zprofile" "$REPO/home/dot_zshenv"
}

@test "registry: macOS rows are the Mac managed installs only" {
  macos_only
  run "$REPO/bin/den" registry list
  [ "$status" -eq 0 ]
  names="$(printf '%s\n' "${lines[@]}" | cut -d'|' -f1)"
  for want in opencode claude code; do grep -qx "$want" <<<"$names" || { echo "missing $want"; return 1; }; done
  for gone in herdr zed docker-compose cortex tgrep playwright browser-use; do
    ! grep -qx "$gone" <<<"$names" || { echo "should not be on the Mac: $gone"; return 1; }
  done
}

@test "sudo-touchid: writes pam_reattach then pam_tid, once" {
  macos_only
  export DEN_PAM_SUDO_LOCAL="$TMP/sudo_local"
  mkdir -p "$TMP/reattach/lib/pam"; : > "$TMP/reattach/lib/pam/pam_reattach.so"
  printf '#!/bin/sh\nprintf "brew %%s\\n" "$*" >> "%s"\n[ "$1" = --prefix ] && echo "%s/reattach"\nexit 0\n' "$CALLS" "$TMP" > "$TMP/bin/brew"
  # sudo: drop sudo flags, run the command (writes land in the temp file).
  printf '#!/bin/bash\nprintf "sudo %%s\\n" "$*" >> "%s"\nwhile [[ "$1" == -* ]]; do shift; done\nexec "$@"\n' "$CALLS" > "$TMP/bin/sudo"
  chmod +x "$TMP/bin/brew" "$TMP/bin/sudo"
  run "$REPO/bin/den" up --only=sudo-touchid
  [ "$status" -eq 0 ]
  r="$(grep -n 'pam_reattach' "$DEN_PAM_SUDO_LOCAL" | cut -d: -f1)"
  t="$(grep -n 'auth.*sufficient.*pam_tid\.so' "$DEN_PAM_SUDO_LOCAL" | cut -d: -f1)"
  [ -n "$r" ] && [ -n "$t" ] && [ "$r" -lt "$t" ]
  before="$(cat "$DEN_PAM_SUDO_LOCAL")"
  : > "$CALLS"
  run "$REPO/bin/den" up --only=sudo-touchid
  [ "$status" -eq 0 ]
  [ "$(cat "$DEN_PAM_SUDO_LOCAL")" = "$before" ]
  ! grep -q '^sudo .*tee\|^sudo .*install\|^sudo .*cp' "$CALLS"
}

@test "macos-defaults: every write passes domain, key, type and value" {
  macos_only
  printf '#!/bin/sh\nprintf "defaults %%s\\n" "$*" >> "$CALLS"\n[ "$1" = write ] && [ $# -ne 5 ] && exit 1\nexit 0\n' > "$TMP/bin/defaults"
  for c in osascript killall; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$c"; done
  chmod +x "$TMP/bin/defaults" "$TMP/bin/osascript" "$TMP/bin/killall"
  run "$REPO/bin/den" up --only=macos-defaults
  [ "$status" -eq 0 ]
  grep -qx 'defaults write -g KeyRepeat -int 2' "$CALLS"
  grep -qx 'defaults write com.apple.dock autohide -bool true' "$CALLS"
  [[ "$output" != *"could not set"* ]]
}

@test "macos-defaults: a write that fails fails the phase, with the key named" {
  macos_only
  printf '#!/bin/sh\n[ "$1" = write ] && [ "$2" = com.apple.dock ] && exit 1\nexit 0\n' > "$TMP/bin/defaults"
  for c in osascript killall; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$c"; done
  chmod +x "$TMP/bin/defaults" "$TMP/bin/osascript" "$TMP/bin/killall"
  run "$REPO/bin/den" up --only=macos-defaults
  [ "$status" -eq 1 ]
  [[ "$output" == *"com.apple.dock"* ]]
  jq -e '.results[] | select(.phase=="macos-defaults") | .status == "failed"' "$DEN_STATE_DIR/last-run.json"
}

@test "sudo-touchid: a sudo_local with other auth rules is kept, the phase skips with the fix" {
  macos_only
  export DEN_PAM_SUDO_LOCAL="$TMP/sudo_local"
  printf 'auth sufficient pam_smartcard.so\n' > "$DEN_PAM_SUDO_LOCAL"
  mkdir -p "$TMP/reattach/lib/pam"; : > "$TMP/reattach/lib/pam/pam_reattach.so"
  printf '#!/bin/sh\n[ "$1" = --prefix ] && echo "%s/reattach"\nexit 0\n' "$TMP" > "$TMP/bin/brew"
  printf '#!/bin/bash\nprintf "sudo %%s\\n" "$*" >> "%s"\nwhile [[ "$1" == -* ]]; do shift; done\nexec "$@"\n' "$CALLS" > "$TMP/bin/sudo"
  chmod +x "$TMP/bin/brew" "$TMP/bin/sudo"
  run "$REPO/bin/den" up --only=sudo-touchid
  [ "$(cat "$DEN_PAM_SUDO_LOCAL")" = "auth sufficient pam_smartcard.so" ]
  jq -e '.results[] | select(.phase=="sudo-touchid") | .status == "skipped" and (.fix|length>0)' "$DEN_STATE_DIR/last-run.json"
  [[ "$output" == *"pam_smartcard"* ]]
}
