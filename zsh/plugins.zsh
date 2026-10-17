# Source a plugin Homebrew installed, failing when it isn't there
_source_plugin() {
    [[ -n ${HOMEBREW_PREFIX:-} ]] || return 1
    local file="$HOMEBREW_PREFIX/share/$1/$1.zsh"
    [[ -f $file ]] || return 1
    source "$file"
    return 0
}

if _source_plugin zsh-autosuggestions
then
    ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=100
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
fi

# fzf: Ctrl-T (files) and Alt-C (directories). atuin, below, takes over Ctrl-R.
# The widgets read FZF_CTRL_T_* and FZF_ALT_C_* when they run, so setting them after the
# source line works. Without a terminal (e.g. `zsh -i -c` from a script) there's no line
# editor, and fzf's script warns twice that it can't change the zle option. $TTY is empty then;
# the zle option still reads as on, so it can't tell.
if [[ -n $TTY ]] && _cached_init fzf --zsh; then

    if command -v fd &>/dev/null; then
        export FZF_DEFAULT_COMMAND="fd --type f --hidden --exclude .git"
        export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
        export FZF_ALT_C_COMMAND="fd --type d --hidden --exclude .git"
    fi
    if command -v bat &>/dev/null; then
        export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always --line-range :300 {}'"
    fi
    if command -v eza &>/dev/null; then
        export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --color=always {}'"
    fi
fi

# atuin (better shell history): Ctrl-R and the Up arrow. --disable-ai leaves ? on an empty
# prompt as a plain ?, instead of opening Atuin AI. The init script depends on atuin's config too.
_cached_init -f ${ATUIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/atuin}/config.toml atuin init zsh --disable-ai

# mise (dev tool version manager: node, go, ...). Not cached: its output embeds the current PATH.
if command -v mise &>/dev/null; then
    # mise puts its tool dirs ahead of the PATH it saw at activation, so a CLI installed both ways
    # (claude with npm and natively) would resolve to mise's copy here and to ~/.local/bin's in
    # login shells. In its default (non-aggressive) mode, entries added after activation stay in
    # front at every prompt, so take ~/.local/bin out first and add it back after.
    path=(${path:#$HOME/.local/bin})
    eval "$(mise activate zsh)"
    path=("$HOME/.local/bin" $path)
fi
