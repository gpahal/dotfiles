# Helpers for tests of the macos and ubuntu steps' status checks. Source after tests/lib.sh.
# shellcheck shell=bash

# One check, as status runs it, with status_result's exit code
diag() {
    "$@"
    status_result
}

# Fails if a check since the last call could prompt for sudo or changed something
read_only() {
    local log
    log="$(cat "$STUB_LOG")"
    assert_sudo_noninteractive
    if grep -qE '^systemctl ([^ ]+ )*(start|restart|try-restart|reload|enable|stop)( |$)|^fwupdmgr (refresh|update|install|upgrade)|^smartctl .*( -t | --test)|^docker ([^ ]+ )*(prune|stop|start|rm|kill)( |$)' <<< "$log"; then
        fail "status changed something:"
        _show "$log"
    fi
    : > "$STUB_LOG"
}

# df prints the first of these lines that names the path, else the first line. It fails for a
# path listed in $SANDBOX/df-fails.
df_lines() {
    printf '%s\n' "$@" > "$SANDBOX/df-table"
    : > "$SANDBOX/df-fails"
    stub df 'path="${!#}"
! grep -qxF -- "$path" "'"$SANDBOX"'/df-fails" || { echo "df: $path: No such file or directory" >&2; exit 1; }
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
line="$(grep -F " $path" "'"$SANDBOX"'/df-table" | head -n 1)"
[ -n "$line" ] || line="$(head -n 1 "'"$SANDBOX"'/df-table")"
echo "$line"'
}

# 1 GiB in df's 1024-byte blocks
# shellcheck disable=SC2034 # the tests read it
GIB=1048576
