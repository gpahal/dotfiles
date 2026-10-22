# The runners' default steps on either OS, for the docs check. Source it; don't run it.
# shellcheck shell=bash

# Write a uname into dir $1 whose -s reports $2 (Darwin or Linux).
os_uname_shim() {
    mkdir -p "$1"
    # shellcheck disable=SC2016 # expanded by the shim
    printf '#!/bin/sh\n[ "$1" = -s ] && { echo %s; exit 0; }\nexec /usr/bin/uname "$@"\n' "$2" > "$1/uname"
    chmod +x "$1/uname"
}

# Print a runner's default steps on OS $2, one per line, from its --help.
runner_steps() {
    local dir status=0
    dir="$(mktemp -d)" || return 1
    os_uname_shim "$dir" "$2"
    PATH="$dir:$PATH" "$BASH" "$1" --help > "$dir/help" 2>&1 || status=$?
    sed -n 's/^Steps, run in this order by default: //p' "$dir/help" | tr ' ' '\n'
    rm -rf "$dir"
    return "$status"
}
