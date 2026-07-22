# Nushell configuration managed by chezmoi.

$env.config.show_banner = false
$env.config.history.max_size = 50_000
$env.config.history.sync_on_enter = true
$env.config.history.file_format = "sqlite"
$env.config.completions.algorithm = "fuzzy"
$env.config.completions.case_sensitive = false
$env.config.completions.quick = true
$env.config.completions.partial = true

if (($nu.default-config-dir | path join "mise.nu") | path exists) {
  use ($nu.default-config-dir | path join "mise.nu")
}

if (($nu.default-config-dir | path join "completions" "opencode.nu") | path exists) {
  source ($nu.default-config-dir | path join "completions" "opencode.nu")
}

alias ls = eza --icons --group-directories-first
alias ll = eza -lh --icons --git --group-directories-first
alias la = eza -la --icons --git --group-directories-first
alias cat = bat --paging=never
alias k = kubectl
alias code = code-insiders

def --env cd-dev [] { cd ~/Developer }
def --env cd-down [] { cd ~/Downloads }
def --env cd-skills [] { cd ~/.agents/skills }
def --env cd-opencode [] { cd ~/.config/opencode }
def --env cd-bootstrap [] { cd ~/Developer/github/acastro2/mac-bootstrap }
def --env cd-claude [] { cd ~/.claude }
def --env cd-onedrive [] { cd ~/Library/CloudStorage/OneDrive-Attainfinance.com }

def --env awssso [profile: string = "default"] {
  aws sso login --profile $profile
  $env.AWS_PROFILE = $profile
}

# Focused Git shortcuts based on commands used in Fish history.
alias gs = git status
alias gst = git status
alias gss = git status --short
alias ga = git add
alias gaa = git add --all
alias gb = git branch
alias gbd = git branch -d
alias gco = git checkout
alias gcb = git checkout -b
alias gcl = git clone
alias gc = git commit
alias gca = git commit --amend
alias gcan = git commit --amend --no-edit
alias gf = git fetch
alias gfa = git fetch --all --prune
alias gl = git pull
alias glr = git pull --rebase
alias gp = git push
alias gpf = git push --force-with-lease
alias gr = git remote -v
alias gra = git remote add
alias grr = git remote remove
alias grs = git restore
alias grh = git reset HEAD
alias grh1 = git reset HEAD~1
alias gsta = git stash
alias gstp = git stash pop
alias glo = git log --oneline --decorate --color

def git-clean [] {
  let worktree = (do { git rev-parse --is-inside-work-tree } | complete)
  if $worktree.exit_code != 0 {
    error make { msg: "git-clean must run inside a Git worktree" }
  }

  let origin = (do { git remote get-url origin } | complete)
  if $origin.exit_code != 0 {
    error make { msg: "git-clean requires an origin remote" }
  }

  let fetch = (do { git fetch --prune origin } | complete)
  if $fetch.exit_code != 0 {
    error make { msg: ($fetch.stderr | str trim) }
  }

  let remote_head = (do {
    git symbolic-ref --quiet --short refs/remotes/origin/HEAD
  } | complete)
  if $remote_head.exit_code != 0 {
    error make { msg: "Cannot detect origin's default branch. Run: git remote set-head origin --auto" }
  }

  let default_ref = ($remote_head.stdout | str trim)
  let default_branch = ($default_ref | str replace "origin/" "")
  let current_branch = (git branch --show-current | str trim)
  let merged = (git for-each-ref --format="%(refname:short)" $"--merged=($default_ref)" refs/heads
    | lines
    | where { |branch| $branch != $current_branch and $branch != $default_branch })

  if ($merged | is-empty) {
    print $"No local branches are merged into ($default_ref)."
    return
  }

  for branch in $merged {
    let deletion = (do { git branch -d $branch } | complete)
    if $deletion.exit_code == 0 {
      print ($deletion.stdout | str trim)
    } else {
      print --stderr ($deletion.stderr | str trim)
    }
  }
}

if (($nu.default-config-dir | path join ".api-keys.nu") | path exists) {
  source-env ($nu.default-config-dir | path join ".api-keys.nu")
}

if (($nu.default-config-dir | path join "config.local.nu") | path exists) {
  source ($nu.default-config-dir | path join "config.local.nu")
}
