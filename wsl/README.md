# WSL2 setup

The Windows/WSL2 counterpart of `bootstrap.sh`: the same shell, toolchains, dotfiles and agents on Ubuntu 24.04 under WSL2. It's the Linux-native way, so no Linuxbrew and no Colima.

```bash
git clone https://github.com/acastro2/mac-bootstrap.git ~/Developer/github/mac-bootstrap
cd ~/Developer/github/mac-bootstrap && git switch windows
bash wsl/setup.sh                 # no sudo needed; safe to re-run
sudo bash wsl/setup-root.sh       # optional: native apt extras
```

Then run `wsl --shutdown` from PowerShell and open a new Windows Terminal tab.

Run single steps with `bash wsl/setup.sh <step> [step…]`. The steps, in order:

| Step       | What it does |
| ---------- | ------------ |
| `configs`  | Deploys `wsl/files/*` (an existing file that differs is backed up as `*.bak-<date>`), git config from `config.env`, chezmoi pointed at this checkout, `.wslconfig`, Windows Terminal |
| `zsh`      | User-space zsh ([zsh-bin](https://github.com/romkatv/zsh-bin)) when apt's isn't installed |
| `libs`     | Without root: unpacks Ubuntu's own `.deb`s for Chromium (`libnss3`, `libasound2`), Node (`libatomic1`), `psql` and `redis-cli` into `~/.local` |
| `mise`     | mise, then `gh` + `gh auth login` (SSH key generated and uploaded), then every tool in `files/mise.toml` |
| `agents`   | Claude Code, OpenCode, Cortex, plus the opencode/Pi/skills config repos (cloned over HTTPS as `acastro2`) |
| `browser`  | Python Playwright + browser-use via `uv tool`, Chromium, and a headless launch check |
| `dotfiles` | `chezmoi apply` from `home/`, plus the first zsh start (installs Zim modules) |
| `windows`  | winget: JetBrainsMono Nerd Font, VS Code Insiders (user scope) |
| `doctor`   | Checks that every tool resolves |

## How it differs from the Mac

| Mac | WSL |
| --- | --- |
| Homebrew + Brewfile | apt for the OS; user-space CLIs from `files/mise.toml` (aqua/GitHub/pipx/npm backends) |
| Colima | Native `docker-ce` under systemd (`docker` group) |
| 1Password app SSH agent | systemd user `ssh-agent` (`files/ssh-agent.service`) with a key uploaded by `gh auth login` |
| 1Password → `.api-keys.zsh` in bootstrap | Linux `op` CLI: `op account add`, then `eval "$(op signin)" && op-sync-api-keys` |
| Ghostty | Windows Terminal (`windows-terminal.py`): WSL as the default profile, same theme and font, browser-style tab keys |
| `chsh` | Same with sudo; without it, `~/.profile` hands interactive shells to zsh (`files/profile-handoff.sh`) |
| macOS keychain/open/pbcopy | `local.zsh`: `open` → `wsl-open`, `pbcopy` → `clip.exe`, `$BROWSER` set so `gh`/`az`/`aws sso` logins open the Windows browser |

The shared `home/` dotfiles stay unchanged. Everything WSL-specific lives in `files/local.zsh`, deployed to `~/.config/zsh/local.zsh`, which `.zshrc` sources last.

## Windows Terminal keys

| Keys | Action |
| ---- | ------ |
| Ctrl+T / Ctrl+W | New tab / close pane (closes the tab when it has one pane) |
| Ctrl+1…8, Ctrl+9 | Go to tab N, last tab |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |

These take keys away from the shell, so:
- **fzf file picker:** moves from Ctrl+T to **Alt+T**.
- **Delete previous word:** use **Alt+Backspace** instead of Ctrl+W.

## Gotchas this setup already handles

- **Slow zsh startup:** WSL appends the entire Windows `PATH`, and every lookup on `/mnt/c` is a slow round-trip to Windows.
  - `setup-root.sh` sets `appendWindowsPath = false`.
  - `local.zsh` re-adds just System32, PowerShell, WindowsApps and VS Code Insiders, without checking they exist (checking is the slow part).
  - Result: startup goes from ~2.5 s to ~0.2 s.
- **Duplicate completion setup:** Ubuntu's `/etc/zsh/zshrc` runs `compinit` before Zim does. `files/zshenv` sets `skip_global_compinit=1`.
- **Node won't start:** its prebuilt binary needs `libatomic.so.1`. The `libs` step runs before `mise` for this reason.
- **gh credential helper breaks after upgrades:** `gh auth setup-git` pins gh's versioned install dir, so the `mise` step points the helper at the stable mise shim instead.
- **Private repos not found:** if the active gh/SSH identity is a work account, it can't see `acastro2`'s private repos. The `agents` step clones them over HTTPS with the `acastro2` token.
