#!/bin/bash
set -uo pipefail

# Run every tests/test-*.sh, or the named ones, $TEST_JOBS at a time (default: the CPU count), under
# this script's bash. Each test gets its own dir under one temp dir, with its HOME, TMUX_TMPDIR,
# and sandbox in it; the run shows the output of a test that fails or skips, then the five slowest
# tests in whole seconds.
# - "# os: macos" or "# os: ubuntu" in the first 20 lines: left out of a full run on the other
#   OS, and skipped there when named.
# - TEST_SHARD=<k>/<n> (CI): a full run runs only every nth test of its list, starting at the kth.
#   Named tests ignore it.
# - Exit 77 skips; TEST_FAIL_ON_SKIP=1 (CI) makes a skip fail.
# - A test over $TEST_TIMEOUT seconds (default 120) is killed and fails. Without timeout(1), as on
#   macOS, what the test started isn't killed with it.
# - Ctrl-C stops the run and its tests.

CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" || exit 1
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

# Sourcing all of lib/common.sh would change the tests' PATH and environment
eval "$(sed -n '/^run_bounded() {$/,/^}$/p' ../lib/common.sh)"
if ! declare -F run_bounded > /dev/null; then
    echo "No run_bounded() in lib/common.sh" >&2
    exit 1
fi

# For a test SIGKILLed before its EXIT trap ran: a tmux server outlives its socket's dir
clean_test_dir() {
    local dir="$1" sock
    if command -v tmux &> /dev/null; then
        for sock in "$dir"/tmux/tmux-*/* "$dir"/dotfiles-test.*/tmux/tmux-*/*; do
            [ ! -S "$sock" ] || tmux -S "$sock" kill-server &> /dev/null
        done
    fi
    chmod -R u+w "$dir" 2> /dev/null
    rm -rf "${dir:?}/home" "${dir:?}/tmux" "${dir:?}"/dotfiles-test.*
}

# The xargs worker: run.sh --worker <timeout> <dir> <test>. It exits 0, as xargs stops at a command
# that exits 255.
if [ "${1:-}" == --worker ]; then
    TEST_TIMEOUT="$2" dir="$3" t="$4"
    mkdir "$dir/home" "$dir/tmux"
    export HOME="$dir/home" TMUX_TMPDIR="$dir/tmux" TEST_SANDBOX_PARENT="$dir"
    SECONDS=0
    if ! "$BASH" -n "$t" > "$dir/output" 2>&1; then
        status=2
    else
        run_bounded "$TEST_TIMEOUT" "$BASH" "$t" < /dev/null > "$dir/output" 2>&1
        status=$?
        if [ "$status" -eq 124 ]; then
            echo "Killed: took longer than ${TEST_TIMEOUT}s" >> "$dir/output"
            status=1
        fi
    fi
    echo "$SECONDS" > "$dir/time"
    clean_test_dir "$dir"
    echo "$status" > "$dir/status"
    exit 0
fi

on_macos=false
[ "$(uname -s)" != Darwin ] || on_macos=true

# Prints the OS a test's "# os:" mark names, and succeeds, when it isn't this one
other_os() {
    case "$(sed -n '1,20s/^# os: \(.*\)$/\1/p' "$1" | head -n 1)" in
        macos) ! "$on_macos" && echo macOS ;;
        ubuntu) "$on_macos" && echo Ubuntu ;;
        *) return 1 ;;
    esac
}

passed=0 failed=0 skipped=0 left_out=0
# Usage: result <test> <status> <output>: prints PASS, SKIP, or FAIL, with the output unless it passed
result() {
    local verdict=FAIL output="$3"
    case "$2" in
        0) verdict=PASS ;;
        77) [ "${TEST_FAIL_ON_SKIP:-}" == 1 ] && output="$output
Skipped, and TEST_FAIL_ON_SKIP=1 fails a skip" || verdict=SKIP ;;
    esac
    echo "$verdict  $1"
    case "$verdict" in
        PASS) passed=$((passed + 1)) && return ;;
        SKIP) skipped=$((skipped + 1)) ;;
        FAIL) failed=$((failed + 1)) ;;
    esac
    [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/    /'
}

tests=()
if [ $# -eq 0 ]; then
    shard="${TEST_SHARD:-1/1}"
    shard_k="${shard%%/*}" shard_n="${shard#*/}"
    case "$shard_k" in '' | *[!0-9]* | 0*) shard_k=0 ;; esac
    case "$shard_n" in '' | *[!0-9]* | 0*) shard_n=0 ;; esac
    if [ "$shard" != "$shard_k/$shard_n" ] || [ "$shard_k" -eq 0 ] || [ "$shard_k" -gt "$shard_n" ]; then
        echo "TEST_SHARD must be <k>/<n>, with 1 <= k <= n, not '$shard'" >&2
        exit 1
    fi
    i=0
    for t in test-*.sh; do
        if other_os "$t" > /dev/null; then
            left_out=$((left_out + 1))
        else
            [ $((i % shard_n + 1)) -ne "$shard_k" ] || tests+=("$t")
            i=$((i + 1))
        fi
    done
