# Colored GCC warnings and errors.
export GCC_COLORS="error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01"

export EDITOR="vim"
export VISUAL="vim"

export LANG="en_US.UTF-8"

# Turns off T3 Code's telemetry in the t3 CLI and in servers started from a shell. The macOS app
# reads it from the login shell too, and the t3-code step also sets it with a LaunchAgent:
# https://github.com/pingdotgg/t3code/blob/main/docs/user/telemetry.md
export T3CODE_TELEMETRY_ENABLED=false

# Completion and the zcalc calculator
autoload -U compinit zcalc
# The full compinit audits every completion directory, so run it at most once a day and reuse
# the dump in between. Also run it when Homebrew has linked or unlinked a completion since the
# dump, which changes the site-functions directory's mtime, so a tool installed today completes.
_zcompdump="${ZDOTDIR:-$HOME}/.zcompdump"
_zcompdump_fresh=( $_zcompdump(N.mh-24) )
if (( $#_zcompdump_fresh )) && [[ -s $_zcompdump ]] &&
    [[ -z ${HOMEBREW_PREFIX:-} || ! $HOMEBREW_PREFIX/share/zsh/site-functions -nt $_zcompdump ]]; then
    compinit -C
else
    # Skip insecure completion paths without prompting; an unattended shell can't answer.
    # Only refresh a successful dump, so an aborted initialization can't leave an empty cache.
    compinit -i && touch "$_zcompdump"
fi
unset _zcompdump _zcompdump_fresh

# Color man pages with bat. col -bx strips the overstrike formatting man emits; MANROFFOPT=-c
# keeps groff from emitting SGR escapes, as the bat README advises.
if command -v bat &>/dev/null; then
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
    export MANROFFOPT="-c"
fi
export LESS="-R"
