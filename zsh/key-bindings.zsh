bindkey -e
bindkey '^[[H' beginning-of-line
if [[ "${terminfo[khome]}" != "" ]]; then
    bindkey "${terminfo[khome]}" beginning-of-line
fi
bindkey '^[[F' end-of-line
if [[ "${terminfo[kend]}" != "" ]]; then
    bindkey "${terminfo[kend]}" end-of-line
fi
bindkey '^[[2~' overwrite-mode                                  # Insert
bindkey '^[[3~' delete-char                                     # Delete
bindkey '^[[5~' history-beginning-search-backward               # Page up
bindkey '^[[6~' history-beginning-search-forward                # Page down

bindkey '^[[1;5D' backward-word
bindkey '^[[1;5C' forward-word
bindkey '^H' backward-kill-word
bindkey '^[[Z' undo

autoload -U edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line

bindkey ' ' magic-space

# Ctrl-Z on an empty line resumes the last job
_fg_or_push() {
    if [[ $#BUFFER -eq 0 ]]; then
        BUFFER=fg
        zle accept-line
    else
        zle push-input
    fi
}
zle -N _fg_or_push
bindkey '^Z' _fg_or_push

# Needs no_flow_control (options.zsh), or the terminal takes Ctrl-Q as XON
bindkey '^Q' push-line-or-edit
