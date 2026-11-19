# shellcheck shell=bash
# lib/phases/42-mise.sh — the VM's toolchains, pinned by mise.
# LTS where a release line has one, latest stable elsewhere.
# Verified selectors (mise docs, docs/lang/dotnet.md and tool scopes):
#   node lts, dotnet lts (mise >= 2026.10.15), everything else latest.
# Contract: docs/den/CONTRACT.md ("Versions in the VM").

den_phase mise \
  --title "mise toolchains" \
  --about "go, node LTS, pnpm, python, .NET LTS, OpenTofu and the npm CLIs, in the VM" \
  --os linux \
  --needs "net"

phase_mise() {
  local cfg="$HOME/.config/mise/config.toml" tmp="" log=""

  if ! command -v mise >/dev/null 2>&1; then
    den_skip "mise is not installed" "brew install mise, then run den fix"
  fi

  mkdir -p "$HOME/.config/mise"
  tmp=$(mktemp "${TMPDIR:-/tmp}/den-mise.XXXXXX")
  cat >"$tmp" <<'EOF'
# Written by den. LTS where a release line has one, latest stable elsewhere.
# Per-project overrides go in .mise.toml or .tool-versions.
[tools]
go         = "latest"
node       = "lts"
pnpm       = "latest"
python     = "latest"
dotnet     = "lts"
opentofu   = "latest"
"npm:@playwright/test" = "latest"   # Node CLI for codegen, trace viewer, ad-hoc
"npm:@playwright/mcp"  = "latest"   # Microsoft's official Playwright MCP server
"npm:ctx7"             = "latest"   # Context7 documentation CLI
"aqua:terraform-linters/tflint" = "latest"

[settings]
experimental = true
python.github_attestations = false
EOF

  if [ -f "$cfg" ] && cmp -s "$tmp" "$cfg"; then
    rm -f "$tmp"
    ui_info "the mise global config is current"
  else
    mv "$tmp" "$cfg"
    ui_ok "wrote $cfg"
  fi

  mise trust "$cfg" >/dev/null 2>&1 || ui_warn "mise trust failed; a shell may ask to trust the config"

  # GitHub token only lifts the API rate limit while mise resolves releases.
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null | head -n 1 || true) || GITHUB_TOKEN=""
    export GITHUB_TOKEN
  fi

  log=$(mktemp "${TMPDIR:-/tmp}/den-mise-install.XXXXXX")
  ui_step "installing the mise toolchains"
  if ! mise install >"$log" 2>&1; then
    ui_err "some mise toolchains failed to install"
    tail -n 20 "$log" | sed 's/^/    /' >&2 || true
    rm -f "$log"
    den_fail "a mise install failed" "mise install"
  fi
  rm -f "$log"
  ui_ok "mise toolchains installed"
}
