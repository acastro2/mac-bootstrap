# Nushell environment managed by chezmoi.

# AWS SSO profiles belong in ~/.aws/config, not inherited shell credentials.
hide-env --ignore-errors AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

let brew_paths = [
  /opt/homebrew/bin
  /opt/homebrew/sbin
  /usr/local/bin
  /usr/local/sbin
  /home/linuxbrew/.linuxbrew/bin
  /home/linuxbrew/.linuxbrew/sbin
] | where { |path| $path | path exists }

$env.PATH = ($env.PATH
  | prepend $brew_paths
  | prepend ($env.HOME | path join ".opencode" "bin")
  | prepend ($env.HOME | path join ".local" "bin")
  | uniq)

$env.TENV_AUTO_INSTALL = "true"
$env.OPENCODE_EXPERIMENTAL = "true"
$env.GRAFANA_SERVER = "https://grafana.attainfinance.com"
$env.GRAFANA_ORG_ID = "1"

$env.CARAPACE_BRIDGES = "zsh,fish,bash,inshellisense"

# Trust the corporate CA for tools that don't use the macOS keychain.
# Opt-in: only activates if ~/.config/corporate-ca-bundle.pem exists.
# Personal machines: leave the file out — this block no-ops.
let corporate_ca_bundle = ($env.HOME | path join ".config" "corporate-ca-bundle.pem")
if ($corporate_ca_bundle | path exists) {
  # Node-based tools and MCP clients.
  $env.NODE_EXTRA_CA_CERTS = $corporate_ca_bundle
  # Python requests-based tools (pip ignores this; uses PIP_CERT below).
  $env.REQUESTS_CA_BUNDLE = $corporate_ca_bundle
  # OpenSSL-native tools (Python stdlib, misc CLIs with bundled OpenSSL).
  $env.SSL_CERT_FILE = $corporate_ca_bundle
  # curl and anything linked against it.
  $env.CURL_CA_BUNDLE = $corporate_ca_bundle
  # git (Homebrew build uses OpenSSL; system git uses the keychain instead).
  $env.GIT_SSL_CAINFO = $corporate_ca_bundle
  # pip itself.
  $env.PIP_CERT = $corporate_ca_bundle
  # AWS SDKs (Go v1/v2, boto3, CLI).
  $env.AWS_CA_BUNDLE = $corporate_ca_bundle
}
