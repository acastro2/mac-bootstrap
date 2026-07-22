# Nushell completions for opencode managed by chezmoi.

def "nu-complete opencode log-levels" [] {
  [DEBUG INFO WARN ERROR]
}

def "nu-complete opencode commands" [] {
  [
    { value: completion, description: "Generate shell completion script" }
    { value: acp, description: "Start ACP server" }
    { value: mcp, description: "Manage MCP servers" }
    { value: attach, description: "Attach to a running opencode server" }
    { value: run, description: "Run opencode with a message" }
    { value: debug, description: "Debugging tools" }
    { value: providers, description: "Manage AI providers and credentials" }
    { value: agent, description: "Manage agents" }
    { value: upgrade, description: "Upgrade opencode" }
    { value: uninstall, description: "Uninstall opencode" }
    { value: serve, description: "Start headless opencode server" }
    { value: web, description: "Start server and open web interface" }
    { value: models, description: "List all available models" }
    { value: stats, description: "Show token usage and cost" }
    { value: export, description: "Export session data as JSON" }
    { value: import, description: "Import session data from JSON" }
    { value: github, description: "Manage GitHub agent" }
    { value: pr, description: "Fetch and checkout a GitHub PR" }
    { value: session, description: "Manage sessions" }
    { value: plugin, description: "Install plugin and update config" }
    { value: db, description: "Database tools" }
  ]
}

extern opencode [
  command?: string@"nu-complete opencode commands"
  ...paths: path
  --help(-h)
  --version(-v)
  --model(-m): string
  --continue(-c)
  --session(-s): string
  --fork
  --prompt: string
  --agent: string
  --print-logs
  --log-level: string@"nu-complete opencode log-levels"
  --pure
  --port: int
  --hostname: string
  --mdns
]
