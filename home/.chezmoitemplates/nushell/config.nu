# Nushell configuration managed by chezmoi.

$env.config.show_banner = false
$env.config.history.max_size = 50_000
$env.config.history.sync_on_enter = true
$env.config.history.file_format = "sqlite"
$env.config.completions.algorithm = "fuzzy"
$env.config.completions.case_sensitive = false
$env.config.completions.quick = true
$env.config.completions.partial = true

let carapace_completer = {|spans|
  let expanded_alias = (scope aliases | where name == $spans.0 | get -o 0.expansion)
  let completed_spans = if $expanded_alias == null {
    $spans
  } else {
    $spans | skip 1 | prepend ($expanded_alias | split words)
  }

  carapace $completed_spans.0 nushell ...$completed_spans | from json
}

$env.config.completions.external = {
  enable: true
  max_results: 100
  completer: $carapace_completer
}

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
alias g = git

def --env cd-dev [] { cd ~/Developer }
def --env cd-down [] { cd ~/Downloads }
def --env cd-skills [] { cd ~/.agents/skills }
def --env cd-opencode [] { cd ~/.config/opencode }
def --env cd-pi [] { cd ~/.pi }
def --env cd-bootstrap [] { cd ~/Developer/github/acastro2/mac-bootstrap }
def --env cd-claude [] { cd ~/.claude }
def --env cd-onedrive [] { cd ~/Library/CloudStorage/OneDrive-Attainfinance.com }

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
alias gcm = git commit -m
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

# Additional common Git shortcuts from Oh My Zsh's git plugin
# and Fish's plugin-git. Destructive plugin aliases are intentionally omitted.
alias gapa = git add --patch
alias gau = git add --update
alias gav = git add --verbose
alias gba = git branch --all
alias gbl = git blame -w
alias gbs = git bisect
alias gbsb = git bisect bad
alias gbsg = git bisect good
alias gbsr = git bisect reset
alias gbss = git bisect start
alias gcmsg = git commit --message
alias gcam = git commit --all --message
alias gcf = git config --list
alias gcp = git cherry-pick
alias gcpa = git cherry-pick --abort
alias gcpc = git cherry-pick --continue
alias gd = git diff
alias gdca = git diff --cached
alias gdw = git diff --word-diff
alias gfo = git fetch origin
alias glg = git log --stat
alias glgg = git log --graph
alias glgga = git log --graph --decorate --all
alias glog = git log --oneline --decorate --graph
alias gloga = git log --oneline --decorate --graph --all
alias gm = git merge
alias gma = git merge --abort
alias gmff = git merge --ff-only
alias gpr = git pull --rebase
alias gpra = git pull --rebase --autostash
alias gpv = git push --verbose
alias grb = git rebase
alias grba = git rebase --abort
alias grbc = git rebase --continue
alias grbi = git rebase --interactive
alias grbs = git rebase --skip
alias grev = git revert
alias grmv = git remote rename
alias grrm = git remote remove
alias grset = git remote set-url
alias grup = git remote update
alias grv = git remote --verbose
alias grst = git restore --staged
alias gsb = git status --short --branch
alias gsh = git show
alias gstd = git stash drop
alias gstl = git stash list
alias gsts = git stash show --patch
alias gstall = git stash --all
alias gsu = git submodule update
alias gsur = git submodule update --recursive
alias gsuri = git submodule update --recursive --init
alias gsw = git switch
alias gswc = git switch --create
alias gtv = git tag
alias gwt = git worktree
alias gwta = git worktree add
alias gwtls = git worktree list
alias gwtrm = git worktree remove
alias gup = git pull --rebase

# Dynamic Git helpers need the current branch or repository root at invocation time.
def --env grt [] {
  let root = (do { git rev-parse --show-toplevel } | complete)
  if $root.exit_code != 0 {
    error make { msg: "grt must run inside a Git worktree" }
  }
  cd ($root.stdout | str trim)
}

def gpsup [] {
  let branch = (git branch --show-current | str trim)
  if ($branch | is-empty) {
    error make { msg: "gpsup requires a named Git branch" }
  }
  git push --set-upstream origin $branch
}

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

