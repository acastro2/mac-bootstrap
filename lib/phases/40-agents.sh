# shellcheck shell=bash
# lib/phases/40-agents.sh — the coding agent CLIs.
# Claude Code and OpenCode on both OSes; cortex and tgrep in the VM only.
# Contract: docs/den/CONTRACT.md ("Host vs VM").

den_phase agents \
  --title "Agent CLIs" \
  --about "Claude Code and OpenCode here and in the VM; cortex and tgrep in the VM" \
  --os any \
  --toggle DEN_AGENTS \
  --needs "net"

# One quiet line; never fails the caller under pipefail.
agent_version() {
  local out=""
  out=$("$1" --version 2>/dev/null | head -n 1 || true) || out=""
  printf '%s' "${out:-unknown}"
}

# agent_install <title> <url> <bash|sh>: the official curl installer.
# Output is kept for the failure message only; it is noisy and never a secret.
agent_install() {
  local title=$1 url=$2 shell=$3 log=""
  log=$(mktemp "${TMPDIR:-/tmp}/den-agent.XXXXXX") || log=/dev/null
  ui_step "installing $title"
  if { curl -fsSL "$url" | "$shell"; } >"$log" 2>&1; then
    if [ "$log" != /dev/null ]; then
      rm -f "$log"
    fi
    return 0
  fi
  ui_err "$title: the installer failed"
  if [ "$log" != /dev/null ]; then
    tail -n 20 "$log" | sed 's/^/    /' >&2 || true
    rm -f "$log"
  fi
  return 1
}

# tgrep ships as a plain release archive, not a curl installer.
agent_tgrep() {
  local target="" tmp="" bin="" os_arch
  os_arch=$(uname -s)-$(uname -m)
  case $os_arch in
    Linux-aarch64) target=aarch64-unknown-linux-musl ;;
    Linux-x86_64) target=x86_64-unknown-linux-musl ;;
    *)
      ui_warn "tgrep: no release for $os_arch"
      return 0
      ;;
  esac
  if ! command -v gh >/dev/null 2>&1; then
    ui_warn "tgrep: gh is not installed, so the release cannot be fetched"
    return 0
  fi
  tmp=$(mktemp -d) || return 1
  ui_step "installing tgrep"
  if ! gh release download --repo microsoft/tgrep -p "*${target}*" -D "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"
    ui_warn "tgrep: the release download failed"
    return 1
  fi
  # Unpack the whole archive: GNU tar and bsdtar disagree about members
  # named ./tgrep, so asking for one member by name fails on one of them.
  if ! tar xzf "$tmp"/tgrep-*.tar.gz -C "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"
    ui_warn "tgrep: the archive did not extract"
    return 1
  fi
  bin=$(find "$tmp" -type f -name tgrep | head -n 1 || true) || bin=""
  if [ -z "$bin" ]; then
    rm -rf "$tmp"
    ui_warn "tgrep: the archive holds no tgrep binary"
    return 1
  fi
  mkdir -p "$HOME/.local/bin"
  if ! install -m 755 "$bin" "$HOME/.local/bin/tgrep"; then
    rm -rf "$tmp"
    ui_warn "tgrep: could not install the binary"
    return 1
  fi
  rm -rf "$tmp"
  ui_ok "tgrep: $(agent_version "$HOME/.local/bin/tgrep")"
  return 0
}

phase_agents() {
  local list=${DEN_AGENTS:-opencode claude cortex} os failed=""

  os=$(den_os)

  case " $list " in
    *" claude "*)
      if [ -x "$HOME/.local/bin/claude" ]; then
        ui_ok "Claude Code: $(agent_version "$HOME/.local/bin/claude")"
      elif agent_install "Claude Code (native installer)" https://claude.ai/install.sh bash; then
        if [ -x "$HOME/.local/bin/claude" ]; then
          ui_ok "Claude Code: $(agent_version "$HOME/.local/bin/claude")"
        else
          ui_err "Claude Code: the installer left no ~/.local/bin/claude"
          failed="$failed claude"
        fi
      else
        failed="$failed claude"
      fi
      ;;
  esac

  case " $list " in
    *" opencode "*)
      if [ -x "$HOME/.opencode/bin/opencode" ]; then
        ui_ok "OpenCode: $(agent_version "$HOME/.opencode/bin/opencode")"
      elif agent_install "OpenCode (v2 installer)" https://opencode.ai/v2/install bash; then
        if [ -x "$HOME/.opencode/bin/opencode" ]; then
          ui_ok "OpenCode: $(agent_version "$HOME/.opencode/bin/opencode")"
        else
          ui_err "OpenCode: the installer left no ~/.opencode/bin/opencode"
          failed="$failed opencode"
        fi
      else
        failed="$failed opencode"
      fi
      ;;
  esac

  # Snowflake's tools are for the Linux dev box, never the Mac.
  if [ "$os" = linux ]; then
    case " $list " in
      *" cortex "*)
        if [ -x "$HOME/.local/bin/cortex" ]; then
          ui_ok "cortex: already installed"
        elif agent_install "Cortex Code CLI" https://ai.snowflake.com/static/cc-scripts/install.sh sh; then
          if [ -x "$HOME/.local/bin/cortex" ]; then
            ui_ok "cortex: installed"
          else
            ui_err "cortex: the installer left no ~/.local/bin/cortex"
            failed="$failed cortex"
          fi
        else
          failed="$failed cortex"
        fi
        ;;
    esac
    case " $list " in
      *" tgrep "*)
        if [ -x "$HOME/.local/bin/tgrep" ]; then
          ui_ok "tgrep: $(agent_version "$HOME/.local/bin/tgrep")"
        elif ! agent_tgrep; then
          failed="$failed tgrep"
        fi
        ;;
    esac
  fi

  if [ -n "$failed" ]; then
    den_fail "these agents failed to install:$failed" "den up --only=agents"
  fi
}
