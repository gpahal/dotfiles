# Colored GCC warnings and errors.
export GCC_COLORS="error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01"

export EDITOR="vim"
export VISUAL="vim"

# Put ~/.bin, ~/.local/bin, and the `cargo install` and `go install` bin directories first. Homebrew's own directories come
# from brew shellenv, ahead of /usr/local/bin.
# Assigning to the path array (not `export PATH=...`) applies main.zsh's typeset -U, which also
# drops duplicates added earlier, e.g. by brew shellenv in nested shells.
path=("$HOME/.bin" "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/go/bin" $path)

export LANG="en_US.UTF-8"

# Completion, color names, and the zcalc calculator
autoload -U compinit colors zcalc
# The full compinit audits every completion directory, so run it at most once a day and reuse
# the dump in between
_zcompdump_fresh=( "${ZDOTDIR:-$HOME}"/.zcompdump(N.mh-24) )
if (( $#_zcompdump_fresh )); then
    compinit -C
else
    compinit
    touch "${ZDOTDIR:-$HOME}/.zcompdump"
fi
unset _zcompdump_fresh
colors

# Color man pages with bat. col -bx strips the overstrike formatting man emits; MANROFFOPT=-c
# keeps groff from emitting SGR escapes, as the bat README advises.
if command -v bat &>/dev/null; then
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
    export MANROFFOPT="-c"
fi
export LESS="-R"
