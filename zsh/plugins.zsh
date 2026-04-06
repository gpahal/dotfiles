export ZSH_PLUGIN_DIR="$ZSH_DIR/plugins"

if isdarwin; then
    export ZSH_GLOBAL_PLUGIN_DIR="/opt/homebrew/share"
else
    export ZSH_GLOBAL_PLUGIN_DIR="/usr/share/zsh/plugins"
fi

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

# Use syntax highlighting
_try_install_plugin zsh-syntax-highlighting

# Use auto suggestions
if _try_install_plugin zsh-autosuggestions
then
    ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
fi

# fzf integration
source <(fzf --zsh)

if command -v fd 2>&1 >/dev/null; then
    export FZF_DEFAULT_COMMAND="fd --type f --hidden --exclude .git"
fi

# zoxide (smarter cd)
if command -v zoxide 2>&1 >/dev/null; then
    eval "$(zoxide init zsh)"
fi

# atuin (better shell history)
if command -v atuin 2>&1 >/dev/null; then
    eval "$(atuin init zsh)"
fi
