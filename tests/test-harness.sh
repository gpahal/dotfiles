#!/bin/bash

# tests/lib.sh's own checks: assert_idempotent, assert_read_only, the df table, and
# stub_sudo_exec's refusals.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Usage: fails <assertion> <args>...: succeeds when the assertion fails the test, keeping its
# message in $FAILED_WITH. A passing assertion runs as itself.
fails() {
    local count
    count="$(
        TEST_FAILURES=0
        "$@" > /dev/null 2> "$SANDBOX/failed-with"
        echo "$TEST_FAILURES"
    )"
    FAILED_WITH="$(cat "$SANDBOX/failed-with")"
    rm -f "$SANDBOX/failed-with"
    [ "$count" -gt 0 ]
}

stub pkill
stub_sudo_exec
mkdir -p "$HOME/app"
echo kept > "$HOME/app/config"

# --- assert_idempotent ---
# Each counts its runs in $SANDBOX/runs, which the --ignore below covers
counted() {
    echo x >> "$SANDBOX/runs"
    wc -l < "$SANDBOX/runs" | tr -d ' '
}
set_up_once() {
    [ -e "$HOME/app/state" ] || echo set > "$HOME/app/state"
    echo "done"
}
# Rewriting a file with the same content, or a temp file it removes, changes nothing
rewrite_same() {
    echo kept > "$HOME/app/config.new"
    mv "$HOME/app/config.new" "$HOME/app/config"
    rm "$(mktemp)"
}
changes_on_second() {
    [ "$(counted)" -lt 2 ] || echo changed > "$HOME/app/config"
}
adds_on_second() {
    [ "$(counted)" -lt 2 ] || touch "$HOME/app/new"
}
leaks_temp_file() {
    mktemp > /dev/null
}
chmods_on_second() {
    [ "$(counted)" -lt 2 ] || chmod 600 "$HOME/app/config"
}
reloads_each_run() {
    pkill -USR2 -x app
}
sudo_writes_each_run() {
    echo kept | sudo tee "$HOME/app/config" > /dev/null
}
fails_second() {
    [ "$(counted)" -lt 2 ]
}

assert_idempotent set_up_once
assert_eq "done" "$RUN_OUTPUT" "assert_idempotent's output"
assert_eq "done" "$FIRST_OUTPUT" "assert_idempotent's first output"
assert_idempotent rewrite_same
for changes in changes_on_second adds_on_second leaks_temp_file chmods_on_second; do
    rm -f "$SANDBOX/runs"
    fails assert_idempotent --ignore "$SANDBOX/runs" "$changes" ||
        fail "assert_idempotent passed $changes"
    assert_contains "$FAILED_WITH" "changed the sandbox" "assert_idempotent's message for $changes"
    echo kept > "$HOME/app/config"
    chmod 644 "$HOME/app/config"
    rm -f "$HOME/app/new"
done
rm -f "$SANDBOX/runs"
fails assert_idempotent --ignore "$SANDBOX/runs" fails_second || fail "assert_idempotent passed a failed second run"
fails assert_idempotent reloads_each_run || fail "assert_idempotent passed a second run that ran pkill"
assert_contains "$FAILED_WITH" "pkill -USR2 -x app"
fails assert_idempotent sudo_writes_each_run || fail "assert_idempotent passed a second run that ran sudo tee"
# A file that changes on every run fails it unless ignored, and ignoring it hides nothing else
rm -f "$SANDBOX/runs"
fails assert_idempotent counted || fail "assert_idempotent passed a log written on every run"
assert_idempotent --ignore "$SANDBOX/runs" counted
fails assert_idempotent --ignore "$SANDBOX/run" counted || fail "assert_idempotent ignored a path that only starts like one"
rm -f "$SANDBOX/runs"
fails assert_idempotent --ignore "$SANDBOX/runs" changes_on_second ||
    fail "assert_idempotent passed a change beside an ignored file"
echo kept > "$HOME/app/config"
# A file the test can't read still counts, by its mode
mkdir -p "$SANDBOX/secret"
echo hidden > "$SANDBOX/secret/file"
chmod 000 "$SANDBOX/secret/file"
if [ ! -r "$SANDBOX/secret/file" ]; then
    assert_idempotent set_up_once
    unreadable_gone_on_second() {
        [ "$(counted)" -lt 2 ] || rm -f "$SANDBOX/secret/file"
    }
    rm -f "$SANDBOX/runs"
    fails assert_idempotent --ignore "$SANDBOX/runs" unreadable_gone_on_second ||
        fail "assert_idempotent missed an unreadable file going"
fi
rm -rf "$SANDBOX/secret"

# --- assert_read_only ---
stub_sudo_cacheable
cache_sudo yes
reads() {
    sudo -n cat "$HOME/app/config"
    systemctl is-active --quiet docker.service
    return 3
}
starts() {
    systemctl --user start app.service
}
prompts() {
    sudo cat "$HOME/app/config"
}
sudo_writes() {
    echo x | sudo -n tee "$HOME/app/other" > /dev/null
}
stub systemctl
assert_read_only 3 reads
assert_eq kept "$RUN_OUTPUT" "assert_read_only's output"
fails assert_read_only 0 reads || fail "assert_read_only passed the wrong exit"
fails assert_read_only 0 starts || fail "assert_read_only passed systemctl start"
assert_contains "$FAILED_WITH" "systemctl --user start app.service"
fails assert_read_only 0 prompts || fail "assert_read_only passed a sudo that could prompt"
fails assert_read_only 0 sudo_writes || fail "assert_read_only passed sudo -n tee"

# --- the sandbox's df: $SANDBOX/df-table's line for a path, else its first; df-fails lists paths
# it can't read ---
assert_exit 0 df -P -k /home
assert_contains "$RUN_OUTPUT" "/dev/test 1048576000 104857600 943718400 10% /home"
printf '%s\n' "/dev/sda2 500 380 120 76% /" "/dev/sdb1 900 100 800 12% /home" > "$SANDBOX/df-table"
assert_exit 0 df -P -k /home
assert_eq "Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/sdb1 900 100 800 12% /home" "$RUN_OUTPUT" "df's output for a listed path"
assert_exit 0 df -P -k /elsewhere
assert_contains "$RUN_OUTPUT" "/dev/sda2 500 380 120 76% /"
echo /gone > "$SANDBOX/df-fails"
assert_exit 1 df -P -k /gone

# --- stub_sudo_exec: the refused commands name a missing repo dir, so they'd fail even if run ---
stub_sudo_exec
echo hi > "$SANDBOX/file"
gone="$REPO_DIR/no-such-dir/file"
assert_exit 1 sudo install -m 0644 "$SANDBOX/file" "$gone"
assert_contains "$RUN_OUTPUT" "refused: install would change $gone, in the repo"
assert_exit 1 sudo cat /etc/hosts
assert_contains "$RUN_OUTPUT" "refused: /etc/hosts is outside the sandbox"
test_done
