echotime() {
    date +"%R $*"
}

dir() {
    local var
    for var in "$@"
    do
        readlink -f "$var"
    done
}

mcd() {
    [[ "$1" ]] && mkdir -p "$1" && cd "$1"
}

# git with no arguments shows a short status
g() {
    if (( $# )); then
        git "$@"
    else
        git status -sb
    fi
}
compdef g=git

# Show what's listening on a TCP port
port() {
    if [[ -z "$1" ]]; then
        echo "usage: port <number>" >&2
        return 1
    fi
    lsof -nP -iTCP:"$1" -sTCP:LISTEN
}

# Kill whatever is listening on a TCP port
killport() {
    if [[ -z "$1" ]]; then
        echo "usage: killport <number>" >&2
        return 1
    fi
    local -a pids
    pids=( ${(f)"$(lsof -ti tcp:"$1" -sTCP:LISTEN)"} )
    if (( ! $#pids )); then
        echo "nothing listening on :$1"
        return 0
    fi
    kill "${pids[@]}" && echo "killed ${pids[*]} (listening on :$1)"
}

# Open a path (default: the current directory) in its default app, e.g. Finder
o() {
    open "${@:-.}"
}

# cd to the folder of the frontmost Finder window. Asks for the front window's target, not
# Finder's insertion location, which falls back to the Desktop when no window is open.
cdf() {
    local target
    target="$(osascript -e 'tell app "Finder" to if (count of Finder windows) > 0 then POSIX path of (target of front Finder window as alias)' 2>/dev/null)"
    if [[ -z "$target" ]]; then
        echo "cdf: no Finder window found" >&2
        return 1
    fi
    cd "$target"
}

# Start a shell in a new temp directory, and delete the directory when that shell exits.
# Based on wincent's scratch.
scratch() {
    local dir
    dir="$(mktemp -d)" || return
    echo "Scratch directory: $dir (deleted when this shell exits)"
    (cd "$dir" && "$SHELL")
    /bin/rm -rf "$dir"
}
