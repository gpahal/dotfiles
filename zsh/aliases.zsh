alias zshrc="$EDITOR $HOME/.zshrc"
alias src="source $HOME/.zshrc"

if command -v eza 2>&1 >/dev/null; then
    alias ls="eza"
    alias l="eza -F"
    alias la="eza -aF"
    alias ll="eza -lF"
    alias lla="eza -alF"
elif isdarwin; then
    alias ls="ls -G"
    alias l="ls -GF"
    alias la="ls -GAF"
    alias ll="ls -GlF"
    alias lla="ls -GAlF"
else
    alias ls="ls --color=auto"
    alias l="ls --color=auto -F"
    alias la="ls --color=auto -AF"
    alias ll="ls --color=auto -lF"
    alias lla="ls --color=auto -AlF"
fi

alias /="cd /"
alias ~="cd $HOME"
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

alias quit="exit"
alias lg="lazygit"

upgrade() {
    if isdarwin; then
        brew update && brew upgrade
    else
        yay -Syu
    fi

    if command -v npm 2>&1 >/dev/null; then
        npm update -g
    fi

    if command -v pipx 2>&1 >/dev/null; then
        pipx upgrade-all
    fi
    
    if command -v rustup 2>&1 >/dev/null; then
        rustup update
    fi
}

if isdarwin; then
    alias install="brew install"
    alias uninstall="brew uninstall"
    alias update="brew update"
    alias cleanup="brew cleanup"
    alias update-osx="sudo softwareupdate -ia"
else
    alias install="yay -S"
    alias uninstall="yay -Rs"
    alias outdated="pacman -Qtd"
    alias uninstall-outdated="pacman -Qdtq | pacman -Rcns -"
fi

# Run last command as root
alias please='sudo $(fc -ln -1)'

alias today="date '+%A, %B %d, %Y'"
alias now="date '+%A, %B %d, %Y %H:%M:%S'"
alias dus="du -sckx * | sort -nr"
alias df="df -h"
alias bk="cd $OLDPWD"
alias ttop="top -ocpu -R -F -s 2 -n30"
alias rm="rm -i"
alias mv="mv -i"
alias tree="tree -a -I .git"

alias public-ip="curl -Ss icanhazip.com"
alias public-ip4="curl -Ss4 icanhazip.com/v4"
alias public-ip6="curl -Ss6 icanhazip.com/v6"

if command -v bat 2>&1 >/dev/null; then
    alias cat="bat"
    alias findp="find . -exec bat {} +"
    alias fdp="fd -X bat"
    alias fzfp="fzf --preview 'bat --style=numbers --color=always --line-range :500 {}'"
else
    alias findp="find . -exec cat {} +"
    alias fdp="fd -X cat"
    alias fzfp="fzf --preview 'cat {}'"
fi
