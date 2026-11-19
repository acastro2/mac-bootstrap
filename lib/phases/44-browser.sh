# shellcheck shell=bash
# lib/phases/44-browser.sh — browser automation in the VM: Playwright,
# browser-use and the browse CLI. Contract: docs/den/CONTRACT.md ("VM guest").

den_phase browser \
  --title "Browser automation" \
  --about "Playwright, browser-use and the browse CLI, in the VM" \
  --os linux \
  --needs "net"

# The browse package carries the native binary per platform; a node upgrade
# moves it, so the ~/.local/bin link follows the active mise node.
browser_browse_link() {
  local arch="" root="" bin="" link="$HOME/.local/bin/browse" current=""

  if ! command -v mise >/dev/null 2>&1; then
    ui_warn "browse: mise is not installed; skipping"
    return 0
  fi
  case $(uname -m) in
    x86_64) arch=x64 ;;
    *) arch=arm64 ;;
  esac
  root=$(mise exec -- npm root -g 2>/dev/null || true) || root=""
  if [ -z "$root" ]; then
    ui_warn "browse: npm's global root is unknown; skipping"
    return 0
  fi
  bin="$root/@opencode/browse/node_modules/@opencode/browse-linux-$arch/bin/browse"
  if [ ! -x "$bin" ]; then
    ui_step "installing @opencode/browse"
    if ! mise exec -- npm install -g @opencode/browse >/dev/null 2>&1; then
      ui_warn "browse: the npm install failed"
      return 1
    fi
  fi
  if [ ! -x "$bin" ]; then
    ui_warn "browse: the package holds no binary for this platform"
    return 1
  fi
  current=$(readlink "$link" 2>/dev/null || true) || current=""
  if [ "$current" != "$bin" ]; then
    mkdir -p "$HOME/.local/bin"
    if ! ln -sfn "$bin" "$link"; then
      ui_warn "browse: could not link $link"
      return 1
    fi
    ui_ok "linked $link"
  fi
  return 0
}

# The Playwright chromium download: the uv tool, the mise npm CLI, or PATH.
browser_playwright_install() {
  if command -v playwright >/dev/null 2>&1; then
    if playwright install chromium; then return 0; fi
    return 1
  fi
  if [ -x "$HOME/.local/bin/playwright" ]; then
    if "$HOME/.local/bin/playwright" install chromium; then return 0; fi
    return 1
  fi
  if command -v mise >/dev/null 2>&1 && mise exec -- playwright --version >/dev/null 2>&1; then
    if mise exec -- playwright install chromium; then return 0; fi
    return 1
  fi
  return 2
}

phase_browser() {
  local failed="" out="" rc=0

  if command -v uv >/dev/null 2>&1; then
    ui_step "installing Playwright and browser-use as uv tools"
    if ! out=$(uv tool install --upgrade playwright 2>&1); then
      ui_err "the Playwright (python) install failed"
      printf '%s\n' "$out" | tail -n 10 | sed 's/^/    /' >&2 || true
      failed="$failed playwright"
    fi
    if ! out=$(uv tool install --upgrade browser-use 2>&1); then
      ui_err "the browser-use install failed"
      printf '%s\n' "$out" | tail -n 10 | sed 's/^/    /' >&2 || true
      failed="$failed browser-use"
    fi
  else
    ui_warn "uv is not installed; skipping the Python browser tools"
  fi

  out=$(browser_playwright_install 2>&1) || rc=$?
  case $rc in
    0) ui_ok "chromium for Playwright" ;;
    2) ui_warn "playwright is not on PATH yet; run mise install, then den fix" ;;
    *)
      ui_err "the chromium download failed"
      printf '%s\n' "$out" | tail -n 10 | sed 's/^/    /' >&2 || true
      failed="$failed chromium"
      ;;
  esac

  if ! browser_browse_link; then
    failed="$failed browse"
  fi

  if [ -n "$failed" ]; then
    den_fail "browser tooling failed to install:$failed" "den up --only=browser"
  fi
}
