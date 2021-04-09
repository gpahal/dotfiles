alias ls="ls --color=auto"
alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"

alias /="cd /"
alias ~="cd $HOME"
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

alias bounce-swap="sudo swapoff -a && sleep 10 && sudo swapon -a"
alias quit="exit"

if [[ `uname` == "Darwin" ]]; then
    alias update="brew update"
    alias upgrade="brew update && brew upgrade"
    alias cleanup="brew cleanup"
    alias update-osx="sudo softwareupdate -ia"
else
    alias upgrade="yay -Syu"
    alias install="yay -S"
    alias uninstall="yay -Rs"
    alias outdated="pacman -Qtd"
    alias uninstall-outdated="pacman -Qdtq | pacman -Rcns -"
fi

# Run last command as root
alias please="/usr/bin/sudo $(history -p !!)"

alias today="calendar -A 0 -f /usr/share/calendar/calendar.mark | sort"
alias dus="du -sckx * | sort -nr"
alias df="df -h"
alias bk="cd $OLDPWD"
alias ttop="top -ocpu -R -F -s 2 -n30"
alias rm="rm -i"
alias mv="mv -i"
alias tree="tree -a -I .git"
alias free="free -m"

alias public-ip="curl -Ss icanhazip.com"
alias public-ip4="curl -Ss4 icanhazip.com/v4"
alias public-ip6="curl -Ss6 icanhazip.com/v6"
