# mac-bootstrap

One command. Zero to a fully armed and operational macOS workstation. Shell, toolchains, dotfiles, auth, browser automation, LLM coding agents — all of it.

If you're the kind of engineer who treats their machine like a cattle, not a pet, this is your herd script.

!!! tip
    **On WSL2 / Ubuntu?** The script detects non-macOS and skips the Apple-specific stuff automatically — no Xcode CLT, no `defaults`, no casks. Everything else (Homebrew, fish, mise, tools, dotfiles) runs the same. See `Brewfile.linux` for the Linux package list.

---

## Before you run this

- **Apple ID** — signed into the App Store (for `mas` to pull apps)
- **A functioning brain** — the script's interactive. It'll ask you things. It won't hold your hand for `sudo`.

**1Password is optional.** If you set your vault name in `config.env`, the bootstrap pulls API keys into a fish env file. If you don't, everything else still works — you'll just need to configure API keys yourself.

---

## Make It Yours

Fork the repo, edit `config.env` with your values, then run:

```bash
git clone https://github.com/YOU/mac-bootstrap.git ~/Developer/github/YOU/mac-bootstrap
cd ~/Developer/github/YOU/mac-bootstrap
# edit config.env with your values
./bootstrap.sh
```

| Variable               | What it does                                                                   |
| ---------------------- | ------------------------------------------------------------------------------ |
| `OP_VAULT`             | 1Password vault name (leave empty to skip API key setup)                       |
| `GIT_NAME`             | Your name for `git config --global user.name`                                  |
| `GIT_EMAIL`            | Your email for `git config --global user.email`                                |
| `REPO_URL`             | URL of your fork                                                               |
| `REPO_DIR`             | Where to clone your fork                                                       |
| `OPENCODE_CONFIG_REPO` | Private opencode config repo, e.g. `you/opencode_config` (leave empty to skip) |
| `OPENCODE_SKILLS_REPO` | Public agent skills repo (leave empty to skip)                                 |

Then run:

```bash
./bootstrap.sh
```

---

## Run it

The quick and dirty way (runs with defaults, no 1Password):

```bash
curl -fsSL https://raw.githubusercontent.com/acastro2/mac-bootstrap/main/bootstrap.sh | bash
```

That's it. Copy. Paste. Hit enter. Walk away for 10 minutes.

If you'd rather inspect before you yeet:

```bash
git clone https://github.com/acastro2/mac-bootstrap.git ~/Developer/github/acastro2/mac-bootstrap
cd ~/Developer/github/acastro2/mac-bootstrap
./bootstrap.sh
```

Re-running is safe — everything's idempotent. Use `--only` or `--skip` to be surgical:

```bash
./bootstrap.sh --only=packages,fish        # just packages + shell
./bootstrap.sh --skip=macos-defaults,mise,auth  # skip opinionated macOS defaults, toolchains, and auth
```

Gatable sections: `xcode`, `brew`, `repo`, `workspace`, `macos-defaults`, `packages`, `app-clis`, `fish`, `fisher`, `git`, `ssh`, `herdr`, `opencode`, `cortex`, `tgrep`, `mise`, `browser-automation`, `dotfiles`, `secrets`, `auth`, `doctor`.

---

## Step into the Madness

Here's the deal: this isn't a generic dotfiles repo. It's the exact setup of a platform engineer who spends their days knee-deep in Terraform, Kubernetes, AWS, and LLM-powered coding agents. Every choice here has a body count behind it.

### The OS

**macOS.** I've run Linux on the desktop. I've tried WSL2. For platform work that involves talking to every cloud, running containers locally, and needing a terminal that doesn't fight you — macOS is the least-worst option. The `macos-defaults` section sets key repeat to fast, hides the Dock, disables `.DS_Store` on network volumes, and goes dark mode with an orange accent. Fight me.

### The shell

