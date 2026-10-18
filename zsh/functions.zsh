echotime() {
    date +"%R $*"
}

# Print each path made absolute, with symlinks resolved. Not dir, which would hide coreutils' dir
abspath() {
    local var
    for var in "$@"
    do
        readlink -f "$var"
    done
}

mcd() {
    [[ "$1" ]] && mkdir -p "$1" && cd "$1"
}

# Run the last command in history as root, showing it first. With hist_ignore_space, a line typed
# with a leading space never reaches history, so that may not be the last command typed.
please() {
    local c
    c="$(fc -ln -1)"
    print -r -- "sudo: $c"
    sudo zsh -c "$c"
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

# Open a path (default: the current directory) in its default app, e.g. Finder. Linux's xdg-open
# needs a desktop session, so it fails over SSH.
o() {
    if [[ $OSTYPE == darwin* ]]; then
        open "${@:-.}"
    else
        local target
        for target in "${@:-.}"; do
            xdg-open "$target"
        done
    fi
}

# cd to the folder of the frontmost Finder window. Asks for the front window's target, not
# Finder's insertion location, which falls back to the Desktop when no window is open.
if [[ $OSTYPE == darwin* ]]; then
    cdf() {
        local target
        target="$(osascript -e 'tell app "Finder" to if (count of Finder windows) > 0 then POSIX path of (target of front Finder window as alias)' 2>/dev/null)"
        if [[ -z "$target" ]]; then
            echo "cdf: no Finder window found" >&2
            return 1
        fi
        cd "$target"
    }
fi

# Start a shell in a new temp directory, and delete the directory when that shell exits.
# Based on wincent's scratch.
scratch() {
    local dir
    dir="$(mktemp -d)" || return
    echo "Scratch directory: $dir (deleted when this shell exits)"
    (cd "$dir" && "$SHELL")
    /bin/rm -rf "$dir"
}
