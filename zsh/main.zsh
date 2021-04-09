srcif() {
    [ -f "$1" ] && source "$1"
}

export ZSH_DIR="$HOME/.zsh"

srczshif() {
    [ -f "$ZSH_DIR/$1" ] && source "$ZSH_DIR/$1"
}

srczshif basic-settings.zsh
srczshif functions.zsh
srczshif aliases.zsh
srczshif options.zsh
srczshif history.zsh
srczshif key-bindings.zsh
srczshif completions.zsh
srczshif title.zsh
srczshif hooks.zsh
srczshif reminders.zsh
srczshif plugins.zsh

srczshif private.zsh
