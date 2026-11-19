#!/usr/bin/env bash
# bootstrap.sh — stage 0: CLT, Homebrew, git, gum, jq, the repo, then bin/den.
# Runs before lib/ exists, so it carries its own tiny plain UI. Bash 3.2.
# Inside a checkout it hands the old flags to bin/den; on a fresh Mac it
# installs the floor, clones the repo, and execs the clone's `den up`.
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/acastro2/mac-bootstrap.git}
REPO_DIR=${REPO_DIR:-$HOME/Developer/github/acastro2/mac-bootstrap}

ui_step() { printf '  -> %s\n' "$*"; }
ui_ok() { printf '[ok] %s\n' "$*"; }
ui_warn() { printf '[warn] %s\n' "$*" >&2; }
ui_err() { printf '[err] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
bootstrap.sh — set up this Mac: stage 0, then den.

Usage:
  curl -fsSL https://raw.githubusercontent.com/acastro2/mac-bootstrap/main/bootstrap.sh | bash
  ./bootstrap.sh
  ./bootstrap.sh --only=one,two    --skip=three    --dry-run
  ./bootstrap.sh --only=doctor [--strict]
  ./bootstrap.sh --dump-tools
  ./bootstrap.sh --dump-vm-resources
  ./bootstrap.sh --clean [--dry-run]
  ./bootstrap.sh --export-sessions
  ./bootstrap.sh --import-sessions=<file>

Inside a checkout these map to bin/den: up, doctor, registry list,
vm resources, clean, sessions export, sessions import. Unknown flags exit 2.

Environment:
  REPO_URL   repo to clone (default: acastro2/mac-bootstrap)
  REPO_DIR   where to clone it (default: ~/Developer/github/acastro2/mac-bootstrap)
EOF
}

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# den_from_checkout <args...>: map the old bootstrap flags onto bin/den.
den_from_checkout() {
  local only="" skip="" dry=0 clean=0 strict=0 export_sessions=0 import_file=""
  local dump_tools=0 dump_vm=0
  local args=()
  while [ $# -gt 0 ]; do
    case $1 in
      --only=*) only=${1#--only=} ;;
      --only|-o)
        if [ $# -lt 2 ]; then
          ui_err "--only needs a value"
          usage >&2
          exit 2
        fi
        shift
        only=$1
        ;;
      --skip=*) skip=${1#--skip=} ;;
      --skip|-s)
        if [ $# -lt 2 ]; then
          ui_err "--skip needs a value"
          usage >&2
          exit 2
        fi
        shift
        skip=$1
        ;;
      --dry-run) dry=1 ;;
      --clean) clean=1 ;;
      --strict) strict=1 ;;
      --dump-tools) dump_tools=1 ;;
      --dump-vm-resources) dump_vm=1 ;;
      --export-sessions) export_sessions=1 ;;
      --import-sessions=*) import_file=${1#--import-sessions=} ;;
      --import-sessions)
        if [ $# -lt 2 ]; then
          ui_err "--import-sessions needs a file"
          usage >&2
          exit 2
        fi
        shift
        import_file=$1
        ;;
      *)
        ui_err "unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  if [ "$strict" = 1 ] && [ "$only" != doctor ]; then
    ui_err "--strict only applies to --only=doctor"
    usage >&2
    exit 2
  fi

  if [ "$dump_tools" = 1 ]; then
    args=(registry list)
  elif [ "$dump_vm" = 1 ]; then
    args=(vm resources)
  elif [ "$clean" = 1 ]; then
    args=(clean)
    if [ "$dry" = 1 ]; then
      args[${#args[@]}]=--dry-run
    fi
  elif [ "$export_sessions" = 1 ]; then
    args=(sessions export)
  elif [ -n "$import_file" ]; then
    args=(sessions import "$import_file")
  elif [ "$only" = doctor ]; then
    args=(doctor)
    if [ "$strict" = 1 ]; then
      args[${#args[@]}]=--strict
    fi
  else
    args=(up)
    if [ -n "$only" ]; then
      args[${#args[@]}]="--only=$only"
    fi
    if [ -n "$skip" ]; then
      args[${#args[@]}]="--skip=$skip"
    fi
    if [ "$dry" = 1 ]; then
      args[${#args[@]}]=--dry-run
    fi
  fi
  exec "$SCRIPT_DIR/bin/den" "${args[@]}"
}

# Everything below is the fresh-Mac path: no checkout sat next to this script.
if [ -x "$SCRIPT_DIR/bin/den" ]; then
  den_from_checkout "$@"
fi

if [ "$(uname -s)" = Darwin ]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    ui_step "installing the Xcode Command Line Tools (a dialog will open)"
    xcode-select --install >/dev/null 2>&1 || true
    ui_warn "finish the Command Line Tools install. If brew fails below, re-run this script."
  fi
fi

brew_shellenv() {
  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then
      eval "$("$candidate" shellenv)"
      return 0
    fi
  done
  return 1
}

if ! command -v brew >/dev/null 2>&1; then
  brew_shellenv || true
fi
if ! command -v brew >/dev/null 2>&1; then
  ui_step "installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
  brew_shellenv || true
fi
if ! command -v brew >/dev/null 2>&1; then
  ui_err "Homebrew is still missing. Install it from https://brew.sh, then re-run this script."
  exit 1
fi
brew_version=$(brew --version 2>/dev/null || true)
brew_version=${brew_version%%$'\n'*}
ui_ok "Homebrew ${brew_version:-ready}"

if ! command -v git >/dev/null 2>&1; then
  ui_err "git is missing. Install the Xcode Command Line Tools, then re-run this script."
  exit 1
fi

for formula in gum jq; do
  if ! command -v "$formula" >/dev/null 2>&1; then
    ui_step "installing $formula"
    brew install "$formula" >/dev/null 2>&1 || ui_warn "could not install $formula; den still works without it"
  fi
done

if [ -d "$REPO_DIR/.git" ]; then
  ui_step "updating $REPO_DIR"
  git -C "$REPO_DIR" pull --ff-only || ui_warn "could not fast-forward $REPO_DIR; using what is there"
else
  ui_step "cloning $REPO_URL into $REPO_DIR"
  mkdir -p "$(dirname "$REPO_DIR")"
  if ! git clone "$REPO_URL" "$REPO_DIR"; then
    ui_err "could not clone $REPO_URL"
    exit 1
  fi
fi
if [ ! -x "$REPO_DIR/bin/den" ]; then
  ui_err "$REPO_DIR has no executable bin/den"
  exit 1
fi

# config.env is read only from the clone, never from $PWD.
exec "$REPO_DIR/bin/den" up "$@"
