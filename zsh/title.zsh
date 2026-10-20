# A dumb terminal would print the sequence
_title_precmd() {
    [[ $TERM == dumb ]] || print -Pn '\e]2;%~\a'
}

# On Linux the folder follows the command, since the Stream Deck's open-in reads it from the title;
# on macOS it asks Ghostty instead
_title_preexec() {
    # hist_ignore_space hides it, so hide it here too
    [[ $1 == ' '* ]] && return
    [[ $TERM == dumb ]] && return
    # Control characters would end the sequence early
    print -rn -- $'\e]2;'"${${1//[[:cntrl:]]/ }[1,100]}"
    [[ $OSTYPE == linux* ]] && print -Pn ' — %~'
    print -n '\a'
}

add-zsh-hook precmd _title_precmd
add-zsh-hook preexec _title_preexec
