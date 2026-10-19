echotime() {
    date +"%R $*"
}

# Not named dir, which would hide coreutils' dir
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

# please reruns the previous line as root. A zshaddhistory hook records lines as typed, since
# history can't: share_history mixes in other shells, hist_ignore_space drops lines, fc -n mangles \n.
# `function` keyword: a shell still holding the old please alias would mangle `please()`.
function _please_addhistory {
    local line=${1%$'\n'}
    local -a words=(${(z)line})
    # 0 keeps the line in history
    (( $#words )) || return 0
    if [[ $words[1] == please ]]; then
        typeset -g _please_skipped=1
    else
        typeset -g _please_skipped= _please_prev=${_please_line-} _please_line=$line
    fi
    return 0
}
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

g() {
    if (( $# )); then
        git "$@"
    else
        git status -sb
    fi
}
compdef g=git

port() {
    if [[ -z "$1" ]]; then
        echo "usage: port <number>" >&2
        return 1
    fi
    lsof -nP -iTCP:"$1" -sTCP:LISTEN
}

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

# Not Finder's insertion location, which falls back to the Desktop with no window open
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

scratch() {
    local dir
    dir="$(mktemp -d)" || return
    echo "Scratch directory: $dir (deleted when this shell exits)"
    (cd "$dir" && "$SHELL")
    /bin/rm -rf "$dir"
}
