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
| Editing | VS Code Remote-SSH to `lima-agent` | Edit the clones in place |
| Host folders | **None mounted** (`mounts: []`) | Nothing in `~/.config`, `~/.ssh` or `~/Library` is reachable |

The guest can still open network connections to services on the Mac
(`192.168.5.2`). Bind Mac services to `127.0.0.1`.

## Use it

```sh
den up --only=vm             # create or resize, start, provision the guest
den vm up                    # autostart + the login agent + start
den vm down                  # stop the agent and autostart FIRST, then the VM
den vm status                # VM, relay, tunnel, login agent
den vm logs                  # tail ~/.local/state/rex-vm/vm-up.log
den vm shell                 # ssh into the guest
den vm rebuild               # typed confirm (or --yes), then delete and rebuild
den vm resources             # cpus=N memory=M disk=D this Mac allows
ssh lima-agent               # ~/.ssh/config includes ~/.lima/*/ssh.config
```

`den vm down` is how the RAM comes back. Do not use `limactl stop agent`
alone: the login agent brings the VM back within a minute.

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

1. Sizes the VM from the Mac: cores − 2, half the RAM (macOS keeps 8 GiB),
   half the free disk capped at 100 GiB. Creates it, or resizes a **stopped**
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
   and `bin/den up` for the Linux phases.
5. Installs Obsidian Headless with the guest's mise node, always. Sync is set
   up only once a vault name is known (`obsidian.vault` in the bundle or
   `OBSIDIAN_SYNC_VAULT`): `ob sync-setup`, then
   `ob sync-config --configs "" ... --file-types image,audio,video,pdf`, then
   the `obsidian-sync.service` user unit (`ob sync --continuous`,
   `Restart=on-failure`). No vault name: only this step is skipped, with the
   reason. Without the empty `--configs`, the VM would push plugins (code) to
   the Mac.
6. Installs the Rex server when the guest does not answer `rex server status`,
   installs the VS Code Remote-SSH extension when missing, runs one heal
   pass, and installs/loads the vm-up login agent.

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
path that is not absolute or holds control characters, dedupes the same path
within 10 s, and opens at most 5 a minute. Every accepted and rejected request
is logged.

## Limits

- Colima and Docker-in-Docker are not the point: the guest runs Docker Engine
  rootful on its own kernel.
- HiDock and Voice Memos stay on the Mac (USB and the Apple GPU). Scribe
  writes into the Mac vault; Obsidian Sync carries notes to the guest.
