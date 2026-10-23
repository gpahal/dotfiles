#!/bin/bash
set -euo pipefail
# serial

# lib/common.sh's confirm, regex_escape, version_at_least, run_bounded, and quitting a running app
# to merge its settings, and stub_sudo_exec's refusals.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

# --- confirm and DOTFILES_ASSUME_YES ---
assert_exit 1 confirm "Proceed?"
export DOTFILES_ASSUME_YES=1
stub systemd-detect-virt
assert_exit 0 confirm "Proceed?"
assert_eq "Proceed? yes (DOTFILES_ASSUME_YES)" "$RUN_OUTPUT" "confirm's output"
DOTFILES_ASSUME_YES=0
assert_exit 1 confirm "Proceed?"
# Off a VM, so an export on a real machine approves nothing
DOTFILES_ASSUME_YES=1
stub systemd-detect-virt 'exit 1'
assert_exit 1 confirm "Proceed?"
assert_eq "" "$RUN_OUTPUT" "confirm's output off a VM"

# confirm asks whenever stdin is a terminal, even with stdout piped (bash setup.sh | tee log)
unset DOTFILES_ASSUME_YES
interactive="$SANDBOX/interactive"
check='. "$0/lib/common.sh"; if is_interactive > "$1"; then echo yes > "$1"; else echo no > "$1"; fi'
if in_terminal_available; then
    in_terminal "$BASH" -c "$check" "$REPO_DIR" "$interactive" > /dev/null
    assert_eq yes "$(cat "$interactive")" "is_interactive with a terminal stdin and stdout to a file"
else
    skip_rest "is_interactive with a terminal: script isn't installed"
fi
run bash -c 'set -o pipefail; . "$0/lib/common.sh"; confirm "Proceed?" | cat' "$REPO_DIR"
assert_eq 1 "$RUN_STATUS" "confirm's status with stdin from /dev/null and stdout piped"

# --- regex_escape ---
for s in 'Logi Options+' '/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code' 'a.b*c?d[e]f{1}|g^h$i\j'; do
    pattern="$(regex_escape "$s")"
    printf '%s\n' "$s" | grep -qxE -- "$pattern" || fail "'$pattern' doesn't match '$s'"
done
! printf '%s\n' 'Logi Optionss' | grep -qxE -- "$(regex_escape 'Logi Options+')" ||
    fail "the escaped + still repeats"
! printf '%s\n' 'aXb' | grep -qxE -- "$(regex_escape 'a.b')" || fail "the escaped . still matches any character"

# --- version_at_least: parts compare as numbers, and a missing part counts as 0 ---
for pair in "1.10 1.8.1" "2.100 2.53" "1.8.1 1.8.1" "2.53 2.53.0" "3 2.99"; do
    # shellcheck disable=SC2086 # two arguments
    version_at_least $pair || fail "version_at_least $pair failed"
done
for pair in "1.8.0 1.8.1" "2.53 2.53.1" "1.9 1.10"; do
    # shellcheck disable=SC2086
    ! version_at_least $pair || fail "version_at_least $pair succeeded"
done

