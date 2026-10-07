# Drop duplicate entries, e.g. when nested shells or tmux panes re-run brew shellenv
typeset -U path fpath

export ZSH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]:-${(%):-%x}}" )" &> /dev/null && pwd )

srcif() {
    [ -f "$1" ] && source "$1"
}

srczshif() {
    [ -f "$ZSH_DIR/$1" ] && source "$ZSH_DIR/$1"
}

# ~/.zprofile sets up Homebrew for login shells; cover shells started without it
if [[ -z ${HOMEBREW_PREFIX:-} ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv zsh)"
fi

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
srczshif command-not-found.zsh

# zoxide and starship both ask to be initialized at the end of .zshrc; zoxide after compinit
if command -v zoxide &>/dev/null; then
    eval "$(zoxide init zsh)"
fi
eval "$(starship init zsh)"

# Per-machine settings, secrets and work-only aliases. Not part of the dotfiles repo.
srcif "$HOME/.zshrc.local"

# Load last, so it wraps the widgets every plugin above defines
_try_install_plugin zsh-syntax-highlighting