**fish** via Homebrew. Not zsh with oh-my-zsh. Not bash with a thousand plugins. Fish because tab completions work out of the box, the syntax doesn't make me want to throw my laptop, and I don't have to maintain a 300-line `.zshrc` that breaks every six months. Tide for the prompt (minimal, fast, shows what branch you're on). Fisher for plugins — currently Tide, Sponge (clean history), and `jhillyerd/plugin-git` for oh-my-zsh-style git aliases.

You'll get `gs`, `gss`, `gst`, `ga`, `gc`, `gp`, `gco`, `gb`, and about 30 other aliases that your muscle memory already knows.

### The terminal

**Ghostty.** Native, GPU-accelerated, zero config to look good. It replaced iTerm2, Kitty, and WezTerm for me. The dotfiles include a Ghostty config that just works.

### The editor(s)

**VS Code Insiders** and **Zed**. I live in VS Code for heavy platform work (Terraform, Go, Kubernetes manifests). Zed for quick edits, markdown, and when I want something that opens before I finish blinking. Both get CLI launchers — `code` and `zed` from anywhere.

### The package manager

**Homebrew** with a `Brewfile`. 44 packages: git, fish, mise, chezmoi, uv, fzf, ripgrep, bat, eza, neovim, jq, yq, kubectl, helm, k9s, awscli, colima, postgresql, redis, 1password, ghostty, VS Code, Zed, JetBrains Mono Nerd Font, Geist Mono, and more. Declarative. Boring. Works.

### The toolchain manager

**mise.** Not asdf. Not nvm + pyenv + tfenv. mise is faster, supports piped installs (`npm:@playwright/test`), and doesn't require shims. It pins Go (latest), Node (LTS), pnpm 10, Python 3.12, .NET 9, OpenTofu, and the Playwright CLI — globally. Per-project overrides go in `.mise.toml` or `.tool-versions`.

### The secret sauce (optional)

**1Password CLI → fish env file.** If you set `OP_VAULT` in `config.env`, every API key gets pulled from your 1Password vault into `~/.config/fish/.api-keys.env` (chmod 600). Fish's `conf.d/secrets.fish` sources it at shell start. Keys end up as environment variables. This is the "naive but works everywhere" approach — your company blocks Keychain access? Fine. No problem.

Skip it if you want — you'll just set up API keys yourself.

Keys managed this way: opencode, anthropic, openai, context7, devto, oreilly, google.

### The dotfiles

**chezmoi** with the source directory inside this repo (`home/`). Your fish config, Ghostty config, git aliases, and editor settings all live here. `chezmoi diff` to preview, `chezmoi apply` to deploy. Templates, if you need them, use chezmoi's built-in templating.

### The LLM coding agent

**OpenCode.** Installed via the official install script. An optional private config repo (`OPENCODE_CONFIG_REPO`) gets cloned into `~/.config/opencode` with your provider and model config. A public skills repo (`OPENCODE_SKILLS_REPO`) lands in `~/.agents/skills` — these are the [alex-skills](https://github.com/acastro2/alex-skills) that teach OpenCode how to write in my voice, review PRs, create diagrams, write ADRs, and handle browser automation.

### The browser automation stack

Both Node and Python Playwright, plus `browser-use` (an LLM-driven browser agent). This is how OpenCode's `webapp-testing` and `playwright-cli` skills drive a real Chromium to test web apps, take screenshots, and fill forms. The bootstrap also opens System Settings so you can grant Accessibility and Screen Recording permissions — no, it can't grant them for you. macOS is a prison.

### The infra tooling

**colima** for containers (Docker Desktop is a resource hog and the licensing got weird). **kubectl**, **k9s**, and **helm** for cluster work. **awscli** for, well, AWS. **terraform-linters/tap** and **tflint** because I don't merge Terraform without linting. **snowflake-cli** and **pgcli** for data platform work. **doggo** because `dig` output makes me sad. **herdr** for macOS fleet management — version-pinning, drift detection, and one-command setups across machines.

### The profile

Who runs this? Someone who:

- Spends more time in a terminal than Finder
- Thinks workstations should be disposable and reproducible
- Doesn't want to remember 12 `brew install` commands on a fresh machine
- Ships infrastructure for a living (platform, SRE, DevOps, cloud)
- Uses AI coding agents and wants them wired into their tools, not bolted on
- Has strong opinions about prompt rendering speed and won't tolerate lag
- Doesn't want to touch a Keychain API ever again

If that's you — welcome. Run the command. Break things. Send PRs.

---

## What happens when you run it

The script runs in two phases:

**Phase 1 — silent install.** Xcode CLT, Homebrew, all packages, fish as default shell, Fisher plugins, git config, SSH via 1Password agent, OpenCode, mise toolchains, Playwright + browser-use, dotfiles via chezmoi, and API key functions written to fish `conf.d/` (if `OP_VAULT` is set).

**Phase 2 — interactive auth.** If `OP_VAULT` is set: 1Password sign-in, API keys written to `~/.config/fish/.api-keys.env`. Always: GitHub CLI SSO login, opencode config clone (if repo is set), agent skills clone (if repo is set), and a doctor check that verifies critical binaries are alive.

If anything fails, it tells you what and keeps going. Re-run anytime.

---

## After bootstrap

```bash
aws sso login --profile <your-profile>
mise install      # if any tools need (re)installing
# Sign in to desktop apps (Slack, VS Code, etc.)
```

Open a new terminal. You're in fish. You're home.
