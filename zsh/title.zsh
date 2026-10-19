# A dumb terminal would print the sequence
_title_precmd() {
    [[ $TERM == dumb ]] || print -Pn '\e]2;%~\a'
}

_title_preexec() {
    # hist_ignore_space hides it, so hide it here too
    [[ $1 == ' '* ]] && return
    # Control characters would end the sequence early
    [[ $TERM == dumb ]] || print -rn -- $'\e]2;'"${${1//[[:cntrl:]]/ }[1,100]}"$'\a'
}

add-zsh-hook precmd _title_precmd
add-zsh-hook preexec _title_preexec
