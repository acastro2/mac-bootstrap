#!/usr/bin/env bats
# Behaviour of the managed install registry: what it declares, what doctor
# reports, and what --clean plans. Nothing here touches the real machine:
# HOME is a temp dir, and package managers and `rm` are stubs.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  HOME="$TMP/home"
  export HOME
  mkdir -p "$HOME/.local/bin" "$HOME/.docker/cli-plugins" "$TMP/bin"
  export RM_LOG="$TMP/rm.log"
  export PATH="$TMP/bin:$HOME/.local/bin:$HOME/.opencode/bin:/usr/bin:/bin"

  for cmd in npm gh op mise docker; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  done

  # A real prefix with a real plugin binary, so the managed link is not dangling.
  export FAKE_BREW_PREFIX="$TMP/brewprefix"
  mkdir -p "$FAKE_BREW_PREFIX/opt/docker-compose/bin"
  : > "$FAKE_BREW_PREFIX/opt/docker-compose/bin/docker-compose"
  chmod +x "$FAKE_BREW_PREFIX/opt/docker-compose/bin/docker-compose"
  cat > "$TMP/bin/brew" <<'STUB'
#!/bin/sh
if [ "$1" = "--prefix" ]; then printf '%s\n' "$FAKE_BREW_PREFIX"; fi
exit 0
STUB
  chmod +x "$TMP/bin/brew"

  cat > "$TMP/bin/uv" <<'STUB'
#!/bin/sh
if [ "$1" = "tool" ] && [ "$2" = "list" ]; then
  printf 'playwright v1.64.0\n- playwright\nbrowser-use v0.13.11\n- browser-use\n'
fi
exit 0
STUB
  chmod +x "$TMP/bin/uv"

  # A dry run must never reach a real rm. If it does, the log proves it and
  # nothing is deleted.
  cat > "$TMP/bin/rm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$RM_LOG"
exit 0
STUB
  chmod +x "$TMP/bin/rm"
}

teardown() {
  /bin/rm -rf "$TMP"
}

# Create every registry target exactly as the table declares it, so a test can
# break one row and know the rest are healthy.
install_registry_targets() {
  local name kind target spec remove
  "$REPO/bootstrap.sh" --only=__none__ --dump-tools > "$TMP/rows"
  while IFS='|' read -r name kind target spec remove; do
    case "$kind" in
      script)
        mkdir -p "$HOME/$(dirname "$target")"
        : > "$HOME/$target"
        chmod +x "$HOME/$target"
        ;;
      uv)
        : # the uv stub reports both packages as installed
        ;;
      app)
        if [ -e "$spec" ]; then
          mkdir -p "$HOME/$(dirname "$target")"
          ln -sfn "$spec" "$HOME/$target"
        fi
        ;;
      plugin)
        mkdir -p "$HOME/$(dirname "$target")"
        ln -sfn "$FAKE_BREW_PREFIX/opt/docker-compose/bin/docker-compose" "$HOME/$target"
        ;;
    esac
  done < "$TMP/rows"
}

@test "dump-tools declares ten unique rows with known kinds" {
  # --only=__none__ is a safety belt: a regression that drops --dump-tools must
  # not turn this test into a full bootstrap.
  run "$REPO/bootstrap.sh" --only=__none__ --dump-tools
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 10 ]

  for line in "${lines[@]}"; do
    IFS='|' read -r name kind target spec remove <<< "$line"
    [ -n "$name" ]
    [ -n "$target" ]
    [ "${target#/}" = "$target" ]
    case "$kind" in
      script|uv|app|plugin) ;;
      *) return 1 ;;
    esac
  done

  [ "$(printf '%s\n' "${lines[@]}" | cut -d'|' -f1 | sort -u | wc -l | tr -d ' ')" -eq 10 ]
}

@test "doctor --strict fails when another copy shadows a managed install" {
  install_registry_targets
  printf '#!/bin/sh\n' > "$TMP/bin/claude"
  chmod +x "$TMP/bin/claude"

  run "$REPO/bootstrap.sh" --only=doctor --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"shadows"* ]]
}

@test "doctor reports a shadow but exits 0 without --strict" {
  install_registry_targets
  printf '#!/bin/sh\n' > "$TMP/bin/claude"
  chmod +x "$TMP/bin/claude"

  run "$REPO/bootstrap.sh" --only=doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"shadows"* ]]
}

@test "doctor --strict fails on a missing managed install" {
  run "$REPO/bootstrap.sh" --only=doctor --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing at ~/.local/bin/herdr"* ]]
}

@test "an absent dependency skips its row instead of failing" {
  install_registry_targets
  /bin/rm -f "$TMP/bin/docker"

  run "$REPO/bootstrap.sh" --only=doctor --strict
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker-compose"* ]]
  [[ "$output" == *"docker not installed"* ]]
}

@test "a managed install PATH cannot see warns but does not gate" {
  install_registry_targets
  export PATH="$TMP/bin:/usr/bin:/bin"

  run "$REPO/bootstrap.sh" --only=doctor --strict
  [ "$status" -eq 0 ]
  [[ "$output" == *"not on PATH"* ]]
}

@test "doctor survives a machine without zsh" {
  if command -v zsh >/dev/null 2>&1; then
    skip "zsh is installed here"
  fi

  run "$REPO/bootstrap.sh" --only=doctor
  [ "$status" -eq 0 ]
}

@test "clean --dry-run plans removals without running them" {
  : > "$HOME/.local/bin/herdr"

  run "$REPO/bootstrap.sh" --clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove: ~/.local/bin/herdr"* ]]
  [ ! -e "$RM_LOG" ]
  [ -f "$HOME/.local/bin/herdr" ]
}
