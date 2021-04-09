echotime() {
    date +"%R $*"
}

dir() {
    for var in "$@"
    do
        readlink -f $var
    done
}

mcd() {
    [[ "$1" ]] && mkdir -p "$1" && cd "$1"
}
