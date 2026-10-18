#!/bin/bash
set -uo pipefail

# Run every tests/test-*.sh, or the named ones (e.g. bash tests/run.sh vim copy-file), each in its
# own process under the bash running this script, with stdin from /dev/null, $TEST_JOBS at a time
# (one per CPU by default). Prints PASS, FAIL, or SKIP per file, in name order, with a failing or
# skipped test's output, and exits 1 when any fails. A test skips by exiting 77, and with
# TEST_FAIL_ON_SKIP=1, as CI sets, a skip fails. A test that runs longer than $TEST_TIMEOUT seconds
# (120 by default) is killed and fails. A slow test can raise its own limit with a
# "# timeout: <seconds>" line in its first 20 lines. A test that needs a command only macOS ships,
# such as ls -e or sqlite3, has an "# os: macos" line there, and a run of every test leaves it out
# on Ubuntu; a named test always runs. Each test gets its own HOME and TMUX_TMPDIR, with XDG_* and
# DOTFILES_* unset, as a backstop for one that forgets setup_sandbox. It syntax-checks the repo's
# other shell scripts and each selected test before running it, since a syntax error in a sourced
# script can let a test pass.

CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" || exit 1
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

on_macos=false
[ "$(uname -s)" != Darwin ] || on_macos=true
tests=()
macos_only=0
if [ $# -eq 0 ]; then
    for t in test-*.sh; do
        [ -e "$t" ] || continue
        if ! "$on_macos" && sed -n '1,20p' "$t" | grep -qx '# os: macos'; then
            macos_only=$((macos_only + 1))
            continue
        fi
        tests+=("$t")
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
        tests+=("$t")
    done
fi

# Print the repo's *.sh files and the files in */bin/, as paths from here. In a git checkout,
# these are the ones git lists, as `just check` lints, so ignored dirs such as .scratch/ are left
# out.
repo_scripts() {
    if git -C .. rev-parse --is-inside-work-tree &>/dev/null; then
        git -C .. ls-files --cached --others --exclude-standard '*.sh' '*/bin/*' | sed 's|^|../|' | sort -u
    else
        find .. \( -name .git -o -name node_modules \) -prune -o -type f \( -name '*.sh' -o -path '*/bin/*' \) -print | sort
    fi
}

# The *.sh files, and the scripts in */bin/ that run under bash. Each test gets its own check
# below.
broken=0
while IFS= read -r f; do
    # git lists a tracked file deleted from the working tree
    [ -f "$f" ] || continue
    case "$f" in
        ../tests/test-*.sh) continue ;;
        *.sh) ;;
        *) head -1 "$f" | grep -q bash || continue ;;
    esac
    if ! output="$("$BASH" -n "$f" 2>&1)"; then
        echo "FAIL  ${f#../}"
        printf '%s\n' "$output" | sed 's/^/    /'
        broken=$((broken + 1))
    fi
done < <(repo_scripts)

# Print a test's time limit: its "# timeout:" line, when that's above $TEST_TIMEOUT
test_timeout() {
    local own
    own="$(sed -n '1,20s/^# timeout: \([0-9][0-9]*\)$/\1/p' "$1" | head -1)"
    if [ -n "$own" ] && [ "$own" -gt "$TEST_TIMEOUT" ]; then
        echo "$own"
    else
        echo "$TEST_TIMEOUT"
    fi
}

# Kill test process group $1 once it has run $3 seconds, noting it in file $2
watchdog() {
    local pid="$1" limit="$3" i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$limit" ]; then
            echo "Killed: took longer than ${limit}s" > "$2"
            kill -TERM -- "-$pid" 2>/dev/null
            sleep 2
            kill -KILL -- "-$pid" 2>/dev/null
            return
        fi
        sleep 1
        i=$((i + 1))
    done
}

jobs="${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
# 0 would start no test and wait forever
case "$jobs" in
    '' | *[!0-9]* | 0*)
        echo "TEST_JOBS must be a positive integer, not '$jobs'" >&2
        exit 1
        ;;
esac
# /tmp, not $TMPDIR, keeps the tests' TMUX_TMPDIR under tmux's socket path length limit on macOS
tmp="$(mktemp -d /tmp/dotfiles-run.XXXXXX)" || exit 1

