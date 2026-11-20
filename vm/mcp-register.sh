#!/usr/bin/env bash
# vm/mcp-register.sh — guest side of the vm-mcp phase: register the
# superlogical MCP in the guest's Claude Code. Runs inside the VM; the Mac
# pipes the gated URL on stdin (never argv on the Mac). Bash 3.2 safe.
# Contract: docs/den/CONTRACT.md (rule 5). Not named guest-*.sh on purpose:
# vm_guest_provision runs every guest-*.sh, and this one needs the URL.
#
# Prints exactly one word and never the URL. Always exits 0.
#   nourl     empty stdin; nothing added
#   noclaude  no claude on PATH
#   ok        already registered with this URL
#   added     registered (an old entry was replaced)
#   failed    claude mcp add returned nonzero

url=""
IFS= read -r url || true

if [ -z "$url" ]; then
  echo nourl
  exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
  echo noclaude
  exit 0
fi

# Compare without printing: the stored URL is gated.
have=$(claude mcp get superlogical 2>/dev/null || true)
# Whole-line match on the "  URL: " line: a stored URL that only contains
# the new one (an old token in the query) is not current.
if printf '%s\n' "$have" | grep -Fxq -- "  URL: $url"; then
  echo ok
  exit 0
fi

# No scope: drop the entry wherever it lives, so a stale local or project
# entry cannot shadow the new one (same as lib/phases/52-rex.sh).
claude mcp remove superlogical >/dev/null 2>&1 || true
if claude mcp add -s user --transport http superlogical "$url" >/dev/null 2>&1; then
  echo added
else
  echo failed
fi
exit 0
