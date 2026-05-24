# mac-bootstrap

One-shot macOS workstation bootstrap. Takes a fresh Mac from zero to fully set up in one command.

## What it does

`bootstrap.sh` runs everything in two phases:

**Phase 1 — non-interactive install:**
- Xcode Command Line Tools
- Homebrew
- All packages via `Brewfile` (fish, ghostty, 1Password, opencode, terraform, kubectl, zed, cursor, ...)
- Sets fish as default shell
- Configures git globals, SSH via 1Password agent
- Installs opencode (optionally clones a private config repo + a public skills repo if their URLs are set)
- Sets up mise toolchains (Go, Node, Python, Terraform, OpenTofu)
- Installs Playwright (Node + Python), Playwright MCP server, browser-use, and warms browser cache
- Applies dotfiles via chezmoi (fish config + Tide prompt, ghostty terminal)

**Phase 2 — interactive auth (one prompt at a time):**
- 1Password CLI setup + sign-in
- GitHub CLI SSO login (`gh auth login --web`)

## Run on a new machine

```bash
curl -fsSL https://raw.githubusercontent.com/acastro2/mac-bootstrap/main/bootstrap.sh | bash
```

Or inspect first:

```bash
git clone https://github.com/acastro2/mac-bootstrap.git ~/mac-bootstrap
cd ~/mac-bootstrap
./bootstrap.sh
```

## Configuration

Edit these vars at the top of `bootstrap.sh`:

| Variable                 | What                                                                       |
| ------------------------ | -------------------------------------------------------------------------- |
| `OP_VAULT`               | 1Password vault name for secrets                                           |
| `GIT_NAME` / `GIT_EMAIL` | Git identity                                                               |
| `OPENCODE_CONFIG_REPO`   | Optional — private git repo with `config.json` (skipped if empty)          |
| `OPENCODE_SKILLS_REPO`   | Optional — public git repo cloned to `~/.agents/skills` (skipped if empty) |

## 1Password setup (one-time)

Before the bootstrap can pull secrets, set up the 1Password desktop app:

1. **Settings → Developer**, enable:
   - "Integrate with 1Password CLI"
   - "Use the SSH agent"
   - "Biometric unlock for 1Password CLI"
2. `eval "$(op signin)"`

## 1Password vault items

| Item path                        | Field      | What                        |
| -------------------------------- | ---------- | --------------------------- |
| `op://Private/opencode-api-key`  | `password` | Opencode API key            |
| `op://Private/anthropic-api-key` | `password` | Anthropic API key           |
| `op://Private/openai-api-key`    | `password` | OpenAI API key              |
| `op://Private/context7-api-key`  | `password` | Context7 API key            |
| `op://Private/devto-api-key`     | `password` | dev.to API key              |
| `op://Private/oreilly-api-token` | `password` | O'Reilly API token          |
| `op://Private/google-api-key`    | `password` | Google API key (for Stitch) |

## Updating dotfiles

The bootstrap writes `~/.config/chezmoi/chezmoi.toml` pointing chezmoi's source at `~/mac-bootstrap/home`, so bare commands work:

```bash
chezmoi diff             # preview changes
chezmoi apply            # apply to $HOME
cd ~/mac-bootstrap && git add home/ && git commit -m "update dotfiles" && git push
```

## Selective runs

The bootstrap is idempotent — re-run `./bootstrap.sh` anytime. Specific sections are skipped if already configured.

## Browser automation

Both Node and Python Playwright are installed. They share `~/Library/Caches/ms-playwright/`, so warming once via either CLI covers both. Tools available after bootstrap:

| Tool                  | Source                        | Use case                                      |
| --------------------- | ----------------------------- | --------------------------------------------- |
| `playwright` (Node)   | mise → `npm:@playwright/test` | codegen, trace viewer, ad-hoc scripts         |
| `playwright` (Python) | `uv tool install playwright`  | the `playwright-cli`, `webapp-testing` skills |
| `@playwright/mcp`     | mise → `npm:@playwright/mcp`  | agentic browser control via MCP               |
| `browser-use`         | `uv tool install browser-use` | LLM-driven browser agent (Python)             |

### macOS permissions required (one-time)

For headed-mode tests and video recording to work, grant the following in **System Settings → Privacy & Security**:

| Permission       | Apps to grant                      |
| ---------------- | ---------------------------------- |
| Accessibility    | Ghostty, Chromium, Firefox, WebKit |
| Screen Recording | Ghostty, Chromium                  |

Without these: key presses silently no-op, `--video=on` records black frames. macOS sandbox won't let bootstrap grant these — first run is interactive.

## Next steps after bootstrap

```bash
aws sso login --profile <your-profile>
mise install   # if any tools need (re)installing
# Sign in to desktop apps (Slack, VS Code, etc.)
```
