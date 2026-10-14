# Only in a terminal you're looking at. Tools that read a shell's output source this file too:
# T3 Code's server probes PATH with `$SHELL -ilc`, and Claude Code snapshots the shell config. Each
# would print the reminders into its output and use up the oneshot ones.
if [[ -o interactive && -t 1 && -z ${CLAUDECODE:-} ]]; then
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
