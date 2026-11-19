# shellcheck shell=bash
# 34-ssh.sh — GitHub host key and the 1Password SSH agent.

den_phase ssh \
  --title "SSH config" \
  --about "Trust github.com once and use the 1Password SSH agent" \
  --os any

phase_ssh() {
  local known=$HOME/.ssh/known_hosts config=$HOME/.ssh/config
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # Append, never rewrite: other hosts people trust must survive.
  if [ -f "$known" ] && ssh-keygen -F github.com -f "$known" >/dev/null 2>&1; then
    ui_ok "github.com is already in known_hosts"
  else
    # ssh-keyscan is unauthenticated, so a key is trusted only when its
    # fingerprint matches what GitHub publishes over HTTPS (api.github.com/meta).
    ui_step "adding github.com to known_hosts (fingerprints checked against api.github.com)"
    local scan published line fp added=0
    scan=$(mktemp "${TMPDIR:-/tmp}/den-keyscan.XXXXXX")
    published=$(curl -fsS -m 10 https://api.github.com/meta 2>/dev/null \
      | tr -d ' \n' | grep -o '"ssh_key_fingerprints":{[^}]*}' | grep -o 'SHA256_[A-Z0-9]*":"[^"]*' | sed 's/.*":"//') || published=""
    if [ -z "$published" ] || ! ssh-keyscan -T 5 github.com > "$scan" 2>/dev/null; then
      rm -f "$scan"
      den_skip "could not fetch GitHub's key fingerprints or scan github.com" "den up --only=ssh when the network is back"
    fi
    while IFS= read -r line; do
      case $line in ''|'#'*) continue ;; esac
      fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | sed 's/^SHA256://')
      if [ -n "$fp" ] && printf '%s\n' "$published" | grep -qxF "$fp"; then
        printf '%s\n' "$line" >> "$known"
        added=$((added + 1))
      else
        ui_warn "rejected a github.com key whose fingerprint GitHub does not publish"
      fi
    done < "$scan"
    rm -f "$scan"
    chmod 600 "$known" 2>/dev/null || true
    if [ "$added" -eq 0 ]; then
      den_fail "no github.com key matched GitHub's published fingerprints" \
        "check your network for interception, then den up --only=ssh"
    fi
    ui_ok "trusted $added verified github.com key(s)"
  fi

  if [ "$(den_os)" = macos ] && ! grep -qF "1Password" "$config" 2>/dev/null; then
    {
      printf '\n# 1Password SSH agent\n'
      printf 'Host *\n'
      printf '  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"\n'
    } >> "$config"
    ui_step "SSH now uses the 1Password agent"
  fi
  if [ -f "$config" ]; then
    chmod 600 "$config"
  fi
  ui_ok "SSH is ready"
}
