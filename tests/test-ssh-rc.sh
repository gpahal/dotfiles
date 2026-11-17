#!/bin/bash

# ssh/rc, which sshd runs on the Mac at the start of each SSH session: it holds caffeinate on the
# connection's sshd process, once per connection, prints nothing, and starts nothing without one.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RC="$REPO_DIR/ssh/rc"

# ps reads "<pid> <ppid> <comm>" lines from $SANDBOX/ps-table. Any other pid, such as rc's real
# parent, is a shell whose parent is 500.
stub ps 'table="$SANDBOX/ps-table"
pid="$4"
line="$(awk -v pid="$pid" '"'"'$1 == pid'"'"' "$table")"
[ -n "$line" ] || line="$pid 500 -zsh"
case "$2" in
    comm=) echo "$line" | cut -d " " -f 3- ;;
    ppid=) echo "  $(echo "$line" | cut -d " " -f 2)" ;;
    *) exit 1 ;;
esac'
# A caffeinate already running for a pid shows in $SANDBOX/running
stub pgrep 'grep -qx -- "${2%\$}" "$SANDBOX/running" 2> /dev/null'
stub caffeinate 'echo "$*" > "$SANDBOX/caffeinated"'

caffeinated() {
    [ -e "$SANDBOX/caffeinated" ]
}

# sshd-session above the shell sshd started
printf '%s\n' "500 400 /usr/libexec/sshd-session" "400 1 /usr/libexec/sshd-session" > "$SANDBOX/ps-table"
assert_exit 0 sh "$RC"
assert_eq "" "$RUN_OUTPUT" "rc's output"
wait_for caffeinated || fail "rc didn't start caffeinate"
assert_eq "-i -s -w 500" "$(cat "$SANDBOX/caffeinated" 2> /dev/null)" "caffeinate's arguments"

# A second session on the same connection starts no second caffeinate
rm "$SANDBOX/caffeinated"
echo "caffeinate -i -s -w 500" > "$SANDBOX/running"
assert_exit 0 sh "$RC"
sleep 0.3
caffeinated && fail "rc started a second caffeinate for the same connection"
rm "$SANDBOX/running"

# The process title sshd sets counts too
printf '%s\n' "500 400 sshd-session: me@ttys001" > "$SANDBOX/ps-table"
assert_exit 0 sh "$RC"
wait_for caffeinated || fail "rc didn't find sshd by its process title"
rm -f "$SANDBOX/caffeinated"

# Without sshd above it, nothing starts: caffeinate would never be released
printf '%s\n' "500 1 /sbin/launchd" > "$SANDBOX/ps-table"
assert_exit 0 sh "$RC"
assert_eq "" "$RUN_OUTPUT" "rc's output without sshd"
sleep 0.3
caffeinated && fail "rc started caffeinate without an sshd above it"
test_done
