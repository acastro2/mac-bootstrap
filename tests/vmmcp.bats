#!/usr/bin/env bats
# The superlogical MCP in the agent VM. The gated URL comes from the den
# bundle and reaches the guest on stdin only: never in argv on the Mac, never
# on screen, never in state. Two seams: vm/mcp-register.sh (the guest side,
# run here against a fake claude) and the vm-mcp phase (against a limactl stub).

URL="https://example.test/gated-secret-7f3a"

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  HOME="$TMP/home"
  export HOME
  export DEN_UI=plain DEN_PROBE_NET=ok DEN_STATE_DIR="$TMP/state"
  mkdir -p "$HOME/.local/bin" "$TMP/bin"
  export PATH="$TMP/bin:$HOME/.local/bin:/usr/bin:/bin"
  export LIMA_LOG="$TMP/limactl.log" LIMA_STDIN="$TMP/limactl.stdin"
  export CLAUDE_LOG="$TMP/claude.log"

  for cmd in op brew; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  done

  # limactl: log argv, keep stdin of every shell call, answer as the guest.
  cat > "$TMP/bin/limactl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LIMA_LOG"
if [ "$1" = "list" ]; then
  case "$*" in *'{{.Status}}'*) printf '%s\n' "${LIMA_STATUS:-Running}" ;; esac
fi
if [ "$1" = "shell" ]; then
  cat >> "$LIMA_STDIN"
  [ -n "$LIMA_SHELL_OUT" ] && printf '%s\n' "$LIMA_SHELL_OUT"
fi
exit 0
STUB
  chmod +x "$TMP/bin/limactl"
}

teardown() {
  /bin/rm -rf "$TMP"
}

macos_only() {
  [ "$(uname)" = "Darwin" ] || skip "macOS only"
}

bundle() { # bundle [rex.mcp value]: a den.json, with rex.mcp only when given
  if [ -n "${1:-}" ]; then
    jq -n --arg u "$1" '{version:1, env:{}, rex:{mcp:$u}}' > "$HOME/den.json"
  else
    jq -n '{version:1, env:{}}' > "$HOME/den.json"
  fi
}

state() { jq -r --arg p "$1" '.results[] | select(.phase==$p) | "\(.status)|\(.reason)|\(.fix)"' "$DEN_STATE_DIR/last-run.json"; }

# fake_claude: `mcp get superlogical` prints $CLAUDE_HAVE (empty = not
# registered, exit 1); `mcp add` exits $CLAUDE_ADD_RC. Every call is logged.
fake_claude() {
  cat > "$HOME/.local/bin/claude" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_LOG"
case "$1 $2" in
  "mcp get")
    if [ -n "$CLAUDE_HAVE" ]; then printf 'superlogical:\n  URL: %s\n' "$CLAUDE_HAVE"; exit 0; fi
    echo "No MCP server found" >&2; exit 1 ;;
  "mcp add")
    echo "Added HTTP MCP server with URL: $5"; exit "${CLAUDE_ADD_RC:-0}" ;;
esac
exit 0
STUB
  chmod +x "$HOME/.local/bin/claude"
}

# ── Guest side: vm/mcp-register.sh ──────────────────────────────────

@test "guest: adds superlogical at user scope when it is missing, prints only 'added'" {
  fake_claude
  run bash "$REPO/vm/mcp-register.sh" <<<"$URL"
  [ "$status" -eq 0 ]
  [ "$output" = "added" ]
  grep -Fx -- "mcp add -s user --transport http superlogical $URL" "$CLAUDE_LOG"
}

@test "guest: leaves a matching registration alone and prints 'ok'" {
  fake_claude
  export CLAUDE_HAVE="$URL"
  run bash "$REPO/vm/mcp-register.sh" <<<"$URL"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  ! grep -E -- "^mcp (add|remove)" "$CLAUDE_LOG" || false
}

@test "guest: replaces a registration with a different URL" {
  fake_claude
  export CLAUDE_HAVE="https://www.superlogical.com/rex/community-mcp"
  run bash "$REPO/vm/mcp-register.sh" <<<"$URL"
  [ "$status" -eq 0 ]
  [ "$output" = "added" ]
  grep -Fx -- "mcp remove superlogical" "$CLAUDE_LOG"
  grep -Fx -- "mcp add -s user --transport http superlogical $URL" "$CLAUDE_LOG"
}

@test "guest: a stored URL that only contains the new one is replaced, not kept" {
  fake_claude
  export CLAUDE_HAVE="$URL?k=OLD"
  run bash "$REPO/vm/mcp-register.sh" <<<"$URL"
  [ "$output" = "added" ]
  grep -Fx -- "mcp add -s user --transport http superlogical $URL" "$CLAUDE_LOG"
}

@test "guest: a failed add prints 'failed' and never the URL" {
  fake_claude
  export CLAUDE_ADD_RC=1
  run bash "$REPO/vm/mcp-register.sh" <<<"$URL"
  [ "$output" = "failed" ]
  [[ "$output" != *"$URL"* ]] || false
}

