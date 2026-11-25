# shellcheck shell=bash
# lib/phases/76-vm-harness.sh — one CA and one passkey for the harness page on
# the Mac and in the VM. The Mac trusts the mkcert CA in the login keychain
# (no admin needed; macOS asks for the user's password), the CA files are copied into the guest on stdin, the
# guest issues its cert from them, and passkey.json (public half only) is
# copied to whichever side lacks it. Secrets ride stdin only: the CA key is
# never in argv, den state or logs. A re-run with nothing new copies and
# restarts nothing (sha256 compare first). Bash 3.2.
# shellcheck disable=SC2154  # AGENT_VM, DEN_GUEST_ENV come from config/lib.

den_phase vm-harness \
  --title "Harness TLS and passkey in the VM" \
  --about "one mkcert CA on the Mac and in the VM, and one shared harness passkey.json" \
  --os macos \
  --toggle DEN_VM

# Guest side. Modes: hashes (print "<name> <sha256|->"), getpasskey (print
# passkey.json in base64), put (stdin lines "<ca|key|passkey> <base64>", then
# run harness-tls and restart harness-serve if it printed `issued`).
# CAROOT and HOME may be set by the caller (the test does).
# shellcheck disable=SC2016  # the guest shell expands it, not this one
DEN_HARNESS_GUEST='
mode=$1
caroot=${CAROOT:-$(mkcert -CAROOT 2>/dev/null || true)}
[ -n "$caroot" ] || caroot=$HOME/.local/share/mkcert
pk=$HOME/.config/harness/passkey.json
sum() { if [ -f "$1" ]; then sha256sum "$1" | cut -d" " -f1; else echo -; fi; }
case $mode in
  hashes)
    echo "ca $(sum "$caroot/rootCA.pem")"
    echo "key $(sum "$caroot/rootCA-key.pem")"
    echo "passkey $(sum "$pk")"
    command -v mkcert >/dev/null 2>&1 && echo "mkcert yes" || echo "mkcert no" ;;
  getpasskey) base64 <"$pk" | tr -d "\n" ;;
  bwrap)
    # Ubuntu 24.04 blocks unprivileged user namespaces (apparmor_restrict_unprivileged_userns=1),
    # so bwrap needs an AppArmor profile. Prints one word: ok, failed, nosudo, nobwrap
    # (and "dry" when DEN_BWRAP_DRY=1 and a write would be needed; nothing runs then).
    if ! command -v bwrap >/dev/null 2>&1; then echo nobwrap; exit 0; fi
    bw_test() { bwrap --ro-bind / / --dev /dev --proc /proc true >/dev/null 2>&1; }
    prof=/etc/apparmor.d/bwrap
    if bw_test; then echo ok; exit 0; fi
    if [ ! -e "$prof" ]; then
      if [ "${DEN_BWRAP_DRY:-}" = 1 ]; then
        echo "would run: sudo -n tee $prof, with this profile:" >&2
        cat >&2 <<"PROFILE"
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
PROFILE
        echo "would run: sudo -n apparmor_parser -r $prof" >&2
        echo dry; exit 0
      fi
      if ! sudo -n true >/dev/null 2>&1; then echo nosudo; exit 0; fi
      sudo -n tee "$prof" >/dev/null <<"PROFILE"
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
PROFILE
      sudo -n apparmor_parser -r "$prof" >/dev/null 2>&1 || true
    fi
    if bw_test; then echo ok; else echo failed; fi ;;
  put)
    umask 077
    mkdir -p "$caroot" "$(dirname "$pk")"
    while read -r name b64; do
      case $name in
        ca) dest=$caroot/rootCA.pem ;;
        key) dest=$caroot/rootCA-key.pem ;;
        passkey) dest=$pk ;;
        *) continue ;;
      esac
      printf "%s" "$b64" | base64 -d >"$dest.new" && chmod 600 "$dest.new" && mv "$dest.new" "$dest"
    done
    tls=$HOME/.agents/skills/harness/bin/harness-tls
    if [ -x "$tls" ] && command -v mkcert >/dev/null 2>&1; then
      if out=$(CAROOT=$caroot "$tls" 2>&1); then
        case "
$out
" in
          *"
issued"*)
            XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemctl --user restart harness-serve >/dev/null 2>&1 || true
            echo issued ;;
          *) echo current ;;
        esac
      else
        echo tlsfailed
      fi
    else
      echo notls
    fi ;;
esac
'

# den_vm_harness_guest MODE: stdin is the caller's.
den_vm_harness_guest() {
  den_vm_to 90 limactl shell "$AGENT_VM" -- bash -c "${DEN_GUEST_ENV}$DEN_HARNESS_GUEST" _ "$@" 2>/dev/null | tr -d '\r'
}

den_vm_harness_b64() { base64 <"$1" | tr -d '\n'; }

den_vm_harness_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