else
    for name in "$@"; do
        name="${name##*/}"
        name="${name#test-}"
        t="test-${name%.sh}.sh"
        if [ ! -f "$t" ]; then
            echo "No test $t in tests/" >&2
            exit 1
        fi
        if os="$(other_os "$t")"; then
            result "$t" 77 "It runs only on $os"
        else
            tests+=("$t")
        fi
    done
fi

jobs="${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 2)}"
for setting in "TEST_JOBS=$jobs" "TEST_TIMEOUT=$TEST_TIMEOUT"; do
    case "${setting#*=}" in
        '' | *[!0-9]* | 0*)
            echo "${setting%%=*} must be a positive integer, not '${setting#*=}'" >&2
            exit 1
            ;;
    esac
done

# /tmp keeps TMUX_TMPDIR under macOS's socket path limit
tmp="$(mktemp -d /tmp/dotfiles-run.XXXXXX)" || exit 1
# shellcheck disable=SC2329 # the traps run it
cleanup() {
    local dir
    for dir in "$tmp"/*/; do
        [ ! -d "$dir" ] || clean_test_dir "$dir"
    done
    rm -rf "$tmp"
}
trap cleanup EXIT
# Ignoring the signals first keeps kill 0 from re-running the trap. kill 0 misses the process group
# timeout(1) makes, so each worker's timeout gets the signal to pass on.
trap 'trap "" INT TERM; pkill -P "$(pgrep -d , -f "run.sh --worker [0-9]* $tmp/")" 2> /dev/null; kill 0; exit 130' INT TERM

# xargs runs in the foreground: a background job would start the tests with SIGINT ignored, which
# a test can't undo. GNU xargs would run the worker once with no tests. Results print in the order
# given, so output doesn't depend on timing.
if [ "${#tests[@]}" -gt 0 ]; then
    for i in "${!tests[@]}"; do
        mkdir "$tmp/$i"
        printf '%s\0%s\0' "$tmp/$i" "${tests[i]}"
    done | xargs -0 -n 2 -P "$jobs" "$BASH" "$PWD/run.sh" --worker "$TEST_TIMEOUT" > /dev/null 2>&1
fi
times=""
for i in "${!tests[@]}"; do
    status="$(cat "$tmp/$i/status" 2> /dev/null)" || {
        status=1
        echo "It didn't finish: xargs stopped first" >> "$tmp/$i/output"
    }
    result "${tests[i]}" "$status" "$(cat "$tmp/$i/output")"
    if [ -f "$tmp/$i/time" ]; then
        name="${tests[i]#test-}"
        times="$times$(cat "$tmp/$i/time") ${name%.sh}
"
    fi
done

echo ""
echo "$passed passed, $failed failed, $skipped skipped"
[ "$left_out" -eq 0 ] || echo "$left_out left out, as they need commands only the other OS ships"
[ -z "$times" ] || printf '%s' "$times" | sort -rn | head -n 5 | awk '{ printf "%s%s %ss", (NR > 1 ? ", " : "Slowest: "), $2, $1 } END { print "" }'
[ "$failed" -eq 0 ]