# Docker aliases from Oh My Zsh's docker plugin. They assume the Docker CLI
# is connected to the intended Colima context.
alias dbl = docker build
alias dcin = docker container inspect
alias dcls = docker container ls
alias dclsa = docker container ls --all
alias dib = docker image build
alias dii = docker image inspect
alias dils = docker image ls
alias dlo = docker container logs
alias dnc = docker network create
alias dnls = docker network ls
alias dpo = docker container port
alias dps = docker ps
alias dpsa = docker ps --all
alias dpu = docker pull
alias dr = docker container run
alias drit = docker container run --interactive --tty
alias drm = docker container rm
alias dst = docker container start
alias drs = docker container restart
alias dstp = docker container stop
alias dsts = docker stats
alias dtop = docker top
alias dvi = docker volume inspect
alias dvls = docker volume ls
alias dxc = docker container exec
alias dxcit = docker container exec --interactive --tty

# Kubernetes aliases from Oh My Zsh's kubectl plugin. Context-changing and
# destructive delete/restart aliases stay explicit for safety.
alias kaf = kubectl apply --filename
alias kapk = kubectl apply --kustomize
alias keti = kubectl exec --tty --stdin
alias kccc = kubectl config current-context
alias kcgc = kubectl config get-contexts
alias kcuc = kubectl config use-context
alias kge = kubectl get events --sort-by=".lastTimestamp"
alias kgp = kubectl get pods
alias kgpa = kubectl get pods --all-namespaces
alias kgpw = kubectl get pods --watch
alias kgpwide = kubectl get pods --output wide
alias kgs = kubectl get services
alias kgsa = kubectl get services --all-namespaces
alias kgsw = kubectl get services --watch
alias kgns = kubectl get namespaces
alias kgd = kubectl get deployments
alias kgda = kubectl get deployments --all-namespaces
alias kgdw = kubectl get deployments --watch
alias kgdwide = kubectl get deployments --output wide
alias kgno = kubectl get nodes
alias kga = kubectl get all
alias kgaa = kubectl get all --all-namespaces
alias kl = kubectl logs
alias klf = kubectl logs --follow
alias kcp = kubectl cp
alias kpf = kubectl port-forward

# Helm aliases from Oh My Zsh's helm plugin.
alias h = helm
alias hin = helm install
alias hun = helm uninstall
alias hse = helm search
alias hup = helm upgrade

# Terraform-plugin aliases backed by the toolchain this repo installs. The
# wrapper prefers OpenTofu but falls back to Terraform when that is present.
def --wrapped tf [...args] {
  if (which tofu | is-empty) {
    ^terraform ...$args
  } else {
    ^tofu ...$args
  }
}

def tfi [...args] { tf init ...$args }
def tfir [...args] { tf init --reconfigure ...$args }
def tfiu [...args] { tf init --upgrade ...$args }
def tff [...args] { tf fmt ...$args }
def tffr [...args] { tf fmt --recursive ...$args }
def tfp [...args] { tf plan ...$args }
def tfpo [...args] { tf plan --out tfplan ...$args }
def tfa [...args] { tf apply ...$args }
def tfv [...args] { tf validate ...$args }
def tfo [...args] { tf output ...$args }
def tfsh [...args] { tf show ...$args }
def tft [...args] { tf test ...$args }
def tfw [...args] { tf workspace ...$args }
def tfwl [...args] { tf workspace list ...$args }
def tfws [...args] { tf workspace select ...$args }

# AWS helpers do not mutate the shell environment; pass profiles explicitly.
alias awsp = aws configure list-profiles
alias awswho = aws sts get-caller-identity

if (($nu.default-config-dir | path join ".api-keys.nu") | path exists) {
  source-env ($nu.default-config-dir | path join ".api-keys.nu")
}

if ("GRAFANA_SERVICE_ACCOUNT_TOKEN" in $env) {
  $env.GRAFANA_TOKEN = $env.GRAFANA_SERVICE_ACCOUNT_TOKEN
}

if (($nu.default-config-dir | path join "config.local.nu") | path exists) {
  source ($nu.default-config-dir | path join "config.local.nu")
}