phase_vm_harness() {
  local vm=${AGENT_VM:-} s="" caroot="" h="" gca="" gkey="" gpk="" gmk=""
  local hpk="$HOME/.config/harness/passkey.json" lpk="" word="" tmp="" name="" val=""
  if [ -z "$vm" ]; then
    den_skip "AGENT_VM is empty in config.env" "set AGENT_VM in config.env"
  fi
  if ! command -v limactl >/dev/null 2>&1; then
    den_skip "limactl is not installed" "brew install lima"
  fi
  if ! command -v mkcert >/dev/null 2>&1; then
    den_skip "mkcert is not installed" "den up --only=packages"
  fi
  s=$(den_vm_status "$vm") || s=""
  if [ "$s" != Running ]; then
    den_skip "$vm is not Running" "den vm up"
  fi

  # Mac side: make the CA and trust it in the LOGIN keychain. `mkcert -install`
  # writes the System keychain, which needs an admin; a user trust setting
  # needs only the user's own password (a macOS dialog), and Edge honours it.
  caroot=$(mkcert -CAROOT)
  if [ ! -f "$caroot/rootCA.pem" ] || [ ! -f "$caroot/rootCA-key.pem" ]; then
    # Any mkcert run creates the CA; the throwaway cert goes to a temp dir.
    local ct=""
    ct=$(mktemp -d) || den_fail "mktemp failed" "den up --only=vm-harness"
    (cd "$ct" && mkcert localhost >/dev/null 2>&1) || true
    rm -rf "$ct"
  fi
  if [ ! -f "$caroot/rootCA.pem" ] || [ ! -f "$caroot/rootCA-key.pem" ]; then
    den_fail "mkcert could not create a CA in $caroot" "mkcert localhost"
  fi
  if security verify-cert -c "$caroot/rootCA.pem" >/dev/null 2>&1; then
    ui_info "mkcert CA already trusted on this Mac"
  elif security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$caroot/rootCA.pem" >/dev/null 2>&1; then
    ui_ok "mkcert CA trusted in the login keychain"
  else
    den_fail "could not trust the mkcert CA (cancelled, or the keychain is locked)" \
      "security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db \"\$(mkcert -CAROOT)/rootCA.pem\""
  fi

  h=$(den_vm_harness_guest hashes </dev/null) || h=""
  while read -r name val; do
    case $name in
      ca) gca=$val ;;
      key) gkey=$val ;;
      passkey) gpk=$val ;;
      mkcert) gmk=$val ;;
    esac
  done <<EOF
$h
EOF
  if [ -z "$gca" ]; then
    den_fail "could not talk to $vm" "den vm status"
  fi
  if [ "$gmk" != yes ]; then
    den_skip "mkcert is not installed in $vm" "den up --only=packages inside the VM (Brewfile.linux has mkcert)"
  fi

  # Payload on stdin: only what the guest lacks or has different.
  tmp=$(mktemp -d) || den_fail "mktemp failed" "den up --only=vm-harness"
  : >"$tmp/payload"
  chmod 600 "$tmp/payload"
  if [ "$gca" != "$(den_vm_harness_sha "$caroot/rootCA.pem")" ]; then
    printf 'ca %s\n' "$(den_vm_harness_b64 "$caroot/rootCA.pem")" >>"$tmp/payload"
  fi
  if [ "$gkey" != "$(den_vm_harness_sha "$caroot/rootCA-key.pem")" ]; then
    printf 'key %s\n' "$(den_vm_harness_b64 "$caroot/rootCA-key.pem")" >>"$tmp/payload"
  fi

  # Passkey: copy to the side that lacks it; both and different is a human call.
  if [ -f "$hpk" ]; then
    lpk=$(den_vm_harness_sha "$hpk")
  fi
  if [ "$gpk" = "-" ] && [ -n "$lpk" ]; then
    printf 'passkey %s\n' "$(den_vm_harness_b64 "$hpk")" >>"$tmp/payload"
  elif [ "$gpk" != "-" ] && [ -z "$lpk" ]; then
    mkdir -p "$(dirname "$hpk")"
    if (umask 077; den_vm_harness_guest getpasskey </dev/null | base64 -D >"$hpk.new") &&
      [ -s "$hpk.new" ] && chmod 600 "$hpk.new" && mv "$hpk.new" "$hpk"; then
      ui_ok "passkey.json copied from $vm to this Mac"
    else
      rm -f "$hpk.new"
      ui_warn "could not copy passkey.json from $vm"
    fi
  elif [ "$gpk" != "-" ] && [ -n "$lpk" ] && [ "$gpk" != "$lpk" ]; then
    ui_warn "passkey.json differs between this Mac and $vm; kept both, copy one by hand"
  fi

  word=$(den_vm_harness_guest put <"$tmp/payload" | tail -n 1) || word=""
  rm -rf "$tmp"
  case $word in
    issued) ui_ok "$vm harness cert issued from the shared CA; harness-serve restarted" ;;
    current) ui_ok "$vm harness cert is current" ;;
    notls) den_skip "$vm has no harness-tls yet" "den up --only=config-repos, then den up --only=vm-harness" ;;
    *) den_fail "harness-tls failed in $vm (${word:-no answer})" "den vm shell, then ~/.agents/skills/harness/bin/harness-tls" ;;
  esac
  den_vm_harness_bwrap "$vm"
}

# den_vm_harness_bwrap VM: let bwrap make user namespaces in the guest.
den_vm_harness_bwrap() {
  local vm=$1 word=""
  word=$(den_vm_harness_guest bwrap </dev/null | tail -n 1) || word=""
  case $word in
    ok) ui_ok "bwrap ok in $vm" ;;
    nobwrap) ui_info "bwrap is not installed in $vm; skipped" ;;
    nosudo) ui_warn "bwrap is blocked in $vm and sudo -n is not available; run in the VM: printf 'abi <abi/4.0>,\ninclude <tunables/global>\n\nprofile bwrap /usr/bin/bwrap flags=(unconfined) {\n  userns,\n  include if exists <local/bwrap>\n}\n' | sudo tee /etc/apparmor.d/bwrap && sudo apparmor_parser -r /etc/apparmor.d/bwrap" ;;
    *) ui_warn "bwrap failed in $vm (${word:-no answer}); check /etc/apparmor.d/bwrap and run: sudo apparmor_parser -r /etc/apparmor.d/bwrap" ;;
  esac
}
