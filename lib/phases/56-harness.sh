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

  # The cert comes from the CA this host already has (den never runs
  # `mkcert -install` here: the Mac trusts it in 76-vm-harness, the VM gets the
  # Mac's CA copied in). No CA yet is a warning, not a failure.
  local caroot="" tls="" issued=0
  if command -v mkcert >/dev/null 2>&1 && [ -x "$root/bin/harness-tls" ]; then
    caroot=$(mkcert -CAROOT 2>/dev/null || true) || caroot=""
    if [ -n "$caroot" ] && [ -f "$caroot/rootCA.pem" ]; then
      if tls=$("$root/bin/harness-tls" 2>&1); then
        case $'\n'$tls$'\n' in
          *$'\n'issued*) issued=1 ;; # harness-tls prints "issued: <path>"
        esac
        ui_ok "harness tls: ${tls##*$'\n'}"
      else
        ui_warn "harness-tls failed: ${tls##*$'\n'} (run $root/bin/harness-tls)"
      fi
    else
      ui_warn "no mkcert CA yet, the harness page stays on http. Mac: den up --only=vm-harness. VM: den up --only=vm-harness from the Mac"
    fi
  else
    ui_warn "mkcert or harness-tls is missing, the harness page stays on http (fix: den up --only=packages)"
  fi

  if out=$("$root/bin/harness-service" install --bun "$bun" 2>&1); then
    ui_ok "harness serve: ${out##*$'\n'}"
  else
    den_fail "harness serve did not start: ${out##*$'\n'}" "$root/bin/harness-service status"
  fi

  # harness-service restarts only when its own unit changes; a new cert needs it.
  if [ "$issued" = 1 ]; then
    if [ "$(uname)" = Darwin ]; then
      launchctl kickstart -k "gui/$(id -u)/com.alex.harness-serve" >/dev/null 2>&1 ||
        ui_warn "could not restart harness serve: launchctl kickstart -k gui/$(id -u)/com.alex.harness-serve"
    else
      XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemctl --user restart harness-serve >/dev/null 2>&1 ||
        ui_warn "could not restart harness serve: systemctl --user restart harness-serve"
    fi
  fi
}
