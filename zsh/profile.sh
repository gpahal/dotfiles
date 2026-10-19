# Ubuntu's ~/.profile sources this for sh login shells (T3 Code's `sh -lc`) and the desktop session.
# Same order as zsh/path.zsh; ~/.local/bin is re-added last to get ahead of Homebrew.
# shellcheck shell=sh
# `brew shellenv` without running brew. A leading colon has man search its default path too.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    export HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
    export HOMEBREW_CELLAR="$HOMEBREW_PREFIX/Cellar" HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX/Homebrew"
    PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$PATH"
    [ -z "${MANPATH-}" ] || export MANPATH=":${MANPATH#:}"
    export INFOPATH="$HOMEBREW_PREFIX/share/info:${INFOPATH:-}"
fi
PATH="$HOME/go/bin:$PATH"
PATH="$HOME/.cargo/bin:$PATH"
[ ! -d "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims" ] || PATH="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims:$PATH"
PATH="$HOME/.local/bin:$PATH"
