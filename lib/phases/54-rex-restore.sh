# shellcheck shell=bash
# lib/phases/54-rex-restore.sh — Rex Agent Restore: resume Claude Code and
# Cursor chats after a Rex restart.
# Its installer only wires agents whose config dirs exist, so this runs after
# the config repos. The zsh part belongs to chezmoi, hence --no-shell.
# Contract: docs/den/CONTRACT.md ("Host vs VM").

den_phase rex-restore \
  --title "Rex Agent Restore" \
  --about "resume Claude Code chats after a Rex restart" \
  --os any \
  --toggle DEN_REX

phase_rex_restore() {
  local agents=${REX_RESTORE_AGENTS:-claude} out=""

  if ! command -v rex-agent-restore >/dev/null 2>&1; then
    den_skip "rex-agent-restore not installed" "brew install rex-agent-restore, then run den fix"
  fi

  if ! out=$(rex-agent-restore install --no-shell --agents "$agents" 2>&1); then
    ui_err "rex-agent-restore install failed"
    printf '%s\n' "$out" | tail -n 10 | sed 's/^/    /' >&2 || true
    den_fail "rex-agent-restore install failed" "rex-agent-restore install --no-shell --agents $agents"
  fi
  ui_ok "wired $agents; save open chats with: rex-agent-restore capture"
}
