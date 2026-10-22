# Error counting and a temp dir for the check scripts. Source it; don't run it.
# shellcheck shell=bash

errors=0

# Reports a problem and carries on; the script ends with [ "$errors" -eq 0 ]
fail() {
    echo "$1" >&2
    errors=$((errors + 1))
}

# Sets tmp to a new dir, removed on exit
make_tmp() {
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
}
