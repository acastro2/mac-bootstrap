# den: build contract

`den` sets up a Mac (and its Lima agent VM) in one shot and keeps it healthy.
This file is the contract every module is built against. Change it only on
purpose, in one commit with the code that needs the change.

## Rules every module follows

1. **Bash 3.2.** macOS `/bin/bash` is 3.2: no `mapfile`, no `${x,,}`, no
   associative arrays, no `case` inside `$( ... <<EOF )`. `shellcheck` clean.
2. **Ask first, then run unattended.** Every human input (sudo, 1Password,
   `gh` logins, wizard answers) happens in preflight, before the first phase.
   No phase reads `/dev/tty`.
3. **Do what access allows.** A phase whose needs are not met is **skipped**
   with a reason and a fix command, never fails the run. A phase that errors is
   **failed** with a reason and a fix, and the run continues.
4. **Idempotent and quiet when healthy.** A second run changes nothing and says
   so in one line per phase.
5. **No secret in logs, argv, or the repo.** Secret values move through files
   (mode 600, `umask 077`) or stdin, never command-line arguments.
   **Known exceptions:** two CLIs take the value no other way, so the secret
   rides argv and is exposed in the local process list (`ps`) for about a
   second: `opencode service set password`
   (`lib/phases/50-opencode-web.sh`) and the gated MCP URL passed to
   `claude mcp add` (`lib/phases/52-rex.sh`). Nothing else may take this path.
6. **Self-contained phases.** Each phase runs in a subshell. It cannot rely on a
   variable another phase set; it derives what it needs (helpers in core).

## Layout

```text
bootstrap.sh          stage 0: CLT, Homebrew, git, clone repo, exec bin/den up "$@".
                      Keeps every current flag (--only, --skip, --clean, --dump-*,
                      --export-*, --import-sessions, --strict) by passing them through.
bin/den               the CLI (see "CLI").
lib/ui.sh             output and prompts (see "UI").
lib/core.sh           config, phase registry, runner, needs, state (see "Core").
lib/secrets.sh        den.json load/render/purge (see "Secrets").
lib/registry.sh       managed install registry (moved as is from bootstrap.sh).
lib/phases/<NN>-<name>.sh   one file per phase; NN sets run order.
vm/                   lima-dev.yaml, vm-up.sh, guest-heal.sh, guest-provision.sh, README.md (VM lane).
config.env            public config (committed). Toggles live here.
```

## UI (lib/ui.sh)

Mode is chosen once: `gum` when `gum` is on PATH, stdout is a TTY and
`NO_COLOR` is unset; `ansi` when stdout is a TTY; `plain` otherwise (CI,
launchd, pipes). `DEN_UI=gum|ansi|plain` overrides. Every function works in
every mode; `plain` output has no escape codes.

| Function | Use |
| --- | --- |
| `ui_banner` | The den banner (small, fun, one per run). Skipped in `plain`. |
| `ui_section "Title"` | Start of a phase. |
| `ui_step "text"` | Something is happening. |
| `ui_ok "text"` / `ui_warn "text"` / `ui_err "text"` / `ui_skip "text"` / `ui_info "text"` | Outcome lines: ✓ ! ✗ ↷ ·. |
| `ui_spin "title" cmd args...` | Run a command with a spinner; returns its exit code; output shown only on failure. |
| `ui_confirm "question"` | Yes/no; returns 0/1. Non-TTY: returns 1 (never blocks). |
| `ui_input "prompt" "default"` | One line of text to stdout. Non-TTY: prints the default. |
| `ui_choose "prompt" opt...` | One option to stdout. Non-TTY: prints the first. |
| `ui_summary` | Reads the current run's results (core) and prints the table: phase, status icon, seconds, reason, fix. |

`bootstrap.sh` stage 0 must work before the repo exists, so it carries a
10-line plain fallback of `ui_step/ui_ok/ui_warn/ui_err` and does not source
`lib/`.

## Core (lib/core.sh)

### Config

