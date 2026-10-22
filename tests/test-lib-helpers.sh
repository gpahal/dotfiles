#!/bin/bash
set -euo pipefail
# serial

# The test helpers in tests/lib.sh, and lib/common.sh's confirm and regex_escape.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

# --- confirm and DOTFILES_ASSUME_YES ---
assert_exit 1 confirm "Proceed?"
export DOTFILES_ASSUME_YES=1
assert_exit 0 confirm "Proceed?"
assert_eq "Proceed? yes (DOTFILES_ASSUME_YES)" "$RUN_OUTPUT" "confirm's output"
DOTFILES_ASSUME_YES=0
assert_exit 1 confirm "Proceed?"

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

# --- tests/lib.sh ---
os() {
    case "$1" in
        macos) is_macos && ! is_ubuntu ;;
        ubuntu) is_ubuntu && ! is_macos ;;
    esac
}

as_os macos
os macos || fail "as_os macos"
as_os ubuntu
os ubuntu || fail "as_os ubuntu"
as_os macos
os macos || fail "as_os macos after as_os ubuntu"

answer yes
run confirm "Go on?"
assert_eq "0 Go on?" "$RUN_STATUS $RUN_OUTPUT" "confirm after answer yes"
answer no
run confirm "Go on?"
assert_eq "1 Go on?" "$RUN_STATUS $RUN_OUTPUT" "confirm after answer no"

# The homebrew step supplies most commands, through apt on Ubuntu for some
as_os ubuntu
assert_eq "jq isn't installed. Run bash setup.sh homebrew first, which installs it with apt." \
    "$(missing_cmd_hint jq)" "jq's hint on Ubuntu"
assert_eq "gnome-extensions isn't installed. It needs the GNOME desktop: ubuntu-desktop." \
    "$(missing_cmd_hint gnome-extensions)" "gnome-extensions' hint"
as_os macos
assert_eq "jq isn't installed. Run bash setup.sh homebrew first." "$(missing_cmd_hint jq)" "jq's hint on macOS"

replace_fn locale_installed 'return 1'
! locale_installed || fail "replace_fn didn't replace locale_installed"
replace_fn locale_installed ''
locale_installed || fail "replace_fn with an empty body"

expect_failure() {
    local message="$1" output failures
    shift
    output="$(
        TEST_FAILURES=0
        "$@" 2>&1
        echo "failures=$TEST_FAILURES"
    )"
    failures="${output##*failures=}"
    assert_eq 1 "$failures" "checks '$*' failed"
    assert_contains "$output" "$message" "output of '$*'"
    assert_contains "$output" "test-lib-helpers.sh:" "output of '$*'"
}
expect_failure "replace_fn: no function no_such_fn to replace" replace_fn no_such_fn 'echo hi'
assert_eq hi "$(
    replace_fn no_such_fn 'echo hi' 2> /dev/null
    no_such_fn
)" "no_such_fn after replace_fn"
expect_failure "as_os: 'windows' isn't macos or ubuntu" as_os windows
expect_failure "answer: 'maybe' isn't yes or no" answer maybe

greet() { echo "hi $1"; }
wrap_fn greet 'real_greet "$1"; echo wrapped'
wrap_fn greet 'real_greet "$1"; echo again'
assert_eq "hi you
again" "$(greet you)" "greet after wrap_fn twice"
restore_fn greet
assert_eq "hi you" "$(greet you)" "greet after restore_fn"
! declare -F real_greet > /dev/null || fail "restore_fn left real_greet"
expect_failure "replace_fn: no function no_such_fn to replace" wrap_fn no_such_fn
expect_failure "restore_fn: greet isn't wrapped" restore_fn greet

: > "$STUB_LOG"
stub_sudo_cacheable
expect_failure "cache_sudo: 'maybe' isn't yes or no" cache_sudo maybe
assert_exit 1 sudo -n true
cache_sudo yes
assert_exit 0 sudo -n true
cache_sudo no
assert_exit 1 sudo -n true
assert_sudo_noninteractive
assert_exit 0 sudo true
expect_failure "the check ran sudo without -n:" assert_sudo_noninteractive "the check"
unset -f confirm
expect_failure "replace_fn: no function confirm to replace" answer yes

# The refused commands name a missing repo dir, so they'd fail even if they ran

stub_sudo_exec
echo hi > "$SANDBOX/file"
gone="$REPO_DIR/no-such-dir/file"
assert_exit 0 sudo -n install -m 0644 "$REPO_DIR/tests/lib.sh" "$SANDBOX/copy"
cmp -s "$REPO_DIR/tests/lib.sh" "$SANDBOX/copy" || fail "sudo install didn't copy from the repo"
assert_exit 0 sudo cat "$REPO_DIR/tests/lib.sh"
assert_exit 0 sudo DEBIAN_FRONTEND=noninteractive bash -n "$REPO_DIR/tests/lib.sh"
for cmd in "cp $SANDBOX/file $gone" "install -d $gone" "install -m 0644 $SANDBOX/file $gone" \
    "rm -f $gone" "mv $gone $SANDBOX/moved" "chmod 600 $gone $SANDBOX/file" "tee $gone"; do
    # shellcheck disable=SC2086 # split into arguments
    assert_exit 1 sudo $cmd
    assert_contains "$RUN_OUTPUT" "refused: ${cmd%% *} would change $gone, in the repo" "sudo $cmd"
done
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
