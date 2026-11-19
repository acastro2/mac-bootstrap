# shellcheck shell=bash
# 24-app-clis.sh — Mac command-line tools that live in ~/.local/bin: the browse
# CLI (the relay VM agents reach through the tunnel) and the VS Code CLI.

den_phase app-clis \
  --title "App CLI commands" \
  --about "The browse CLI and the VS Code CLI, in ~/.local/bin" \
  --os macos \
  --needs net

# app_clis_browse: the native browse binary from the npm registry, with the
# registry's sha512 integrity checked. No node needed on the Mac. vm-up runs
# `browse serve` from this path; without it the VM tunnel has nothing to reach.
app_clis_browse() {
  local dest="$HOME/.local/bin/browse" arch meta url want got tmp
  if [ -x "$dest" ]; then
    ui_ok "browse $("$dest" --version 2>/dev/null | head -n 1) is in ~/.local/bin"
    return 0
  fi
  case $(uname -m) in
    arm64) arch=arm64 ;;
    *) arch=x64 ;;
  esac
  meta=$(curl -fsS --connect-timeout 15 -m 30 "https://registry.npmjs.org/@opencode/browse-darwin-$arch/latest") || {
    ui_warn "browse: the npm registry did not answer; run den up --only=app-clis later"
    return 1
  }
  url=$(printf '%s' "$meta" | jq -r '.dist.tarball // empty')
  want=$(printf '%s' "$meta" | jq -r '.dist.integrity // empty')
  if [ -z "$url" ] || [ -z "$want" ]; then
    ui_warn "browse: the registry answer has no tarball or integrity"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/den-browse.XXXXXX") || return 1
  if ! curl -fsS --connect-timeout 15 -m 300 -o "$tmp/browse.tgz" "$url"; then
    rm -rf "$tmp"
    ui_warn "browse: the download failed"
    return 1
  fi
  got="sha512-$(openssl dgst -sha512 -binary "$tmp/browse.tgz" | openssl base64 -A)"
  if [ "$got" != "$want" ]; then
    rm -rf "$tmp"
    ui_err "browse: integrity mismatch; nothing installed"
    return 1
  fi
  if ! tar -xzf "$tmp/browse.tgz" -C "$tmp" package/bin/browse; then
    rm -rf "$tmp"
    ui_warn "browse: the archive has no package/bin/browse"
    return 1
  fi
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$tmp/package/bin/browse" "$dest"
  rm -rf "$tmp"
  ui_ok "browse $("$dest" --version 2>/dev/null | head -n 1) installed in ~/.local/bin (integrity checked)"
}

phase_app_clis() {
  local vsc="$HOME/Applications/Visual Studio Code.app" failed=0
  app_clis_browse || failed=1
  if [ ! -x "$vsc/Contents/Resources/app/bin/code" ]; then
    den_skip "VS Code is not in ~/Applications" \
      "install VS Code with den up --only=packages, then den up --only=app-clis"
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$vsc/Contents/Resources/app/bin/code" "$HOME/.local/bin/code"
  ui_ok "code -> ~/.local/bin/code"
  if [ "$failed" = 1 ]; then
    den_fail "the browse CLI did not install" "den up --only=app-clis"
  fi
}
