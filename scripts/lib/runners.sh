# shellcheck shell=bash
# The readers of the runners' default steps that scripts/check-docs.sh and tests/test-run-steps.sh
# share. It only defines functions.

# Write a uname into dir $1 that reports OS $2 (Darwin or Linux) for -s and runs the real one
# otherwise, so a script run with the dir first on PATH acts as on that OS
# e.g. os_uname_shim "$tmp/Linux" Linux
os_uname_shim() {
    mkdir -p "$1"
    # shellcheck disable=SC2016 # expanded by the shim
    printf '#!/bin/sh\n[ "$1" = -s ] && { echo %s; exit 0; }\nexec /usr/bin/uname "$@"\n' "$2" > "$1/uname"
    chmod +x "$1/uname"
}

# Print a runner's default steps on an OS (Darwin or Linux), one per line, from its --help, and
# fail when --help does. Both OSes' lists come from one machine, through os_uname_shim.
# e.g. runner_steps "$REPO_DIR/setup.sh" Linux
runner_steps() {
    local dir status=0
    dir="$(mktemp -d)" || return 1
    os_uname_shim "$dir" "$2"
    PATH="$dir:$PATH" "$BASH" "$1" --help > "$dir/help" 2>&1 || status=$?
    sed -n 's/^Steps, run in this order by default: //p' "$dir/help" | tr ' ' '\n'
    rm -rf "$dir"
    return "$status"
}
