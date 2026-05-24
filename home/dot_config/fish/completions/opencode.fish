# Fish completions for opencode — managed by chezmoi
# Regenerate with: opencode completion fish (if/when supported)

# Global flags
complete -c opencode -s h -l help        -d "Show help"
complete -c opencode -s v -l version     -d "Show version"
complete -c opencode -s m -l model       -d "Model to use (provider/model)" -r
complete -c opencode -s c -l continue    -d "Continue last session"
complete -c opencode -s s -l session     -d "Session ID to continue" -r
complete -c opencode      -l fork        -d "Fork the session when continuing"
complete -c opencode      -l prompt      -d "Prompt to use" -r
complete -c opencode      -l agent       -d "Agent to use" -r
complete -c opencode      -l print-logs  -d "Print logs to stderr"
complete -c opencode      -l log-level   -d "Log level" -r -a "DEBUG INFO WARN ERROR"
complete -c opencode      -l pure        -d "Run without external plugins"
complete -c opencode      -l port        -d "Port to listen on" -r
complete -c opencode      -l hostname    -d "Hostname to listen on" -r
complete -c opencode      -l mdns        -d "Enable mDNS service discovery"

# Subcommands
set -l subcommands completion acp mcp attach run debug providers agent \
                  upgrade uninstall serve web models stats export import \
                  github pr session plugin db

complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a completion -d "Generate shell completion script"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a acp -d "Start ACP server"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a mcp -d "Manage MCP servers"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a attach -d "Attach to a running opencode server"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a run -d "Run opencode with a message"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a debug -d "Debugging tools"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a providers -d "Manage AI providers and credentials"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a agent -d "Manage agents"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a upgrade -d "Upgrade opencode"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a uninstall -d "Uninstall opencode"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a serve -d "Start headless opencode server"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a web -d "Start server and open web interface"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a models -d "List all available models"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a stats -d "Show token usage and cost"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a export -d "Export session data as JSON"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a import -d "Import session data from JSON"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a github -d "Manage GitHub agent"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a pr -d "Fetch and checkout a GitHub PR"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a session -d "Manage sessions"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a plugin -d "Install plugin and update config"
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a db -d "Database tools"

# Default: open a project directory
complete -c opencode -n "not __fish_seen_subcommand_from $subcommands" \
  -a "(__fish_complete_directories)" -d "Project path"
