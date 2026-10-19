# Only in a terminal you're looking at, which options.zsh sets _human_tty for. Tools that read a
# shell's output would print the reminders into it and use up the oneshot ones.
if [[ -o interactive && -n ${_human_tty:-} ]]; then
    if [ -f $HOME/.remind ]; then
        command cat $HOME/.remind
    fi

    if [ -f $HOME/.remind-oneshot ]; then
        command cat $HOME/.remind-oneshot
        rm $HOME/.remind-oneshot
    fi
fi

remind() {
    if [ "$1" ]; then
        echo "$@" >> $HOME/.remind
    else
        $EDITOR $HOME/.remind
    fi
}

remind-oneshot() {
    if [ "$1" ]; then
        echo "$@" >> $HOME/.remind-oneshot
    else
        $EDITOR $HOME/.remind-oneshot
    fi
}
