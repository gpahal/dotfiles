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

# Run the line typed before this one as root, showing it first. A zshaddhistory hook keeps the
# lines as typed, since history can't give them: share_history puts other shells' commands there,
# hist_ignore_space leaves a line out, and fc -n prints a newline as \n, which zsh -c reads as n.
# The hook sees every line, also one zsh doesn't run, such as a parse error or a comment, so please
# never reaches past it to an older command. A line that starts with please doesn't count, so a
# second please runs the same command, and please after another command on its line runs the line
# before. The function keyword, since please was once an alias: a shell that still has it would
# expand `please()` into a parse error on re-sourcing, and stop loading this file.
function _please_addhistory {
    local line=${1%$'\n'}
    local -a words=(${(z)line})
    # 0 keeps the line in history, as without the hook
    (( $#words )) || return 0
    if [[ $words[1] == please ]]; then
        typeset -g _please_skipped=1
    else
        typeset -g _please_skipped= _please_prev=${_please_line-} _please_line=$line
    fi
    return 0
}
autoload -U add-zsh-hook
add-zsh-hook zshaddhistory _please_addhistory

function please {
    local c
    if [[ -n ${_please_skipped-} ]]; then
        c=${_please_line-}
    else
        c=${_please_prev-}
    fi
    if [[ -z $c ]]; then
        print -u2 "please: no earlier command in this shell"
        return 1
    fi
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
