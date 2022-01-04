export ZSH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]:-${(%):-%x}}" )" &> /dev/null && pwd )

srcif() {
    [ -f "$1" ] && source "$1"
}

srczshif() {
    [ -f "$ZSH_DIR/$1" ] && source "$ZSH_DIR/$1"
}

isdarwin() {
    [[ `uname` == "Darwin" ]]
}

islinux() {
    [[ `uname` == "Linux" ]]
}

if isdarwin; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

USE_POWERLINE="true"

eval "$(starship init zsh)"

srczshif basic_settings.zsh
srczshif functions.zsh
srczshif aliases.zsh
srczshif options.zsh
srczshif history.zsh
srczshif key_bindings.zsh
srczshif completions.zsh
srczshif title.zsh
srczshif hooks.zsh
srczshif reminders.zsh
srczshif plugins.zsh
