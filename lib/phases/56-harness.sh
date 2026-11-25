# shellcheck shell=bash
# lib/phases/56-harness.sh — the agent harness on this host: Claude Code hooks,
# the OpenCode plugin, the `harness` MCP server, and `harness serve` as a user
# service (systemd on the VM, launchd on the Mac). It is also the recovery
# path: a re-run restores every entry the harness owns and touches nothing
# else. Runs after config-repos (the skills checkout) and mise (the pinned Bun).
# Spec: ~/.agents/skills/docs/specs/harness-evolution.md (D59, D71).

den_phase harness \
  --title "Agent harness" \
  --about "harness hooks, OpenCode plugin, MCP server and harness serve" \
  --os any

phase_harness() {
  local root="$HOME/.agents/skills/harness" bun="" out=""
  if [ ! -f "$root/src/install.ts" ]; then
    den_skip "the skills checkout has no harness/" "den up --only=config-repos"
  fi
  if command -v mise >/dev/null 2>&1; then
    bun=$(mise which bun 2>/dev/null || true) || bun=""
  fi
  [ -n "$bun" ] || bun=$(command -v bun 2>/dev/null || true) || bun=""
  if [ -z "$bun" ]; then
    den_skip "Bun is not installed" "den up --only=mise"
  fi

  if [ ! -d "$root/node_modules" ]; then
    if (cd "$root" && "$bun" install --frozen-lockfile >/dev/null 2>&1); then
      ui_ok "harness dependencies installed"
    else
      den_fail "bun install failed in $root" "cd $root && bun install --frozen-lockfile"
    fi
  fi

  if out=$("$bun" "$root/src/install.ts" --bun "$bun" 2>&1); then
    printf '%s\n' "$out" | while IFS= read -r line; do ui_info "harness: $line"; done
  else
    den_fail "the harness installer failed: ${out##*$'\n'}" "$bun $root/src/install.ts --dry-run"
  fi

  if out=$("$root/bin/harness-service" install --bun "$bun" 2>&1); then
    ui_ok "harness serve: ${out##*$'\n'}"
  else
    den_fail "harness serve did not start: ${out##*$'\n'}" "$root/bin/harness-service status"
  fi
}
