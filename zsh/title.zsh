# Set the terminal's title with OSC 2: the current directory at the prompt, and the command line
# while it runs. tmux shows it as the pane title (#T), which tmux.conf passes on to the terminal.
# A dumb terminal, such as an editor's shell, would print the sequence.
_title_precmd() {
    [[ $TERM == dumb ]] || print -Pn '\e]2;%~\a'
}

_title_preexec() {
    # A leading space keeps a command out of history (hist_ignore_space), so out of the title too
    [[ $1 == ' '* ]] && return
    # Control characters, such as a newline in a multi-line command, would end the sequence early
    [[ $TERM == dumb ]] || print -rn -- $'\e]2;'"${${1//[[:cntrl:]]/ }[1,100]}"$'\a'
}

autoload -U add-zsh-hook
add-zsh-hook precmd _title_precmd
add-zsh-hook preexec _title_preexec