`den_config_load`: sources `config.env` from the repo root (never from `$PWD`),
then `~/.config/den/local.env` if present (machine overrides, not committed).
Unknown keys are allowed. The repo root is `DEN_ROOT` (resolved from
`bin/den`'s real path).

Toggles (all default as shown in `config.env`):

| Variable | Phases it gates |
| --- | --- |
| `DEN_MACOS_DEFAULTS=1` | macos-defaults |
| `DEN_TOUCHID_SUDO=1` | sudo-touchid |
| `DEN_AGENTS="opencode claude cortex"` | which agent CLIs install |
| `DEN_REX=1` | rex, rex-restore |
| `DEN_OPENCODE_WEB=1` | opencode-web |
| `DEN_VM=1` | vm (and the vm-up login agent) |
| `DEN_BROWSE_TUNNEL=1` | browse relay + tunnel in vm-up |

### Phase registry

A phase file registers itself and defines its body:

```bash
den_phase rex-restore \
  --title "Rex Agent Restore" \
  --about "Resume Claude Code and Cursor chats after a Rex restart" \
  --os macos|linux|any \
  --toggle DEN_REX \
  --needs "brew rex-app"
phase_rex_restore() { ...; }
```

`den_phase` appends to the ordered registry. Names are lowercase with `-`;
the function is `phase_` plus the name with `-` → `_`.

### Needs

Vocabulary: `sudo net brew op gh secrets tty vm rex-app disk:<GiB> macos linux`.
`den_need <need>` returns 0 when met, else 1 and sets `DEN_NEED_REASON` and
`DEN_NEED_FIX` (exact command the user runs). Preflight computes them once;
`den_need` reads the cache.

### Preflight (`den_preflight`)

Runs once before phases, in this order, each step skippable when not needed by
any selected phase:

1. Probe: OS, arch, free disk, network (`curl -fsS -m 5 https://github.com`),
   brew, TTY.
2. sudo: if any selected phase needs `sudo` and a TTY exists, `sudo -v` once
   and keep it alive (background `sudo -n -v` every 50 s, killed on exit).
3. Secrets: `den_secrets_load` (see Secrets). No `op signin` offer: a recorded
   file or `~/den.json` is used without asking 1Password, and otherwise
   `op document get` may show the 1Password approval prompt on each run.
4. gh: if any selected phase needs `gh` and a TTY exists and `gh auth status`
   fails, run `gh auth login --web --git-protocol https` once.
5. Print a short preflight table (what is available, what will be skipped).

### Runner (`den_run`)

For each registered phase in order:

1. Not selected (`--only`/`--skip`, toggle off, wrong OS): not shown.
2. Unknown names in `--only`/`--skip` → `die` with the valid list (before
   preflight).
3. Needs unmet → status `skipped` with reason + fix.
4. `--dry-run` → status `dry-run`, prints title + about + needs; runs nothing.
5. Else run `( set -euo pipefail; phase_<name> )`, timed. Exit 0 → `done`.
   A phase may call `den_skip "reason" "fix"` (exit 0, status `skipped`) or
   `den_fail "reason" "fix"` (status `failed`). Any other nonzero exit →
   `failed` with reason `exited <code>` and fix `den up --only=<name>`.

### State

`~/.local/state/den/last-run.json` (a `--dry-run` writes `last-dry-run.json`
instead, so it never hides the real run; a partial `--only` run, which `den fix`
uses, keeps the rows of phases it did not run; written atomically, mode 600, valid JSON
built with `printf` + escaping — jq may not exist yet):

```json
{"version":1,"started":"<iso>","finished":"<iso>","host":"<hostname>","os":"macos",
 "args":"--only=...","results":[
  {"phase":"vm","status":"done|skipped|failed|dry-run","seconds":12,
   "reason":"","fix":""}]}
```

`den fix` reruns phases whose last status was `skipped` or `failed`.

## Secrets (lib/secrets.sh)

Source of truth: the 1Password **Document** titled `den` (file `den.json`) in
`$OP_VAULT`. A file at `~/den.json`, or one recorded with
`den secrets import <path>`, works without asking 1Password:

```json
{"version":1,
 "env":{"OPENCODE_API_KEY":"...","...":"..."},
 "opencode_web":{"password":"..."},
 "rex":{"appcast":"...","mcp":"..."}}
```

`den_secrets_load`, first match wins:

1. A recorded import path (from `den secrets import <path>`), else `~/den.json`.
   When a file exists it is used as it is and 1Password is not asked. An
   invalid file is rejected and kept for the user to fix.
2. Only when there is no file: `op document get den --vault "$OP_VAULT"` (no
   `op whoami` gate, because under the 1Password app integration it says "not
   signed in" while reads work). The 1Password app may show an approval prompt
   on each run; a prompt nobody answers is killed after `DEN_OP_TIMEOUT`
   seconds (default 60).
3. Neither: phases that need `secrets` are skipped with fix
   "drop den.json at ~/den.json, or approve the 1Password prompt".

No `op signin` is offered at any point.

The JSON is validated (`version` 1, `env` an object of strings). It is held in
a mode-600 file under `$DEN_RUNTIME` (`mktemp -d`, removed on exit), never in
argv. After derived files are written, a source file from step 1 is deleted
and the run says so.

`den_secret <jq path>` prints one value (e.g. `.rex.appcast`). Empty string
when absent.

`den_render_env <out>` writes `export KEY='value'` lines with single-quote
escaping (`'` → `'\''`), mode 600, then `zsh -n`. It never replaces an
existing file with an empty set: if the bundle has no `env`, it skips with a
reason. The old file is kept as `<out>.bak` before replace.

## CLI (bin/den)

```text
den                     dashboard: VM, relay, tunnel now; last run; next steps; fun line
den up [--only a,b] [--skip a,b] [--dry-run]   run phases (preflight first)
den fix                 rerun what was skipped or failed last time
den doctor [--strict]   read-only health, incl. VM, relay, tunnel, vm-up agent
den phases              list phases: name, toggle, needs, about
den setup               wizard: writes config.env values, then offers den up
den secrets import <path> | status
den vm up|down|shell|status|logs|rebuild
den clean [--dry-run] [--host-drift] [--yes]   safe: only registry/Brewfile items, snapshot, typed confirm (--host-drift never takes --yes)
den sessions export|import <file>   safe import: snapshot, temp extract, verify, swap
den update              git pull --ff-only, then den up
den help [cmd] / den --version
```

`den vm down` stops the vm-up login agent and Lima autostart **before**
stopping the VM, so nothing restarts it; `den vm up` turns both back on.

## Host vs VM

The VM is the dev box; the Mac is the window, the keys, the browser and the VM
host. Coding happens in the VM.

| Installs on | What |
| --- | --- |
| **Both** | Claude Code, OpenCode, their config repos (`~/.claude`, `~/.config/opencode`), skills (`~/.agents/skills`), git, gh, chezmoi, zsh + Zim, starship, carapace, fzf, eza, bat, ripgrep, fd, jq, yq, neovim, gum, rex-agent-restore, uv, ffmpeg (Mac: for scribe only) |
| **Mac only** | 1Password app + `op`, Rex.app, Lima, VS Code (+ Remote-SSH), browse relay, fonts, shellcheck, bats-core, desktop apps (Jumpcut, Beyond Compare, KeepingYouAwake) |
| **VM only** | mise and every toolchain it pins (go, node, pnpm, python, dotnet, opentofu, Playwright, ctx7), Docker Engine, kubectl, k9s, helm, awscli, snowflake-cli, pgcli, crane, tflint, pre-commit, gitleaks, repomix, doggo, PostgreSQL (latest major), redis, asdf, opentunnel, cortex, tgrep, Playwright + browser-use (uv), the Rex server |
| **Nowhere** | Zed, Ghostty, Claude desktop, Cursor CLI, pi, herdr, reverse-engineer-anything (REA) and Hopper, Copilot CLI, mas, Colima/docker/docker-compose on the Mac |

Additions decided 2026-11-18:

- **Mac Brewfile adds:** `gum`, `mcat`, `uv`, `ffmpeg`, `shellcheck`,
  `bats-core`, `peekaboo` (tap `openclaw/tap`), casks `obsidian`, `rectangle`,
  and `hex` (tap `anomalyco/tap`; scribe's speech-to-text).
- **Brewfile.linux adds:** `gum`, `mcat`, `uv`, `ffmpeg`, `asdf`, and
  `opentunnel` (tap `anomalyco/tap`). Nothing else from the undeclared list.
- **Versions in the VM:** the LTS release wherever one exists (Node `lts`,
  .NET LTS, Java LTS if Java is ever added, Ubuntu 24.04 LTS image); latest
  stable for everything without LTS (Go, Python, OpenTofu, pnpm, Playwright,
  ctx7). **PostgreSQL: the latest major** (unversioned `postgresql` formula or
  the newest `postgresql@NN`), not `@16`. Verify each mise selector (`lts`,
  `latest`) against current mise docs before writing it.
- **`cat` alias:** `alias cat=mcat` only when `mcat` is on PATH.
- **Host drift** (reported by `den doctor`; `den clean --host-drift` removes
  the Homebrew leaves after a typed confirmation of the exact list, and mise
  tools are reported only): every Homebrew leaf and mise tool on the Mac that the Mac Brewfile does not
  declare, e.g. `asdf nvm pyenv go dog gcx pi-coding-agent qemu mosh aria2
  coreutils bash p7zip unar scrcpy ideviceinstaller xcodegen xdelta rsync
  opentunnel` and everything in the VM-only row. Undeclared **casks** (apps) are
  reported but never removed by den.

`Brewfile` is the Mac list, `Brewfile.linux` the VM list. The mise global
config is written only in the VM. `den doctor` on the Mac reports host drift:
Homebrew leaves and mise installs that no Brewfile declares, with the command
to remove each. Nothing is uninstalled without `den clean --host-drift` and a
typed confirmation.

## VM guest

The VM is the dev box: it gets every key in `den.json`, its own `gh` login
(no SSH agent forwarding from the Mac), and a container engine.

- **Docker Engine** from Docker's apt repository (`docker-ce`, `docker-ce-cli`,
  `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`), rootful,
  the user in the `docker` group. Root in the guest is fine: the guest is the
  sandbox. The group is added **before** the Rex server and the systemd user
  manager start, or tabs lack it until the VM restarts.
- `Brewfile.linux` carries no `docker`, `docker-compose`, `colima` or `lima`:
  Homebrew's `docker` shadows `/usr/bin/docker`.
- `den doctor` checks, in the guest: `docker info` works as the user, and
  `docker compose version`.
- **Obsidian vault**: Obsidian Headless (`npm i -g obsidian-headless`, `ob`,
  Node 22+ from the VM's mise) syncs the remote vault into `~/vault` through
  Obsidian Sync. No mount, no Mac bridge, no OneDrive in the VM. Setup:
  `ob login` (interactive, in preflight), `ob sync-setup --vault <name>
  --path ~/vault --device-name <instance>`, then `ob sync-config --configs ""
  --mode bidirectional --conflict-strategy merge`. The empty `--configs` means
  the VM never syncs `.obsidian/`, so it cannot push plugins (code) to the Mac.
  `--file-types` leaves out `unsupported`, so files like `*.pem` stay off the
  VM. A systemd user unit `obsidian-sync.service` runs `ob sync --continuous`
  (linger is on); guest-heal restarts it. `OBSIDIAN_VAULT=~/vault` in the VM.
  Remote vault name and an E2EE password, if the vault uses one, come from
  `den.json` (`obsidian.vault`) or the wizard. An E2EE vault password is asked in preflight, never stored.
- **Scribe stays on the Mac** (HiDock over USB, Voice Memos, Hex on the Apple
  GPU). It writes notes into the Mac vault; Obsidian Sync carries them to the
  VM. HiDock in the VM waits for macOS 27 USB passthrough in Lima's vz driver.
  So `uv` and `ffmpeg` also install on the Mac, for scribe only.
- Passwordless sudo is a den-managed `/etc/sudoers.d/<user>` (checked with
  `visudo -cf`), not Lima's cloud-init file.

## Exit codes

`0` all selected phases done or skipped; `1` any phase failed (`den up`,
`den fix`) or `--strict` doctor found a broken managed install; `2` usage error.
## Hooks

- Preflight: a lib may define `den_preflight_hook_<name> "$needs"` for an up-front human step (e.g. the VM's `gh auth login`). Never prompt without a TTY.
- Commands: a lib defines `den_cmd_<name>`; `bin/den` sources every `lib/*.sh` and dispatches `den <name>` to it.
- Doctor: a lib defines `den_doctor_<name>`; `den doctor` runs them all (sorted), prints their lines, and with `--strict` exits 1 if any returns nonzero.
