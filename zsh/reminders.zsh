# A tool reading the output would use up the oneshot reminders
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
