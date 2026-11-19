#!/usr/bin/env bats
# Lane B acceptance: secrets, config repos, Rex, mise versions.
# Contract: docs/den/CONTRACT.md ("Secrets", "Host vs VM", "Versions in the VM").

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export DEN_UI=plain DEN_PROBE_NET=ok DEN_STATE_DIR="$TMP/state"
  export CALLS="$TMP/calls.log"
  mkdir -p "$HOME" "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin:/opt/homebrew/bin"
  for c in op sudo; do printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"; done
  # Guard: nothing in this file may reach the real machine. Every tool that
  # changes state is a logging stub here, even when a test forgets to scope.
  for c in brew limactl launchctl defaults hdiutil ditto; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "%s"\nexit 0\n' "$c" "$CALLS" > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"
  done
  # gh: not signed in.
  printf '#!/bin/sh\nprintf "gh %%s\\n" "$*" >> "%s"\nexit 1\n' "$CALLS" > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
}

teardown() { /bin/rm -rf "$TMP"; }

macos_only() { [ "$(uname)" = "Darwin" ] || skip "macOS only"; }
state() { jq -r --arg p "$1" '.results[] | select(.phase==$p) | "\(.status)|\(.reason)|\(.fix)"' "$DEN_STATE_DIR/last-run.json"; }

bundle() {
  cat > "$HOME/den.json" <<'EOF'
{"version":1,"env":{"OPENCODE_API_KEY":"k-1","EXA_API_KEY":"e$x"},
 "opencode_web":{"password":"pw"},
 "rex":{"appcast":"https://appcast.example.invalid/feed.xml","mcp":"https://mcp.example.invalid/x"}}
EOF
}

@test "secrets phase renders the keys file from den.json and purges the source" {
  bundle
  run "$REPO/bin/den" up --only=secrets
  [ "$status" -eq 0 ]
  [ "$(state secrets | cut -d'|' -f1)" = done ]
  f="$HOME/.config/zsh/.api-keys.zsh"
  [ "$(zsh -fc "source '$f'; print -r -- \$EXA_API_KEY")" = 'e$x' ]
  [ ! -e "$HOME/den.json" ]
}

@test "config-repos is skipped with a gh fix when gh is not signed in" {
  run "$REPO/bin/den" up --only=config-repos
  [ "$status" -eq 0 ]
  s="$(state config-repos)"
  [ "${s%%|*}" = skipped ]
  [[ "$s" == *"gh auth login"* ]]
}

@test "rex install reads the appcast from den.json and never prints it" {
  macos_only
  bundle
  export SYSTEM_APPDIR="$TMP/sysapps"; mkdir -p "$SYSTEM_APPDIR"
  printf '#!/bin/sh\nprintf "curl %%s\\n" "$*" >> "%s"\nexit 22\n' "$CALLS" > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"
  run "$REPO/bin/den" up --only=rex
  grep -F "appcast.example.invalid" "$CALLS"
  [[ "$output" != *"example.invalid"* ]]
  ! grep -F "example.invalid" "$DEN_STATE_DIR/last-run.json"
}

@test "mise never runs on the Mac" {
  macos_only
  printf '#!/bin/sh\nprintf "mise %%s\\n" "$*" >> "%s"\n' "$CALLS" > "$TMP/bin/mise"; chmod +x "$TMP/bin/mise"
  run "$REPO/bin/den" up --only=mise
  ! grep -q '^mise ' "$CALLS"
  [ ! -e "$HOME/.config/mise/config.toml" ]
}

@test "VM mise config: LTS where it exists, latest elsewhere, no stale pins" {
  f="$(grep -rl 'opentofu' "$REPO/lib/phases" | head -1)"
  [ -n "$f" ]
  grep -E 'node *= *"lts"' "$f"
  grep -E 'dotnet *= *"(lts|10)"' "$f"
  ! grep -E 'python *= *"3\.12"' "$f"
  ! grep -E 'dotnet *= *"9"' "$f"
  ! grep -F 'pi-coding-agent' "$f"
}
