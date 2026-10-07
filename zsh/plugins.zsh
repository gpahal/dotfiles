export ZSH_PLUGIN_DIR="$ZSH_DIR/plugins"

export ZSH_GLOBAL_PLUGIN_DIR="/opt/homebrew/share"

_try_install_plugin() {
    if [ -f "$ZSH_PLUGIN_DIR/$1/$1.zsh" ]
    then
        source "$ZSH_PLUGIN_DIR/$1/$1.zsh"
        return 0
    elif [ -f "$ZSH_GLOBAL_PLUGIN_DIR/$1/$1.zsh" ]
    then
        source "$ZSH_GLOBAL_PLUGIN_DIR/$1/$1.zsh"
        return 0
    else
        return 1
    fi
}

if _try_install_plugin zsh-autosuggestions
then
    ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
fi

# fzf: Ctrl-T (files) and Alt-C (directories). atuin, below, takes over Ctrl-R.
# The widgets read FZF_CTRL_T_* and FZF_ALT_C_* when they run, so setting them after the
# source line works.
if command -v fzf &>/dev/null; then
    source <(fzf --zsh)

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

# atuin (better shell history): Ctrl-R and the Up arrow
if command -v atuin &>/dev/null; then
    eval "$(atuin init zsh)"
fi

# mise (dev tool version manager: node, go, ...)
if command -v mise &>/dev/null; then
    eval "$(mise activate zsh)"
fi
