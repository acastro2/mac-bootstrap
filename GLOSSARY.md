# mac-bootstrap

Declares and builds Alex's workstation state on macOS and Linux: packages, shell,
dotfiles, agent CLIs, and secrets.

## Language

**Bootstrap**:
One run of `bootstrap.sh` that brings a machine to the declared state.
_Avoid_: setup, install, provisioning

**Phase**:
A named, individually selectable unit of a bootstrap run.
_Avoid_: step, section, task

**Managed install**:
A tool this repo installs directly at a path it owns.
_Avoid_: tool, package, dependency

**Managed install registry**:
The declared set of managed installs, and the single source of truth for whether each one is present and where it resolves.
_Avoid_: tool list, manifest

**Single install**:
The rule that a managed install resolves to exactly one path, its managed path, in every shell.
_Avoid_: dedupe, no duplicates

**Doctor**:
A read-only check of whether the machine matches the declared state.
_Avoid_: health check, verification

**Secrets file**:
The private zsh file that holds API keys pulled from 1Password.
_Avoid_: env file, dotenv

**Session data**:
Agent conversation state that must survive a move to a new machine.
_Avoid_: history, state

**Dotfiles**:
The home-directory files that chezmoi renders from `home/`.
_Avoid_: config, shell config
