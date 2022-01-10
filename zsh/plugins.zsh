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

# Use history substring search
if _try_install_plugin zsh-history-substring-search
then
    zmodload zsh/terminfo

    bindkey "$terminfo[kcuu1]" history-substring-search-up
    bindkey "$terminfo[kcud1]" history-substring-search-down
    bindkey '^[[A' history-substring-search-up
    bindkey '^[[B' history-substring-search-down
fi

if [ -f "$ZSH_PLUGIN_DIR/fzf/key-bindings.zsh" ]
then
    source "$ZSH_PLUGIN_DIR/fzf/key-bindings.zsh"
    srcif "$ZSH_PLUGIN_DIR/fzf/completion.zsh"
elif [ -f "/usr/share/fzf/key-bindings.zsh" ]
then
    source "/usr/share/fzf/key-bindings.zsh"
    srcif "/usr/share/fzf/completion.zsh"
elif [ -f "/opt/homebrew/opt/fzf/shell/key-bindings.zsh" ]
then
    if [[ ! "$PATH" == */opt/homebrew/opt/fzf/bin* ]]; then
        export PATH="${PATH:+${PATH}:}/opt/homebrew/opt/fzf/bin"
    fi
    source "/opt/homebrew/opt/fzf/shell/key-bindings.zsh"
    srcif "/opt/homebrew/opt/fzf/shell/completion.zsh"
fi

if hash fd; then
    export FZF_DEFAULT_COMMAND="fd --type f --hidden --exclude .git"
fi