# --- ensure_app_quit and merge_app_json: a running app's settings change only once it quits ---
app_json() {
    # shellcheck source=../ai_tools/lib/app-json.sh
    source "$REPO_DIR/ai_tools/lib/app-json.sh"
    settings="$SANDBOX/app.json"
    echo '{"mine": 1}' > "$settings"
    snapshot "$settings"
    # shellcheck disable=SC2329 # assert_exit runs it
    merge() {
        merge_app_json "Some App" "already set" "set" "$settings" '.repo = 2'
    }
    stub pgrep '[ -e "'"$SANDBOX"'/app-running" ]'
    stub osascript '[ -e "'"$SANDBOX"'/stays-running" ] || rm -f "'"$SANDBOX"'/app-running"'
    stub sleep
    touch "$SANDBOX/app-running"
    as_os macos

    # Without a terminal, confirm says no
    assert_exit 0 merge
    assert_unchanged "$settings" "while the app ran, without a terminal"
    assert_file_not_contains "$STUB_LOG" osascript
    answer no
    assert_exit 0 merge
    assert_unchanged "$settings" "after declining to quit the app"
    assert_file_not_contains "$STUB_LOG" osascript
    # Ubuntu can't quit it, so it doesn't ask
    as_os ubuntu
    answer yes
    assert_exit 0 merge
    assert_unchanged "$settings" "while the app ran on Ubuntu"
    assert_not_contains "$RUN_OUTPUT" "Quit Some App now?"
    as_os macos
    touch "$SANDBOX/stays-running"
    assert_exit 0 merge
    assert_unchanged "$settings" "after the app didn't quit"
    rm "$SANDBOX/stays-running"
    assert_exit 0 merge
    assert_file_contains "$STUB_LOG" 'osascript -e quit app "Some App"'
    assert_eq '1 2' "$(jq -r '"\(.mine) \(.repo)"' "$settings")" "the settings after the app quit"

    # Settings already in place leave a running app alone
    : > "$STUB_LOG"
    touch "$SANDBOX/app-running"
    assert_exit 0 merge
    assert_eq "" "$(cat "$STUB_LOG")" "commands run with the settings already in place"

    # Never quit the app running this script, as a terminal app can
    assert_exit 1 ensure_app_quit bash
    assert_file_not_contains "$STUB_LOG" osascript
    running_inside bash || fail "running_inside didn't find the bash running this test"
    ! running_inside no-such-app || fail "running_inside found no-such-app"
    # Stubs outlive the subtest
    rm "$STUB_DIR/sleep"
}
if command -v jq &> /dev/null; then
    subtest app_json
else
    skip_rest "merge_app_json: jq isn't installed"
fi

# --- stub_sudo_exec: the refused commands name a missing repo dir, so they'd fail even if run ---
stub_sudo_exec
echo hi > "$SANDBOX/file"
gone="$REPO_DIR/no-such-dir/file"
assert_exit 1 sudo install -m 0644 "$SANDBOX/file" "$gone"
assert_contains "$RUN_OUTPUT" "refused: install would change $gone, in the repo"
assert_exit 1 sudo cat /etc/hosts
assert_contains "$RUN_OUTPUT" "refused: /etc/hosts is outside the sandbox"

# run_bounded through timeout(1), then through perl, as on macOS. One real timeout each.
assert_exit 124 run_bounded 1 sleep 10
assert_exit 3 run_bounded 5 bash -c 'echo out; exit 3'
assert_eq out "$RUN_OUTPUT" "run_bounded's output"
# timeout -k 5 exits 137 after SIGKILL; run_bounded reports 124 only past the deadline
run_bounded_killed() {
    stub timeout '[ "$1 $2" == "-k 5" ] || exit 99; exit 137'
    assert_exit 124 run_bounded 0 sleep 10
    assert_exit 137 run_bounded 5 sleep 10
    rm "$STUB_DIR/timeout"
}
subtest run_bounded_killed
# Its elapsed-time check is why this test is serial
run_bounded_without_timeout() {
    local start=$SECONDS
    hide timeout
    assert_exit 124 run_bounded 1 sleep 10
    [ $((SECONDS - start)) -lt 5 ] || fail "run_bounded without timeout(1) waited out the command"
    assert_exit 3 run_bounded 5 bash -c 'echo out; exit 3'
    assert_eq out "$RUN_OUTPUT" "run_bounded's output without timeout(1)"
    # 142 (SIGALRM) or 143 from the command itself isn't a timeout
    assert_exit 142 run_bounded 5 sh -c 'exit 142'
    assert_exit 143 run_bounded 5 sh -c 'kill -TERM $$'
}
if command -v perl &> /dev/null; then
    subtest run_bounded_without_timeout
else
    skip_rest "run_bounded without timeout(1): perl isn't installed"
fi

test_done
