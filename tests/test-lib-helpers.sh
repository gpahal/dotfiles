#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

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

test_done
