# shellcheck shell=bash
# lib/phases/46-secrets.sh — the shell's API keys, rendered from the den bundle.
# The bundle comes from 1Password or ~/den.json (lib/secrets.sh); this phase
# only writes the derived file, so no value ever reaches a log or argv.
# Contract: docs/den/CONTRACT.md ("Secrets").

den_phase secrets \
  --title "Secrets" \
  --about "render the API keys the zsh config sources from the den bundle" \
  --os any \
  --needs "secrets"

phase_secrets() {
  # den_render_env reports the key count, never a value, and refuses to
  # replace the file with an empty set.
  den_render_env "$HOME/.config/zsh/.api-keys.zsh"
}
