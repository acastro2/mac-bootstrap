# Agents in a VM

The agent VM is the dev box. The Mac is the window, the keys, the browser and
the VM host. Coding happens in the guest; Rex on the Mac is a window onto it,
so every tab on host `vm` is a zsh in Linux.

`den up --only=vm` sizes, starts and provisions it; `den vm ...` drives it by
hand. `vm/vm-up.sh` keeps it alive from the `io.mac-bootstrap.vm-up` login
agent.

## Why

Agents run with few permission prompts. A bad command inside the VM can only
damage the VM: it has its own disk under `~/.lima/agent`. `den vm rebuild`
throws the whole box away and builds a new one.

## What crosses the boundary

| Path | How | Why |
| --- | --- | --- |
| Code | VM-owned clones in `~/code`, pushed and pulled through GitHub | The Mac never runs a file the VM wrote |
| SSH keys | **Not forwarded** (`ssh.forwardAgent: false`) | The guest has its own `gh` login, so it never borrows the Mac's 1Password agent |
| API keys | `limactl copy` of `~/.config/zsh/.api-keys.zsh`, mode 600 | `op` stays on the Mac; every key still reaches the dev box, on purpose |
| Browse relay | `rex forward -R 127.0.0.1:19988` plus the relay token, mode 600 | VM agents drive the Mac browser; the relay port is not mirrored back (Lima `portForwards` ignores it) |
| Superlogical MCP | The URL from the den bundle, piped on stdin by the `vm-mcp` phase into `claude mcp add` in the guest | The VM's Claude Code gets the same MCP. The URL rides argv in the guest for about a second ([contract rule 5](../docs/den/CONTRACT.md)) |
| Editing | VS Code Remote-SSH to `lima-agent` | Edit the clones in place. **Accepted risk:** while a window is open, the VM can ask it to run a command on the Mac. Remote-SSH trusts the remote. See [../docs/den/JAILBREAK.md](../docs/den/JAILBREAK.md) |
| Host folders | **None mounted** (`mounts: []`) | Nothing in `~/.config`, `~/.ssh` or `~/Library` is reachable |

By default, Lima's gateway (`192.168.5.2`, `host.lima.internal`) leads to
the Mac's `127.0.0.1`, so binding a Mac service to localhost does not protect
it. `lima-dev.yaml` sets `networkOpts.hostLoopback: false` to close that path,
and `den doctor` checks it. Mac services that listen on every interface (SSH,
Screen Sharing) stay reachable through the Mac's LAN address and need their
own fix. Every path from the VM to the Mac:
[../docs/den/JAILBREAK.md](../docs/den/JAILBREAK.md).

## Use it

```sh
den up --only=vm             # create or resize, start, provision the guest
den vm up                    # autostart + the login agent + start
den vm down                  # stop the agent and autostart FIRST, then the VM
den vm status                # VM, relay, tunnel, login agent
den vm logs                  # tail ~/.local/state/rex-vm/vm-up.log
den vm shell                 # ssh into the guest
den vm rebuild               # typed confirm (or --yes), then delete and rebuild
den vm obsidian-sync         # restart obsidian-sync.service in the guest
den vm resources             # cpus=N memory=M disk=D this Mac allows
den pair                     # phone pair link + QR for the VM's OpenCode (home Wi-Fi, on demand)
den pair --stop              # close that forward (also: --status)
ssh lima-agent               # ~/.ssh/config includes ~/.lima/*/ssh.config
```

`den vm down` is how the RAM comes back. Do not use `limactl stop agent`
alone: the login agent brings the VM back within a minute.

### burn: free the guest fast

Run `burn` inside the guest when it is starved. It kills at once, with no
prompt, and then stops every Docker container.

- **Keeps:** agents (`claude`, `opencode`) and their MCP servers, pane shells
  (Rex, SSH, tmux), the VS Code server, Obsidian sync, editors and viewers
  (vim, nvim, less, htop and so on), and infrastructure (systemd, dbus, sshd,
  ssh-agent, gpg-agent).
- **Kills:** what an agent ran through a shell (test runs, looping scripts),
  orphans under `systemd --user`, and any other job you started.
- **tofu and terraform** (and their providers) only get SIGINT. burn leaves
  them to finish, up to 60 s, then reports any still running. It never sends
  them STOP, TERM or KILL, so state locks release cleanly.
