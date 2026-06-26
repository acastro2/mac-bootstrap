# MacBook Migration Runbook

Agent-executable runbook for migrating a fully configured MacBook to another machine via AirDrop. This document is designed to be handed to opencode or Claude Code as instructions.

## Context

- **Source machine**: the MacBook you're migrating FROM (has all the data)
- **Target machine**: the MacBook you're migrating TO (fresh or recovered)
- **Transfer method**: AirDrop (no network/rsync between machines)
- **Automation repo**: `~/Developer/github/acastro2/mac-bootstrap`

## Prerequisites

The target machine needs:
- macOS with internet access
- A terminal open (zsh is fine, fish will be installed by bootstrap)
- Git and Xcode CLI tools (bootstrap handles this if missing)

---

## Phase 1: Export from Source Machine

Run these on the source MacBook. All outputs land on `~/Desktop` for easy AirDrop.

### 1.1 Export session data (opencode + Claude Code conversations)

```bash
cd ~/Developer/github/acastro2/mac-bootstrap
./bootstrap.sh --export-sessions
```

This creates `~/Desktop/agent-sessions-<timestamp>.tar.gz` containing:
- `~/.local/share/opencode/opencode.db` (all opencode sessions)
- `~/.claude/projects/` (all Claude Code conversations)
- `~/.claude/history.jsonl` (Claude session index)
- `~/.claude.json` (account state, project settings)
- `~/Library/Application Support/Claude/claude_desktop_config.json`
- `~/Developer/**/.cortex/` (all Cortex Code plans, per-project)
- `~/.snowflake/cortex/conversations/` (all Cortex Code sessions, 38MB+)
- `~/.snowflake/cortex/settings.json`, `cortex.json`, `permissions.json`, `skills.json`
- `~/.snowflake/cortex/skills/`, `plugins/`, `commands/`, `history/`
- `~/.snowflake/cortex/thread_goals.sqlite`
- `~/.snowflake/connections.toml` + `config.toml` (Snowflake connection config)
- `~/.config/fish/completions/cortex.fish`

Note: the Cortex cache (~154MB) is intentionally excluded since it rebuilds on use.

### 1.2 Push config repos

Ensure all config repos are up to date:

```bash
# opencode config
git -C ~/.config/opencode add -A && git -C ~/.config/opencode commit -m "pre-migration snapshot" && git -C ~/.config/opencode push

# Claude Code config (CLAUDE.md, settings, hooks, pandoc templates)
git -C ~/.claude add -A && git -C ~/.claude commit -m "pre-migration snapshot" && git -C ~/.claude push

# Skills
git -C ~/.agents/skills add -A && git -C ~/.agents/skills commit -m "pre-migration snapshot" && git -C ~/.agents/skills push

# mac-bootstrap itself
git -C ~/Developer/github/acastro2/mac-bootstrap add -A && git -C ~/Developer/github/acastro2/mac-bootstrap commit -m "pre-migration snapshot" && git -C ~/Developer/github/acastro2/mac-bootstrap push
```

### 1.3 Export macOS Keychain secrets

Write down or copy these values (they cannot be transferred via tarball):

```bash
security find-generic-password -s ADO_PAT -w
security find-generic-password -s GRAFANA_SERVICE_ACCOUNT_TOKEN -w
```

### 1.4 AirDrop to target

Send these files via AirDrop to the target MacBook:
- `~/Desktop/agent-sessions-<timestamp>.tar.gz`

That's it. Everything else comes from git repos or 1Password.

---

## Phase 2: Bootstrap the Target Machine

Run these on the target MacBook.

### 2.1 Initial bootstrap

```bash
# If git is available (Xcode CLT already installed):
git clone https://github.com/acastro2/mac-bootstrap.git ~/Developer/github/acastro2/mac-bootstrap
cd ~/Developer/github/acastro2/mac-bootstrap

# Create config.env with your values:
cat > config.env << 'EOF'
OP_VAULT="Private"
GIT_NAME="Alexandre Castro"
GIT_EMAIL="alexandre.castro@outlook.com"
REPO_URL="https://github.com/acastro2/mac-bootstrap.git"
REPO_DIR="${HOME}/Developer/github/acastro2/mac-bootstrap"
OPENCODE_CONFIG_REPO="acastro2/opencode_config"
OPENCODE_SKILLS_REPO="https://github.com/acastro2/alex-skills.git"
CLAUDE_CONFIG_REPO="acastro2/claude-config"
EOF

# Run bootstrap (installs everything, sets up auth)
./bootstrap.sh
```

The bootstrap will:
1. Install Homebrew and all packages (Brewfile)
2. Set fish as default shell with Tide prompt
3. Install opencode, Claude Code CLI, herdr, mise toolchains
4. Clone opencode config, Claude Code config, and skills repos
5. Pull API keys from 1Password into fish environment
6. Run doctor checks to verify everything

### 2.2 Import session data

After AirDrop delivers the tarball (check `~/Downloads` or wherever macOS puts it):

