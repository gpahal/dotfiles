# Use powerline
USE_POWERLINE="true"

if [[ `uname` == "Darwin" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

eval "$(starship init zsh)"

# Load main.zsh
source $HOME/.zsh/main.zsh

# zsh aliases
alias zshrc="$EDITOR $HOME/.zshrc"
alias src="source $HOME/.zshrc"
