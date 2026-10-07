if [ -f $HOME/.remind ]; then
    cat $HOME/.remind
fi

if [ -f $HOME/.remind-oneshot ]; then
    cat $HOME/.remind-oneshot
    rm $HOME/.remind-oneshot
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
