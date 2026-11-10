# >>> zsh handoff — the account shell is /bin/sh and changing it needs root, so
# interactive login shells exec zsh here instead. Bypass: NO_ZSH=1 wsl.exe
# (or `wsl.exe -e bash --norc`). Harmless once `chsh -s /usr/bin/zsh` is done.
case $- in
  *i*)
    if [ -z "${ZSH_VERSION:-}" ] && [ -z "${NO_ZSH:-}" ]; then
      for _zsh in /usr/bin/zsh "$HOME/.local/bin/zsh"; do
        [ -x "$_zsh" ] && SHELL=$_zsh exec "$_zsh" -l
      done
      unset _zsh
    fi
    ;;
esac
# <<< zsh handoff