# Remove test $1's HOME, TMUX_TMPDIR, and sandbox, which the test's EXIT trap removes unless the
# watchdog had to SIGKILL it, stopping any tmux server it left running there
clean_test_dirs() {
    local dir="$tmp/$1" sock
    if command -v tmux &>/dev/null; then
        for sock in "$dir"/tmux/tmux-*/* "$dir"/dotfiles-test.*/tmux/tmux-*/*; do
            [ ! -S "$sock" ] || tmux -S "$sock" kill-server &>/dev/null
        done
    fi
    chmod -R u+w "$dir/home" "$dir/tmux" "$dir"/dotfiles-test.* 2>/dev/null
    rm -rf "${dir:?}/home" "${dir:?}/tmux" "${dir:?}"/dotfiles-test.*
}

# Run test $2 as number $1 in $tmp/$1, leaving its output in output and, last, its exit status in
# status. Runs in the background, one per test.
run_test() {
    local dir="$tmp/$1" t="$2" limit pid watchdog_pid status
    # A worker is a subshell, which mustn't run the runner's cleanup when it exits
    trap - EXIT
    mkdir "$dir/home" "$dir/tmux"
    # setup_sandbox makes the sandbox in TEST_SANDBOX_PARENT
    export HOME="$dir/home" TMUX_TMPDIR="$dir/tmux" TEST_SANDBOX_PARENT="$dir"
    if ! "$BASH" -n "$t" > "$dir/output" 2>&1; then
        status=2
    else
        # Job control gives the test and the watchdog their own process groups, so a kill reaches
        # what the test started too. It's on only for these two: on macOS, bash's child sometimes
        # prints "child setpgid (N to N): Operation not permitted" when the parent's setpgid for
        # it ran first. The job still gets its own group. The child prints it before its own
        # redirections apply, so the braces discard it.
        limit="$(test_timeout "$t")"
        set -m
        {
            "$BASH" "$t" < /dev/null > "$dir/output" 2>&1 &
            pid=$!
            watchdog "$pid" "$dir/timed-out" "$limit" < /dev/null > /dev/null 2>&1 &
            watchdog_pid=$!
        } 2>/dev/null
        set +m
        echo "$pid $watchdog_pid" > "$dir/pids"
        trap 'kill -TERM -- "-$pid" "-$watchdog_pid" 2>/dev/null; exit 130' TERM
        # Bash prints "Terminated" for a killed job on the wait's stderr, which the braces discard
        { wait "$pid"; } 2>/dev/null
        status=$?
        { kill -- "-$watchdog_pid" && wait "$watchdog_pid"; } 2>/dev/null
        if [ -e "$dir/timed-out" ]; then
            cat "$dir/timed-out" >> "$dir/output"
            status=1
        fi
    fi
    clean_test_dirs "$1"
    echo "$status" > "$dir/status.tmp" && mv "$dir/status.tmp" "$dir/status"
}

workers=()
# shellcheck disable=SC2329 # the traps run them
cleanup() {
    rm -rf "$tmp"
}
# A test runs in its own process group, which Ctrl-C doesn't reach, so stop each one running here
# shellcheck disable=SC2329
interrupted() {
    local i test_pid watchdog_pid
    for i in ${workers[@]+"${!workers[@]}"}; do
        [ ! -e "$tmp/$i/status" ] || continue
        kill -TERM "${workers[i]}" 2>/dev/null
        read -r test_pid watchdog_pid < "$tmp/$i/pids" 2>/dev/null || continue
        kill -TERM -- "-$test_pid" "-$watchdog_pid" 2>/dev/null
    done
    wait 2>/dev/null
    for i in ${workers[@]+"${!workers[@]}"}; do
        clean_test_dirs "$i"
    done
    exit 130
}
trap cleanup EXIT
trap interrupted INT TERM

for var in $(compgen -e | grep -E '^(XDG_|DOTFILES_)'); do
    unset "$var"
done
unset TMUX TMUX_PANE
failed=()
skipped=0
started=0
reported=0
running=0
while [ "$reported" -lt "${#tests[@]}" ]; do
    while [ "$running" -lt "$jobs" ] && [ "$started" -lt "${#tests[@]}" ]; do
        mkdir "$tmp/$started"
        # With job control, as each worker starts its test: without it, a background job ignores
        # SIGINT, and so would the test, which checks how steps handle an interrupt. The braces
        # discard the setpgid message described in run_test.
        set -m
        { run_test "$started" "${tests[started]}" < /dev/null & } 2>/dev/null
        workers[started]=$!
        set +m
        started=$((started + 1))
        running=$((running + 1))
    done
    # Report the finished tests in order, so the output doesn't depend on which ends first
    progressed=false
    for ((i = reported; i < started; i++)); do
        [ -e "$tmp/$i/status" ] || continue
        if [ -z "${done_tests[i]:-}" ]; then
            done_tests[i]=1
            running=$((running - 1))
            progressed=true
            wait "${workers[i]}" 2>/dev/null
        fi
    done
    while [ "$reported" -lt "$started" ] && [ -n "${done_tests[reported]:-}" ]; do
        t="${tests[reported]}"
        dir="$tmp/$reported"
        status="$(cat "$dir/status")"
        if [ "$status" -eq 0 ]; then
            echo "PASS  $t"
        elif [ "$status" -eq 77 ] && [ "${TEST_FAIL_ON_SKIP:-}" != 1 ]; then
            echo "SKIP  $t"
            sed 's/^/    /' "$dir/output"
            skipped=$((skipped + 1))
        else
            [ "$status" -ne 77 ] || echo "Skipped, and TEST_FAIL_ON_SKIP=1 fails a skip" >> "$dir/output"
            echo "FAIL  $t"
            sed 's/^/    /' "$dir/output"
            failed+=("$t")
        fi
        rm -rf "${dir:?}"
        reported=$((reported + 1))
    done
    "$progressed" || sleep 0.1
done

echo ""
echo "$((${#tests[@]} - ${#failed[@]} - skipped)) passed, ${#failed[@]} failed, $skipped skipped"
[ "$macos_only" -eq 0 ] || echo "$macos_only left out, as they need commands only macOS ships"
[ "$broken" -eq 0 ] || echo "$broken script(s) with a syntax error"
[ ${#failed[@]} -eq 0 ] && [ "$broken" -eq 0 ]
