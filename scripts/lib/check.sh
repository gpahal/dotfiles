# Error counting, a temp dir, and the made-up-name check for the check scripts. Source it; don't run it.
# shellcheck shell=bash

errors=0

# Reports a problem and carries on; the script fails at the end when errors > 0
fail() {
    echo "$1" >&2
    errors=$((errors + 1))
}

# Sets tmp to a new dir, removed on exit
make_tmp() {
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
}

# missing_names <search> <kind> <made-up name> <found-fn> [name...]: sets MISSING to the names,
# each after a space, that found-fn doesn't find. A search that finds the made-up name can't fail,
# so that counts as an error.
missing_names() {
    local search="$1" kind="$2" made_up="$3" found="$4" name
    shift 4
    MISSING=""
    for name in "$@" "$made_up"; do
        "$found" "$name" || MISSING="$MISSING $name"
    done
    case "$MISSING" in
        *" $made_up") MISSING="${MISSING% "$made_up"}" ;;
        *) fail "the search $search found a made-up $kind, so it can't check the real ones" ;;
    esac
}

# Ends the script, failing when any check did
finish_checks() {
    if [ "$errors" -gt 0 ]; then
        echo "$errors check(s) failed" >&2
        exit 1
    fi
    echo "All checks passed"
}
