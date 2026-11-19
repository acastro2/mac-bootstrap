#!/usr/bin/env bats
# Casks and Rex belong in ~/Applications. These tests pin where the registry
# looks for apps, and how the appdir phase moves an app out of /Applications.
# Nothing touches the real machine: HOME and the system Applications folder
# are temp dirs, and brew, pgrep and op are stubs that log their calls.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  HOME="$TMP/home"
  export HOME
  # den: plain output, no network probe, state in the temp HOME.
  export DEN_UI=plain DEN_PROBE_NET=ok DEN_STATE_DIR="$TMP/state"
  export SYSTEM_APPDIR="$TMP/sysapps"
  export BREW_LOG="$TMP/brew.log"
  mkdir -p "$HOME/.local/bin" "$HOME/Applications" "$SYSTEM_APPDIR" "$TMP/bin"
  export PATH="$TMP/bin:$HOME/.local/bin:/usr/bin:/bin"

  for cmd in npm gh op mise docker uv; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  done

  # brew: log every call with the autoremove guard it ran under; answer
  # `info --cask --json=v2 <token>` with the one app each cask ships.
  cat > "$TMP/bin/brew" <<'STUB'
#!/bin/bash
printf 'NO_AUTOREMOVE=%s %s\n' "${HOMEBREW_NO_AUTOREMOVE:-}" "$*" >> "$BREW_LOG"
if [ "$1" = "info" ]; then
  token="${!#}"
  case "$token" in
    visual-studio-code) app="Visual Studio Code.app" ;;
    keepingyouawake)    app="KeepingYouAwake.app" ;;
    1password) app="1Password.app" ;;
    *)         app="Absent-$token.app" ;;
  esac
  printf '{"casks":[{"token":"%s","installed":"1.0","artifacts":[{"app":["%s"]}]}]}\n' "$token" "$app"
fi
# Real brew reads stdin during install; a loop fed on stdin loses its rows.
case "$1" in uninstall|install) cat >/dev/null ;; esac
exit 0
STUB
  chmod +x "$TMP/bin/brew"

  # pgrep: nothing runs unless the test names an app in $RUNNING_APP.
  cat > "$TMP/bin/pgrep" <<'STUB'
#!/bin/sh
[ -n "$RUNNING_APP" ] && printf '%s\n' "$*" | grep -F "$RUNNING_APP" >/dev/null && exit 0
exit 1
STUB
  chmod +x "$TMP/bin/pgrep"
}

teardown() {
  /bin/rm -rf "$TMP"
}

make_app() {
  mkdir -p "$1/Contents/MacOS"
}

# The appdir phase and the Applications checks are macOS only; CI runs Linux.
macos_only() {
  [ "$(uname)" = "Darwin" ] || skip "macOS only"
}

@test "app registry rows point into ~/Applications" {
  run "$REPO/bin/den" registry list
  [ "$status" -eq 0 ]
  local found=0
  for line in "${lines[@]}"; do
    IFS='|' read -r name kind target spec remove <<< "$line"
    [ "$kind" = "app" ] || continue
    found=$((found + 1))
    [[ "$spec" == Applications/* ]]
  done
  [ "$found" -ge 1 ]
}

@test "doctor finds code when VS Code lives in ~/Applications" {
  macos_only
  bin="$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin"
  mkdir -p "$bin"; : > "$bin/code"; chmod +x "$bin/code"
  ln -s "$bin/code" "$HOME/.local/bin/code"

  run "$REPO/bin/den" registry check
  [ "$status" -eq 0 ]
  # Judge the code row only: other rows are legitimately absent here.
  local code_line
  code_line="$(printf '%s\n' "$output" | grep -E '[^-]code  ')"
  [[ "$code_line" == *"~/.local/bin/code"* ]]
  [[ "$code_line" != *"app not installed"* ]]
  [[ "$code_line" != *"points at"* ]]
  [[ "$code_line" == *"✓"* ]]
}

@test "appdir moves an idle cask from /Applications with autoremove off" {
  macos_only
  make_app "$SYSTEM_APPDIR/Visual Studio Code.app"

  run "$REPO/bin/den" up --only=appdir
  [ "$status" -eq 0 ]
  grep -F "NO_AUTOREMOVE=1 uninstall --cask visual-studio-code" "$BREW_LOG"
  grep -F "NO_AUTOREMOVE=1 install --cask --appdir=$HOME/Applications visual-studio-code" "$BREW_LOG"
}

@test "appdir moves every straggler even when brew reads stdin" {
  macos_only
  make_app "$SYSTEM_APPDIR/KeepingYouAwake.app"
  make_app "$SYSTEM_APPDIR/Visual Studio Code.app"

  run "$REPO/bin/den" up --only=appdir
  [ "$status" -eq 0 ]
  grep -F "uninstall --cask keepingyouawake" "$BREW_LOG"
  grep -F "uninstall --cask visual-studio-code" "$BREW_LOG"
}

@test "appdir leaves a running app alone and says to quit it" {
  macos_only
  make_app "$SYSTEM_APPDIR/Visual Studio Code.app"
  export RUNNING_APP="Visual Studio Code.app"

  run "$REPO/bin/den" up --only=appdir
  [ "$status" -eq 0 ]
  [[ "$output" == *"Quit Visual Studio Code"* ]]
  ! grep -F "uninstall --cask visual-studio-code" "$BREW_LOG"
}

@test "appdir never moves 1Password" {
  macos_only
  make_app "$SYSTEM_APPDIR/1Password.app"

  run "$REPO/bin/den" up --only=appdir
  [ "$status" -eq 0 ]
  ! grep -F "uninstall --cask 1password" "$BREW_LOG"
  [ -d "$SYSTEM_APPDIR/1Password.app" ]
}

@test "appdir moves an idle Rex out of /Applications" {
  macos_only
  make_app "$SYSTEM_APPDIR/Rex Beta.app"

  run "$REPO/bin/den" up --only=appdir
  [ "$status" -eq 0 ]
  [ -d "$HOME/Applications/Rex Beta.app" ]
  [ ! -e "$SYSTEM_APPDIR/Rex Beta.app" ]
}

@test "appdir leaves a running Rex in place and says to quit it" {
  macos_only
  make_app "$SYSTEM_APPDIR/Rex Beta.app"
  export RUNNING_APP="Rex Beta.app"

  run "$REPO/bin/den" up --only=appdir
  [ "$status" -eq 0 ]
  [ -d "$SYSTEM_APPDIR/Rex Beta.app" ]
  [[ "$output" == *"Quit Rex"* ]]
}

@test "doctor flags a managed app still in /Applications" {
  macos_only
  make_app "$SYSTEM_APPDIR/Visual Studio Code.app"

  run "$REPO/bin/den" registry check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Visual Studio Code.app"*"/Applications"* ]]
}

@test "registry links regular VS Code as code, no Insiders" {
  run "$REPO/bin/den" registry list
  [ "$status" -eq 0 ]
  [[ "$output" == *"code|app|.local/bin/code|Applications/Visual Studio Code.app/Contents/Resources/app/bin/code|"* ]]
  [[ "$output" != *"nsiders"* ]]
}
