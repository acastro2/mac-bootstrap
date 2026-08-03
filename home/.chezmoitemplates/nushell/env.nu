# Nushell environment managed by chezmoi.

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

$env.CARAPACE_BRIDGES = "zsh,fish,bash,inshellisense"

# Trust the corporate CA for Node-based tools and MCP clients.
let corporate_ca_bundle = ($env.HOME | path join ".config" "corporate-ca-bundle.pem")
if ($corporate_ca_bundle | path exists) {
  $env.NODE_EXTRA_CA_CERTS = $corporate_ca_bundle
}