@test "guest: no claude on PATH prints 'noclaude'" {
  run bash "$REPO/vm/mcp-register.sh" <<<"$URL"
  [ "$output" = "noclaude" ]
}

@test "guest: an empty stdin adds nothing and prints 'nourl'" {
  fake_claude
  run bash "$REPO/vm/mcp-register.sh" </dev/null
  [ "$output" = "nourl" ]
  ! grep -E -- "^mcp add" "$CLAUDE_LOG" || false
}

# ── Mac side: the vm-mcp phase ──────────────────────────────────────

@test "vm-mcp phase sends the URL on stdin only, never argv, screen or state" {
  macos_only
  bundle "$URL"
  export LIMA_SHELL_OUT=added
  run "$REPO/bin/den" up --only=vm-mcp
  [ "$status" -eq 0 ]
  [ "$(state vm-mcp | cut -d'|' -f1)" = "done" ]
  grep -F -- "$URL" "$LIMA_STDIN"
  grep -E -- "^shell agent .*superlogical" "$LIMA_LOG"
  ! grep -F -- "$URL" "$LIMA_LOG" || false
  [[ "$output" != *"$URL"* ]] || false
  ! grep -rF -- "$URL" "$DEN_STATE_DIR" || false
}

@test "vm-mcp phase skips with a fix when the bundle has no rex.mcp" {
  macos_only
  bundle
  run "$REPO/bin/den" up --only=vm-mcp
  [ "$(state vm-mcp | cut -d'|' -f1)" = "skipped" ]
  ! grep -E -- "^shell agent .*superlogical" "$LIMA_LOG" || false
}

@test "vm-mcp phase skips when the VM is not running" {
  macos_only
  bundle "$URL"
  export LIMA_STATUS=Stopped
  run "$REPO/bin/den" up --only=vm-mcp
  [ "$(state vm-mcp | cut -d'|' -f1)" = "skipped" ]
  ! grep -E -- "^shell agent .*superlogical" "$LIMA_LOG" || false
}

@test "vm-mcp phase fails with a fix when the guest add fails" {
  macos_only
  bundle "$URL"
  export LIMA_SHELL_OUT=failed
  run "$REPO/bin/den" up --only=vm-mcp
  [ "$(state vm-mcp | cut -d'|' -f1)" = "failed" ]
  [[ "$(state vm-mcp | cut -d'|' -f3)" == *"den up --only=vm-mcp"* ]] || false
  [[ "$output" != *"$URL"* ]] || false
}

@test "vm-mcp phase: no claude in the guest points at the vm phase, not agents" {
  macos_only
  bundle "$URL"
  export LIMA_SHELL_OUT=noclaude
  run "$REPO/bin/den" up --only=vm-mcp
  [ "$(state vm-mcp | cut -d'|' -f1)" = "skipped" ]
  [[ "$(state vm-mcp | cut -d'|' -f3)" == *"den up --only=vm"* ]] || false
  [[ "$(state vm-mcp | cut -d'|' -f3)" != *"agents"* ]]
}

@test "vm rebuild runs the vm-mcp phase after the vm phase" {
  macos_only
  bundle
  run "$REPO/bin/den" vm rebuild --yes </dev/null
  [ -n "$(state vm)" ] || false
  [ "$(state vm-mcp | cut -d'|' -f1)" = "skipped" ]
}

# ── den vm obsidian-sync ────────────────────────────────────────────

@test "den vm obsidian-sync restarts the guest user service" {
  macos_only
  run "$REPO/bin/den" vm obsidian-sync
  [ "$status" -eq 0 ]
  grep -E -- "^shell agent .*systemctl --user restart obsidian-sync\.service" "$LIMA_LOG"
}

@test "den vm obsidian-sync fails when the VM is not running, and says how to fix it" {
  macos_only
  export LIMA_STATUS=Stopped
  run "$REPO/bin/den" vm obsidian-sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"den vm up"* ]] || false
  ! grep -E -- "^shell agent .*systemctl" "$LIMA_LOG" || false
}

# ── doctor → den fix ────────────────────────────────────────────────

@test "doctor flags a guest without superlogical and den fix will rerun vm-mcp" {
  macos_only
  export LIMA_SHELL_OUT='mcp=missing'
  run "$REPO/bin/den" doctor
  [[ "$output" == *"superlogical MCP missing"* ]] || false
  [[ "$output" == *"den fix reruns:"*"vm-mcp"* ]] || false
}

@test "doctor passes when the guest has superlogical" {
  macos_only
  export LIMA_SHELL_OUT='mcp=ok'
  run "$REPO/bin/den" doctor
  [[ "$output" == *"superlogical MCP OK"* ]] || false
  [[ "$output" != *"vm-mcp"* ]] || false
}

@test "doctor: no claude in the guest points at the vm phase and queues nothing for den fix" {
  macos_only
  export LIMA_SHELL_OUT='mcp=noclaude'
  run "$REPO/bin/den" doctor
  [[ "$output" == *"Claude Code missing in the guest (fix: den up --only=vm)"* ]] || false
  [[ "$output" != *"vm-mcp"* ]]
}
