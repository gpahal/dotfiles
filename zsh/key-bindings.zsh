# Keybindings
bindkey -e
bindkey '^[[7~' beginning-of-line                               # Home key
bindkey '^[[H' beginning-of-line                                # Home key
if [[ "${terminfo[khome]}" != "" ]]; then
    bindkey "${terminfo[khome]}" beginning-of-line              # [Home] - Go to beginning of line
fi
bindkey '^[[8~' end-of-line                                     # End key
bindkey '^[[F' end-of-line                                      # End key
if [[ "${terminfo[kend]}" != "" ]]; then
    bindkey "${terminfo[kend]}" end-of-line                     # [End] - Go to end of line
fi
bindkey '^[[2~' overwrite-mode                                  # Insert key
bindkey '^[[3~' delete-char                                     # Delete key
bindkey '^[[C'  forward-char                                    # Right key
bindkey '^[[D'  backward-char                                   # Left key
bindkey '^[[5~' history-beginning-search-backward               # Page up key
bindkey '^[[6~' history-beginning-search-forward                # Page down key

# Navigate words with ctrl+arrow keys
bindkey '^[Oc' forward-word
bindkey '^[Od' backward-word
bindkey '^[[1;5D' backward-word
bindkey '^[[1;5C' forward-word
# Ctrl+Backspace deletes a word, and Shift+Tab undoes
bindkey '^H' backward-kill-word
bindkey '^[[Z' undo

# Ctrl-X Ctrl-E: edit the current command in $EDITOR
autoload -U edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line

# Space expands history references such as !! and !$ inline
bindkey ' ' magic-space

# Ctrl-Z: on an empty line, resume the last suspended job; otherwise park the line until the next
# prompt. Based on wincent's zshrc.
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

# Ctrl-Q: park the line and restore it after the next command. At a PS2 prompt, pull the whole
# multi-line construct back into the buffer to edit instead.
# Needs no_flow_control (options.zsh), or the terminal takes Ctrl-Q as XON.
bindkey '^Q' push-line-or-edit
