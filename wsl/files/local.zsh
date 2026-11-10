# ~/.config/zsh/local.zsh — WSL overrides for the shared .zshrc. Deployed by
# wsl/setup.sh (configs step); sourced last by ~/.zshrc. The WINHOME value
# below is filled in with your Windows profile dir at deploy time.
[[ -n ${WSL_DISTRO_NAME:-} ]] || return 0

export WINHOME=@WINHOME@
cd-win()      { cd $WINHOME }
cd-down()     { cd $WINHOME/Downloads }
cd-onedrive() { local d=( "$WINHOME"/OneDrive\ -\ *(N/) "$WINHOME"/OneDrive(N/) ); cd ${d[1]:?no OneDrive folder} }  # work OneDrive first

# Windows tools stay reachable even if appendWindowsPath=false is set in
# /etc/wsl.conf (faster command lookup and completion). Appended, never ahead
# of Linux bins. No existence checks: every stat on /mnt/c is a slow 9P round-trip.
path+=(
  "$WINHOME/AppData/Local/Programs/Microsoft VS Code Insiders/bin"
  /mnt/c/Windows/System32
  /mnt/c/Windows
  /mnt/c/Windows/System32/WindowsPowerShell/v1.0
  "$WINHOME/AppData/Local/Microsoft/WindowsApps"
)

# Open URLs/files with the Windows default app. gh, az and aws sso use $BROWSER.
export BROWSER=$HOME/.local/bin/wsl-open
alias open='wsl-open'
alias pbcopy='clip.exe'
pbpaste() { powershell.exe -NoProfile -Command Get-Clipboard | tr -d '\r' }
alias explorer='explorer.exe .'

# SSH agent from the systemd user unit (~/.config/systemd/user/ssh-agent.service).
export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent.socket

# Shared libs unpacked from Ubuntu .debs without root (Chromium's libnss3/
# libasound2, libpq for psql). Removed once they're installed with apt.
[[ -d $HOME/.local/lib/userdebs ]] && export LD_LIBRARY_PATH=$HOME/.local/lib/userdebs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# Windows Terminal owns Ctrl+T (new tab), so fzf's file picker moves to Alt+T.
(( $+widgets[fzf-file-widget] )) && bindkey '^[t' fzf-file-widget

# Report the cwd to Windows Terminal (OSC 9;9) on every prompt, so Ctrl+T
# (duplicateTab) opens the new tab in the same folder. Pure zsh, no wslpath
# call: /mnt/c/x → C:\x, anything else → \\wsl.localhost\<distro>\...
_wt_report_cwd() {
  local p
  if [[ $PWD == /mnt/[a-z](/*|) ]]; then
    p="${(U)PWD[6]}:${${PWD#/mnt/?}:-/}"
  else
    p="\\\\wsl.localhost\\${WSL_DISTRO_NAME}${PWD}"
  fi
  printf "\e]9;9;%s\e\\" "${p//\//\\}"
}
[[ -n ${WT_SESSION:-} ]] && precmd_functions+=(_wt_report_cwd)
