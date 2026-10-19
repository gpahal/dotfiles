export GCC_COLORS="error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01"

export EDITOR="vim"
export VISUAL="vim"

export LANG="en_US.UTF-8"

export T3CODE_TELEMETRY_ENABLED=false

autoload -U compinit zcalc
# Full compinit is slow: run it once a day, or when Homebrew's site-functions changed since the dump
_zcompdump="${ZDOTDIR:-$HOME}/.zcompdump"
_zcompdump_fresh=( $_zcompdump(N.mh-24) )
if (( $#_zcompdump_fresh )) && [[ -s $_zcompdump ]] &&
    [[ -z ${HOMEBREW_PREFIX:-} || ! $HOMEBREW_PREFIX/share/zsh/site-functions -nt $_zcompdump ]]; then
    compinit -C
else
    # -i: an unattended shell can't answer the insecure-path prompt
    compinit -i && touch "$_zcompdump"
fi
unset _zcompdump _zcompdump_fresh

# MANROFFOPT=-c keeps groff from emitting SGR escapes, per bat's README
if command -v bat &>/dev/null; then
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
    export MANROFFOPT="-c"
fi
export LESS="-R"
