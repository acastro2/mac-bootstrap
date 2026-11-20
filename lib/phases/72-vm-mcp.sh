# shellcheck shell=bash
# lib/phases/72-vm-mcp.sh — register the superlogical MCP in the agent VM's
# Claude Code. The gated URL comes from the den bundle and reaches the guest
# on stdin only (vm/mcp-register.sh reads it); it is never in Mac argv, a
# message, or state. Bash 3.2.
# Contract: docs/den/CONTRACT.md (rule 5, "VM guest").
# shellcheck disable=SC2154  # AGENT_VM, DEN_ROOT come from config/lib.

den_phase vm-mcp \
  --title "Superlogical MCP in the VM" \
  --about "the superlogical MCP in the VM's Claude Code, URL from the den bundle" \
  --os macos \
  --toggle DEN_VM \
  --needs "secrets"

phase_vm_mcp() {
  local vm=${AGENT_VM:-} mcp="" s="" word=""
  if [ -z "$vm" ]; then
    den_skip "AGENT_VM is empty in config.env" "set AGENT_VM in config.env"
  fi
  if ! command -v limactl >/dev/null 2>&1; then
    den_skip "limactl is not installed" "brew install lima"
  fi
  s=$(den_vm_status "$vm") || s=""
  if [ "$s" != Running ]; then
    den_skip "$vm is not Running" "den vm up"
  fi
  mcp=$(den_secret .rex.mcp)
  if [ -z "$mcp" ]; then
    den_skip "the den bundle has no rex.mcp" "add rex.mcp to the den document or ~/den.json, then den up --only=vm-mcp"
  fi

  # The URL rides stdin only. The script text may sit in argv: it holds no
  # secret. The leading no-op names the job in `ps` and in the limactl log.
  word=$(printf '%s\n' "$mcp" |
    den_vm_to 60 limactl shell "$vm" -- bash -c ": superlogical-mcp; ${DEN_GUEST_ENV}$(cat "${DEN_ROOT}/vm/mcp-register.sh")" 2>/dev/null |
    tr -d '\r' | tail -n 1) || word=""
  mcp=""

  case $word in
    ok) ui_ok "superlogical MCP is already registered in the $vm Claude Code" ;;
    added) ui_ok "superlogical MCP registered in the $vm Claude Code" ;;
    noclaude) den_skip "Claude Code is not installed in $vm" "den up --only=vm" ;;
    *) den_fail "could not register the superlogical MCP in $vm (${word:-no answer})" "den up --only=vm-mcp" ;;
  esac
}
