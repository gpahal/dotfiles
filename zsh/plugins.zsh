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

# Without a terminal fzf's script warns it can't set the zle option, which still reads as on
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

# --disable-ai: ? on an empty prompt stays a plain ?
_cached_init -f ${ATUIN_CONFIG_DIR:-${ATUIN_HOME:-$HOME/.atuin}}/config.toml atuin init zsh --disable-ai

# Not cached: the output embeds the current PATH
if command -v mise &>/dev/null; then
    # Keep ~/.local/bin ahead of mise's tools, as in login shells: entries added after
    # activation stay in front
    path=(${path:#$HOME/.local/bin})
    eval "$(mise activate zsh)"
    path=("$HOME/.local/bin" $path)
fi
