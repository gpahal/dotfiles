alias zshrc="$EDITOR $HOME/.zshrc"
alias reload='exec zsh'
alias path='print -l $path'

# Not eza: its -t takes an argument, which breaks ls -lt. GNU ls reads -G as --no-group.
if [[ $OSTYPE == darwin* ]]; then
    alias ls="ls -G"
else
    alias ls="ls --color=auto"
fi
if command -v eza &>/dev/null; then
    # A bare -F would take the next path as --classify's WHEN
    alias l="eza --classify=auto"
    alias la="eza -a --classify=auto"
    alias ll="eza -l --classify=auto"
    alias lla="eza -al --classify=auto"
    alias t="eza --tree -a -I .git"
else
    alias l="ls -F"
    alias la="ls -AF"
    alias ll="ls -lF"
    alias lla="ls -AlF"
fi

alias -- -='cd -'
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

alias lg="lazygit"
alias ts='tmux-sessionizer'

upgrade() {
    bash "${DOTFILES_DIR:-$HOME/Dev/setup/dotfiles}/scripts/upgrade.sh" "$@"
}
upgrade-ai-tools() {
    bash "${DOTFILES_DIR:-$HOME/Dev/setup/dotfiles}/scripts/upgrade.sh" ai-tools
}

alias bi="brew install"
alias uninstall="brew uninstall"
alias update="brew update"
alias cleanup="brew cleanup"
if [[ $OSTYPE == darwin* ]]; then
    alias update-macos="sudo softwareupdate -ia"
    alias flushdns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'
elif command -v resolvectl &>/dev/null; then
    alias flushdns='resolvectl flush-caches'
fi

alias today="date '+%A, %B %d, %Y'"
alias now="date '+%A, %B %d, %Y %H:%M:%S'"
alias dus="du -sckx * | sort -nr"
alias df="df -h"
# macOS top's flags; procps top on Linux takes others
[[ $OSTYPE == darwin* ]] && alias ttop="top -ocpu -R -F -s 2 -n30"

alias public-ip="curl -Ss https://icanhazip.com"
alias public-ip4="curl -Ss4 https://icanhazip.com/v4"
alias public-ip6="curl -Ss6 https://icanhazip.com/v6"

if command -v bat &>/dev/null; then
    # Not cat, so cat's flags (-v, -e, -t, -b) keep working
    alias c='bat -pp'
    alias findp="find . -exec bat {} +"
    alias fdp="fd -X bat"
    alias fzfp="fzf --preview 'bat --style=numbers --color=always --line-range :500 {}'"
else
    alias findp="find . -exec cat {} +"
    alias fdp="fd -X cat"
    alias fzfp="fzf --preview 'cat {}'"
fi
