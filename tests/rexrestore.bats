#!/usr/bin/env bats
# Rex Agent Restore: its tap lives in a repo not named homebrew-*, so the
# packages phase must tap it with its URL before trusting it; the rex-restore
# phase wires the agents without touching ~/.zshrc (chezmoi owns it).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  HOME="$TMP/home"
  export HOME
  # den: plain output, no network probe, state in the temp HOME.
  export DEN_UI=plain DEN_PROBE_NET=ok DEN_STATE_DIR="$TMP/state"
  export CALLS="$TMP/calls.log"
  mkdir -p "$HOME/.local/bin" "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin"

  for cmd in npm gh op mise docker uv limactl pgrep; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  done
  for cmd in brew rex-agent-restore; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "$CALLS"\nexit 0\n' "$cmd" > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  done
}

teardown() {
  /bin/rm -rf "$TMP"
}

@test "packages phase taps a URL tap with its URL, then trusts it" {
  run "$REPO/bin/den" up --only=packages
  [ "$status" -eq 0 ]
  grep -F "brew tap pattont/rex-agent-restore https://github.com/pattont/RexAgentRestore" "$CALLS"
  grep -F "brew trust pattont/rex-agent-restore" "$CALLS"
}

@test "rex-restore phase wires agents without touching ~/.zshrc" {
  run "$REPO/bin/den" up --only=rex-restore
  [ "$status" -eq 0 ]
  grep -F "rex-agent-restore install --no-shell" "$CALLS"
}

@test "rex-restore phase wires only the agents config.env names" {
  run "$REPO/bin/den" up --only=rex-restore
  [ "$status" -eq 0 ]
  grep -F "rex-agent-restore install --no-shell --agents claude" "$CALLS"
}

@test "rex-restore phase skips when the tool is missing" {
  /bin/rm -f "$TMP/bin/rex-agent-restore"
  run "$REPO/bin/den" up --only=rex-restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"rex-agent-restore not installed"* ]]
}
