# PATH for sh login shells and the desktop session on Ubuntu, whose ~/.profile sources this file.
# T3 Code's SSH connections check for claude and codex with `sh -lc`, and apps opened from the
# dock, such as Zed's language servers, start from the desktop session. Add Homebrew, where codex
# lives, Go's and Cargo's dirs, and mise's shims, once mise has made them, for its Node and Go.
# Ubuntu's ~/.profile adds ~/.local/bin before sourcing this, which would leave it behind
# Homebrew, so add it again last: the same order as zsh/path.zsh. Each dir goes in front even when
# PATH has it, as the PATH systemd gives the desktop session does. A login sh started from another
# one adds them again, which leaves their order as it was.
# shellcheck shell=sh
# Homebrew's environment, as `brew shellenv sh` prints it, set without running brew, which would
# slow every login. A leading colon on MANPATH has man search its default path too.
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