- `bash vm/burn.test.sh` checks the classifier against a fixture process tree.
- `burn -n` is a dry run: it lists the kill set and touches nothing.
- `burn -n` (and `burn`) print the kill list as a table with CPU now (1 s sample), RSS and age, sorted by RSS. The last column is the command to kill that one row by hand (`kill -INT` for tofu).
- Agents may start their jobs again. Find the agent that loops and stop it.

### Rex server guard

An AppArmor profile (`vm/rex-server.apparmor`, installed as
`/etc/apparmor.d/rex-server`) stops every process started from a Rex terminal
from signalling the Rex server. Why: `lsof -ti :PORT | xargs kill -9` also
matches the server when it holds a Mac forward to that port, and that ends
every session.

- A `kill` from a terminal to the server gets `Permission denied`, `kill -9`
  too. The kernel log shows `apparmor="DENIED" operation="signal"`.
- `rex server stop` from a terminal is blocked too: it sends SIGTERM. Restart
  with `systemctl --user restart rex`, run in `limactl shell agent`, never in a
  Rex terminal: it ends every session.
- Not covered: `systemctl --user stop|restart|kill rex` from a terminal still
  works, because systemd (not confined) sends the signal.
- Terminals, even under sudo, cannot unload the profile or edit
  `/etc/apparmor.d`. Change it from `limactl shell agent`, which is not confined.
- It stops accidents, not intent: a `limactl shell` session can still kill Rex.
- `ps -eo pid,label,comm | grep rex-server` shows what is confined.

### Connect Rex for Mac (once per Mac, by hand)

1. Press ⌘⇧P and run **Add Remote Host…**.
2. Type `ssh://lima-agent`. The box's hint shows only `https://` and socket
   paths, but `ssh://` works. Rex runs the system `ssh`, so the
   `Include ~/.lima/*/ssh.config` line in `~/.ssh/config` supplies the port,
   user and Lima's key. No 1Password prompt.
3. Press ⌘⇧P and run **Switch Host**, then pick the new host. New tabs open
   in the VM.

Why this is manual:

- `rex hosts add vm ssh://lima-agent` writes the host to the server's list,
  and `rex -S vm ...` works from the CLI. Rex for Mac (build 1996) still did
  not offer it. It needed the add in step 1.
- The app refuses scripted actions (`client.perform`) unless **Settings →
  Rex Server → Remote Control** is on. It stays off: it would let any local
  process, agents included, drive the app.

The vm phase prints this reminder only when it just installed the Rex server,
so a healthy Mac stays quiet.

## What the vm phase does

1. Sizes the VM from the Mac: every core, the larger of half the RAM and RAM − 12 GiB
   (macOS keeps at least 8 GiB; the VM never gives touched RAM back until it restarts),
   half the free disk, at least 40 GiB and at most 200 GiB. Creates it, or resizes a **stopped**
   VM that is too small; a running VM is left alone with the fix command. A
   disk below target is reported, never shrunk.
2. Registers it for autostart and puts the Lima ssh include first in
   `~/.ssh/config` (backup kept).
3. Copies `~/.config/zsh/.api-keys.zsh` (every key) and the browse relay
   token into the guest, mode 600.
