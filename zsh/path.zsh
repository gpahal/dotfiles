# Stops Ubuntu's /etc/zsh/zshrc running a full compinit; basic-settings.zsh runs a cached one
skip_global_compinit=1

# Sourced twice (~/.zprofile on macOS or ~/.zshenv on Ubuntu, then main.zsh); -U drops the repeats
typeset -U path fpath

# A script inherits its parent's PATH, such as an activated venv's
[[ -o login || -o interactive || -z ${HOMEBREW_PREFIX:-} ]] || return 0

# `brew shellenv` without running brew, which is slow
if [[ -z ${HOMEBREW_PREFIX:-} ]]; then
    () {
        setopt local_options extended_glob
        local prefix
        for prefix in /opt/homebrew /home/linuxbrew/.linuxbrew; do
            [[ -x $prefix/bin/brew ]] || continue
            export HOMEBREW_PREFIX=$prefix HOMEBREW_CELLAR=$prefix/Cellar
            if [[ $OSTYPE == darwin* ]]; then
                export HOMEBREW_REPOSITORY=$prefix
            else
                export HOMEBREW_REPOSITORY=$prefix/Homebrew
            fi
            # A leading colon has man search its default path too
            [[ -z ${MANPATH-} ]] || export MANPATH=":${${MANPATH%%:##}##:##}"
            export INFOPATH="$prefix/share/info:${INFOPATH:-}"
            return
        done
    }
fi
# HOMEBREW_PREFIX may come from sh reading ~/.profile, which sets neither path nor fpath
if [[ -n ${HOMEBREW_PREFIX:-} ]]; then
    path=("$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/sbin" $path)
    fpath=("$HOMEBREW_PREFIX/share/zsh/site-functions" $fpath)
    export FPATH
fi
path=("$HOME/.cargo/bin" "$HOME/go/bin" $path)
path=("$HOME/.local/bin" "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims" $path)
