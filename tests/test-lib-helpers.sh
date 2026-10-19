#!/bin/bash
set -euo pipefail

# tests/lib.sh's override helpers: replace_fn redefines a function and fails the test when there's
# none by that name, as_os sets is_macos and is_ubuntu, and answer sets confirm's answer.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

# os <name>: succeeds when is_macos and is_ubuntu agree the OS is <name>
os() {
    case "$1" in
        macos) is_macos && ! is_ubuntu ;;
        ubuntu) is_ubuntu && ! is_macos ;;
    esac
}

# Each sets both, whatever the real OS
as_os macos
os macos || fail "as_os macos"
as_os ubuntu
os ubuntu || fail "as_os ubuntu"
as_os macos
os macos || fail "as_os macos after as_os ubuntu"

# confirm prints its question, then answers
answer yes
run confirm "Go on?"
assert_eq "0 Go on?" "$RUN_STATUS $RUN_OUTPUT" "confirm after answer yes"
answer no
run confirm "Go on?"
assert_eq "1 Go on?" "$RUN_STATUS $RUN_OUTPUT" "confirm after answer no"

replace_fn locale_installed 'return 1'
! locale_installed || fail "replace_fn didn't replace locale_installed"
# An empty body succeeds
replace_fn locale_installed ''
locale_installed || fail "replace_fn with an empty body"

# expect_failure <message> <command> [arg...]: the command fails the test, saying <message>
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
# It still defines it
assert_eq hi "$(
    replace_fn no_such_fn 'echo hi' 2> /dev/null
    no_such_fn
)" "no_such_fn after replace_fn"
expect_failure "as_os: 'windows' isn't macos or ubuntu" as_os windows
expect_failure "answer: 'maybe' isn't yes or no" answer maybe
# A script that has no confirm, as when a step renamed it
unset -f confirm
expect_failure "replace_fn: no function confirm to replace" answer yes

test_done