4. Pipes `vm/guest-provision.sh` in with `limactl shell agent -- bash -s`.
   The guest gets Docker Engine from Docker's apt repository
   (`docker-ce`, `containerd.io`, `docker-buildx-plugin`,
   `docker-compose-plugin`), joins the `docker` group, a validated
   `/etc/sudoers.d/<user>` (checked with `visudo -cf`, mode 0440), the repo,
   and `bin/den up` for the Linux phases. It also points OpenTofu at one
   shared provider cache (`plugin_cache_dir` in `~/.terraformrc`), so each
   checkout's `tofu init` links the providers instead of copying them. It also
   sets up zram swap (half of RAM, zstd) with `systemd-zram-generator`, installing
   `linux-modules-extra` for the running kernel because the cloud image kernel lacks
   the zram module, and the `linux-image-generic` meta so each kernel upgrade
   brings its `-extra` (the image's `linux-image-virtual` meta does not).
5. Installs Obsidian Headless with the guest's mise node, always. Sync is set
   up only once a vault name is known (`obsidian.vault` in the bundle or
   `OBSIDIAN_SYNC_VAULT`): `ob sync-setup`, then
   `ob sync-config --configs "" ... --file-types image,audio,video,pdf`, then
   the `obsidian-sync.service` user unit (`ob sync --continuous`,
   `Restart=on-failure`). No vault name: only this step is skipped, with the
   reason. Without the empty `--configs`, the VM would push plugins (code) to
   the Mac.
6. Installs the Rex server when the guest's `rex.socket` user unit is not active,
   installs the VS Code Remote-SSH extension when missing, runs one heal
   pass, and installs/loads the vm-up login agent.

## Backup and restore

`den vm backup` makes one full, encrypted copy of the VM. It is manual: no
schedule, no login agent. Run it when you want a safe point.

- **What is copied:** `disk`, `vz-efi`, `vz-identifier` and `lima.yaml` from
  `~/.lima/agent`, so the VM can start again on any Mac.
- **How:** while the VM runs, the guest root filesystem is frozen
  (`fsfreeze`) for about 0.1 s. The Mac clones the files (APFS clone, no extra
  disk) and thaws the guest. The VM does not stop. If the Mac side dies, the
  guest thaws itself after 10 s. A stopped VM is cloned with no freeze.
- **Where:** a restic repo in your OneDrive folder
  (`~/Library/CloudStorage/OneDrive-*/den-vm-backup`), or `VM_BACKUP_REPO`
  from `config.env`. The password is `vm.backup_password` from the den
  document. `den vm backup` loads it like `den up` does, so each run may show
  a 1Password approval prompt.
- **How many:** one copy. Each run replaces it, and only after the new copy
  succeeded, so a failed run never deletes the old one.
- **Check:** `den vm status` and `den doctor` show `vm: backup OK (last
  <date>)`, and warn when the last backup is over 14 days old.

First setup: add `vm.backup_password` to the den document
(`openssl rand -base64 32`), then `den up --only=vm-backup` creates the repo.

In Finder, set the `den-vm-backup` folder to **Always Keep on This Device**,
so OneDrive does not turn the repo into online-only files.

On a new Mac:

1. `bootstrap.sh` (installs den and runs `den up`)
2. `den up --only=vm-backup` (checks the repo opens with the den password)
3. `den vm restore` (refuses if `~/.lima/agent` already exists)
4. `limactl start agent`

## Self-healing (nothing to remember)

`vm/vm-up.sh` runs the VM, the relay, the tunnel and the guest repairs:

| What | How often | Fix |
| --- | --- | --- |
| VM running | 60 s | Starts a stopped VM once per backoff window (10 s → 1 m → 10 m → 1 h) |
| VM missing | 60 s | Rebuilds with the vm phase, at most once an hour |
| Mac browse relay | 60 s | `browse serve` when 127.0.0.1:19988 does not answer; PID tracked, one try a minute |
| Tunnel VM → relay | 60 s | Probes the relay **inside** the guest; if the Mac answers and the guest does not, exits so launchd rebuilds the tunnel |
| API keys, relay token | 5 min | Copied in (mode 600) when the sha256 changed |
| browse link, docker, rex, obsidian-sync | 5 min | `vm/guest-heal.sh`, piped into the guest |
| `code` in the VM | instant | Opens VS Code on the Mac over Remote-SSH |

Every `limactl shell` and `copy` is bounded with a timeout. State (backoff
stamps, relay PID, bridge offset) lives in `~/.local/state/rex-vm`.

## `code` from the VM

`code <folder>` inside the guest appends an absolute path to
`~/.local/state/vm-open/requests`. The guest prints a short line saying VS Code
was **requested**; the Mac opens it over Remote-SSH.

The bridge accepts one thing: an absolute path, passed as one request. It
resumes from a persisted byte offset (never replays old requests), refuses a
path that is not absolute or holds control characters, refuses an immediate
repeat of the same path within 10 s, and opens at most 5 a minute. Every accepted and rejected request
is logged.

## Limits

- Colima and Docker-in-Docker are not the point: the guest runs Docker Engine
  rootful on its own kernel.
- HiDock and Voice Memos stay on the Mac (USB and the Apple GPU). Scribe
  writes into the Mac vault; Obsidian Sync carries notes to the guest.