```bash
cd ~/Developer/github/acastro2/mac-bootstrap
./bootstrap.sh --import-sessions=~/Downloads/agent-sessions-*.tar.gz
```

This automatically removes any existing session data on the target before extracting, so you get a clean replacement rather than a merge of old and new. Specifically it wipes:
- opencode DB, Claude projects/history, `.claude.json`
- Cortex conversations, settings, skills, plugins, history, thread goals
- Snowflake connection config
- Per-project `.cortex/` directories (only if the tarball contains Developer paths)

### 2.3 Restore Keychain secrets

```bash
security add-generic-password -s ADO_PAT -a "$(whoami)" -w '<paste-ado-pat-here>'
security add-generic-password -s GRAFANA_SERVICE_ACCOUNT_TOKEN -a "$(whoami)" -w '<paste-token-here>'
```

### 2.4 GitHub multi-account auth

```bash
# Personal account
gh auth login --web

# Work account (if using separate auth)
gh auth login --web --hostname github.com

# Fix credential helper for multi-account pushes
gh auth setup-git
```

### 2.5 Verify

```bash
# Run doctor to check all tools are present
./bootstrap.sh --only=doctor

# Quick smoke tests
opencode --version
claude --version
fish -c "echo \$ANTHROPIC_API_KEY" | head -c 10  # should show sk-ant-...
```

---

## Phase 3: Optional Cleanup of Source Machine

Only after confirming the target is fully working:

```bash
# On the SOURCE machine, if you want to wipe managed tooling:
cd ~/Developer/github/acastro2/mac-bootstrap
./bootstrap.sh --clean
```

This removes all Homebrew packages, fish plugins, mise toolchains, opencode/claude binaries, and generated configs. It does NOT remove:
- `~/Developer` (your code)
- `~/.claude/projects` (conversations)
- `~/.local/share/opencode` (session DB)
- `~/.config/opencode` or `~/.claude` (config repos)
- Homebrew itself

---

## What Lives Where (Reference)

| Data | Path | Backup method |
|------|------|---------------|
| opencode sessions | `~/.local/share/opencode/opencode.db` | --export-sessions |
| opencode config | `~/.config/opencode/` | git repo (acastro2/opencode_config) |
| opencode skills | `~/.agents/skills/` | git repo (acastro2/alex-skills) |
| Claude Code config | `~/.claude/` (CLAUDE.md, settings, hooks, pandoc) | git repo (acastro2/claude-config) |
| Claude Code conversations | `~/.claude/projects/` | --export-sessions |
| Claude Code session index | `~/.claude/history.jsonl` | --export-sessions |
| Claude Code account state | `~/.claude.json` | --export-sessions |
| Claude Desktop config | `~/Library/Application Support/Claude/` | --export-sessions |
| Per-project Claude config | `<project>/.claude/` | lives in project repo |
| Cortex Code CLI | `~/.local/bin/cortex` | bootstrap (cortex section) |
| Cortex Code sessions | `~/.snowflake/cortex/conversations/` | --export-sessions |
| Cortex Code config | `~/.snowflake/cortex/{settings,cortex,permissions,skills}.json` | --export-sessions |
| Cortex Code plans | `~/Developer/**/.cortex/` | --export-sessions |
| Cortex skills/plugins | `~/.snowflake/cortex/{skills,plugins,commands}/` | --export-sessions |
| Snowflake connections | `~/.snowflake/connections.toml` | --export-sessions |
| Cortex fish completions | `~/.config/fish/completions/cortex.fish` | --export-sessions |
| Homebrew packages | Brewfile | git repo (mac-bootstrap) |
| Fish config + aliases | `~/.config/fish/` | chezmoi (mac-bootstrap/home) |
| Ghostty config | `~/.config/ghostty/` | chezmoi (mac-bootstrap/home) |
| API keys | 1Password + fish conf.d | 1Password vault |
| Keychain secrets | macOS Keychain | manual (security add-generic-password) |
| SSH keys | 1Password SSH agent | 1Password vault |
| Git credential helper | gh auth setup-git | bootstrap Phase 2 |

---

## Troubleshooting

**`gh repo clone` fails during bootstrap**: Run `gh auth login --web` manually, then re-run `./bootstrap.sh --only=auth`.

**Claude Code not found after bootstrap**: The npm global install requires Node. Run `mise install` first, then `./bootstrap.sh --only=claude`.

**Fish not set as default shell**: Run `sudo dscl . -create /Users/$USER UserShell /opt/homebrew/bin/fish`.

**1Password CLI prompts for setup**: Open 1Password desktop app first, enable Developer settings (Integrate with CLI, SSH agent, biometric unlock), then re-run auth section.

**Import fails with "file not found"**: Check the exact filename. macOS may have added a suffix or placed it in a different folder after AirDrop. Try `ls ~/Downloads/agent-sessions*`.

**Cortex Code CLI not found**: Re-run `./bootstrap.sh --only=cortex`. The installer puts it at `~/.local/bin/cortex`, which needs to be on PATH (fish config handles this via mise activation).
