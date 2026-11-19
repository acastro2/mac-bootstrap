# Agents in a VM

opencode and Claude Code run inside a Lima Linux VM. Rex on the Mac is a window
onto that VM: its server runs in the guest, so every tab on host `vm` is a zsh
in Linux.

## Why

Agents run with few permission prompts. A bad command inside the VM can only
damage the VM. The guest has its own disk under `~/.lima/agent`. Rebuild it
with `limactl delete agent` and a new create.

## What crosses the boundary

| Path | How | Why |
| --- | --- | --- |
| Code | VM-owned clones in `~/code`, pushed and pulled through GitHub | The Mac never runs a file the VM wrote |
| SSH keys | Forwarded Mac agent (`ssh.forwardAgent`) | git and gh reach 1Password; the approval shows on the Mac |
| API keys | `limactl copy` of `~/.config/zsh/.api-keys.zsh`, mode 600 | `op` stays on the Mac |
| Editing | VS Code or Zed Remote-SSH to `lima-agent` | Edit the clones in place |
| Host folders | None mounted | Nothing in `~/.config`, `~/.ssh` or `~/Library` is reachable |

The guest can still open network connections to services on the Mac
(`192.168.5.2`). Bind Mac services to `127.0.0.1`.

## Use it

```sh
limactl start agent          # boot; 8 GiB and 4 CPU are held while it runs
limactl stop agent           # give the RAM back
ssh lima-agent               # ~/.ssh/config includes ~/.lima/*/ssh.config
rex -S vm ls                 # the Rex CLI on the Mac, pointed at the VM
```

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

`./bootstrap.sh` prints this reminder in its next steps whenever the Lima
instance `agent` exists.

## Self-healing (nothing to remember)

The `io.mac-bootstrap.vm-up` login agent runs `vm/vm-up.sh` and keeps this true:

| What | How often | Fix |
| --- | --- | --- |
| VM running | 60 s | Starts it after 5 min down; rebuilds a deleted instance with `bootstrap.sh --only=vm` |
| Mac browse relay | 60 s | `browse serve` when 127.0.0.1:19988 does not answer |
| Tunnel VM → relay | always | `rex -S vm forward -R 19988`; reconnects; launchd restarts it |
| API keys, relay token | 5 min | Copied in (mode 600) when the content changed |
| browse link, rex server | 5 min | `vm/guest-heal.sh`, piped into the guest |
| `code .` in the VM | instant | Opens VS Code on the Mac over Remote-SSH (absolute path only) |

`limactl stop agent` is undone within 5 minutes. To keep the VM off, stop
the agent first: `launchctl bootout gui/$UID/io.mac-bootstrap.vm-up`.
Log: `~/.local/state/rex-vm/vm-up.log`.

## Limits

- Colima and Docker cannot run in the guest: M1 Pro has no nested
  virtualization (`/dev/kvm` is missing). Use the containerd and nerdctl that
  Lima installs.
