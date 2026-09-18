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

# Update AI tools that the package manager upgrades miss
upgrade-ai-tools() {
    # Claude Code native install (~/.local/share/claude) updates itself
    if command -v claude &>/dev/null && [[ "${$(command -v claude):A}" == "$HOME/.local/share/claude/"* ]]; then
        claude update
    fi

    # CLIs installed with npm: `npm update -g` stays within the installed semver range,
    # which for 0.x versions (Codex) never reaches a new minor release
    if command -v npm &>/dev/null; then
        local pkg
        for pkg in @openai/codex @anthropic-ai/claude-code; do
            if npm ls -g --depth=0 "$pkg" &>/dev/null; then
                npm install -g "$pkg@latest"
            fi
        done
    fi

    # Desktop apps installed with brew auto-update themselves, so `brew upgrade` skips them
    # unless asked with --greedy. Replacing a running app breaks it, so skip running apps.
    if isdarwin; then
        local cask app
        for cask app in claude Claude chatgpt ChatGPT; do
            brew list --cask "$cask" &>/dev/null || continue
            [[ -n "$(brew outdated --cask --greedy --quiet "$cask" 2>/dev/null)" ]] || continue
            if pgrep -x "$app" &>/dev/null; then
                echo "$app is running; quit it and run upgrade again to update it."
            else
                brew upgrade --cask --greedy "$cask"
            fi
        done
    fi

    # Plugins are separate from the CLIs above. Claude Code has no update-all, so update
    # each installed plugin in the scope it was installed in. Updates apply on next start.
    if command -v claude &>/dev/null; then
        claude plugin marketplace update
        local id scope
        claude plugin list --json | jq -r '.[] | "\(.id)\t\(.scope)"' | while IFS=$'\t' read -r id scope; do
            claude plugin update "$id" --scope "$scope"
        done
    fi

    # Codex's bundled marketplaces ship with the CLI and update with it. With no name,
    # this refreshes any Git marketplace added on top of them.
    if command -v codex &>/dev/null; then
        codex plugin marketplace upgrade
    fi
}

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

    upgrade-ai-tools
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
