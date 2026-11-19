# shellcheck shell=bash
# lib/phases/50-opencode-web.sh — the OpenCode web UI on the tailnet.
# The password is a den secret, never config. Contract: docs/den/CONTRACT.md.

den_phase opencode-web \
  --title "OpenCode web" \
  --about "the OpenCode web UI on the tailnet, password from the den bundle" \
  --os macos \
  --toggle DEN_OPENCODE_WEB \
  --needs "secrets"

phase_opencode_web() {
  local bin="" pw="" ip="" port=${OPENCODE_WEB_PORT:-} changed=0 failed=""

  if [ -x "$HOME/.opencode/bin/opencode" ]; then
    bin="$HOME/.opencode/bin/opencode"
  else
    bin=$(command -v opencode 2>/dev/null || true) || bin=""
  fi
  if [ -z "$bin" ]; then
    den_skip "opencode is not installed" "den up --only=agents"
  fi

  pw=$(den_secret .opencode_web.password)
  if [ -z "$pw" ]; then
    den_skip "the den bundle has no opencode_web.password" "add opencode_web.password to the den bundle, then run den fix"
  fi

  # Only touch the service when a value changes: `service set` stops the
  # background server, and a no-op re-run must not restart it.
  set_service() {
    local key=$1 want=$2 have=""
    have=$("$bin" service get "$key" 2>/dev/null | head -n 1 || true) || have=""
    if [ "$have" = "$want" ]; then
      ui_info "opencode service: $key already set"
      return 0
    fi
    # `service set` takes the value only as argv; it has no stdin or file
    # form. The password is therefore briefly visible in this process's argv.
    if "$bin" service set "$key" "$want" >/dev/null 2>&1; then
      changed=1
      ui_ok "opencode service: set $key"
    else
      ui_err "opencode service: could not set $key"
      failed="$failed $key"
    fi
  }

  set_service password "$pw"

  if command -v tailscale >/dev/null 2>&1; then
    ip=$(tailscale ip -4 2>/dev/null | head -n 1 || true) || ip=""
  fi
  if [ -n "$ip" ]; then
    set_service hostname "$ip"
  else
    ui_warn "Tailscale is not running; the web server stays on localhost"
  fi
  if [ -n "$port" ]; then
    set_service port "$port"
  else
    ui_warn "OPENCODE_WEB_PORT is empty; keeping the current port"
  fi

  if [ "$changed" = 1 ]; then
    if "$bin" service start >/dev/null 2>&1; then
      ui_ok "started the OpenCode service"
    else
      ui_warn "the OpenCode service did not start"
    fi
  fi

  if [ -n "$failed" ]; then
    den_fail "could not set the OpenCode service:$failed" "den up --only=opencode-web"
  fi
  ui_info "web login: user opencode, password from the den bundle (opencode_web.password)"
}
