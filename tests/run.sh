#!/bin/bash
set -uo pipefail

# Run every tests/test-*.sh, or the named ones (e.g. bash tests/run.sh harness copy-file), each in
# its own process under the bash running this script, with stdin from /dev/null. Prints PASS,
# FAIL, or SKIP per file, with a failing or skipped test's output, and exits 1 when any fails. A
# test skips by exiting 77, and with TEST_FAIL_ON_SKIP=1, as CI sets, a skip fails. A test that
# runs longer than $TEST_TIMEOUT seconds (120 by default) is killed and fails. A slow test can
# raise its own limit with a "# timeout: <seconds>" line in its first 20 lines. Each test gets a new
# HOME and TMUX_TMPDIR, with XDG_* and DOTFILES_* unset, as a backstop for one that forgets
# setup_sandbox. It syntax-checks the repo's other shell scripts and each selected test before
# running it, since a syntax error in a sourced script can let a test pass.

CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" || exit 1
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

tests=()
if [ $# -eq 0 ]; then
    for t in test-*.sh; do
        [ -e "$t" ] && tests+=("$t")
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

# /tmp, not $TMPDIR, keeps the tests' TMUX_TMPDIR under tmux's socket path length limit on macOS
tmp="$(mktemp -d /tmp/dotfiles-run.XXXXXX)" || exit 1
pid=""
watchdog_pid=""

# Remove the last test's HOME and TMUX_TMPDIR, stopping a tmux server it left running there
clean_test_dirs() {
    if [ -n "$(/bin/ls -A "$tmp/tmux" 2>/dev/null)" ] && command -v tmux &>/dev/null; then
        TMUX_TMPDIR="$tmp/tmux" tmux kill-server &>/dev/null
    fi
    chmod -R u+w "$tmp/home" "$tmp/tmux" 2>/dev/null
    rm -rf "${tmp:?}/home" "${tmp:?}/tmux"
}

# shellcheck disable=SC2329 # the traps run them
cleanup() {
    clean_test_dirs
    rm -rf "$tmp"
}
# A test runs in its own process group, which Ctrl-C doesn't reach, so stop it here
# shellcheck disable=SC2329
interrupted() {
    [ -z "$pid" ] || kill -TERM -- "-$pid" 2>/dev/null
    [ -z "$watchdog_pid" ] || kill -TERM -- "-$watchdog_pid" 2>/dev/null
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
for t in ${tests[@]+"${tests[@]}"}; do
    rm -f "$tmp/timed-out"
    clean_test_dirs
    mkdir "$tmp/home" "$tmp/tmux"
    export HOME="$tmp/home" TMUX_TMPDIR="$tmp/tmux"
    if ! "$BASH" -n "$t" > "$tmp/output" 2>&1; then
        status=2
    else
        # Job control gives the test and the watchdog their own process groups, so a kill reaches
        # what the test started too. It's on only for these two: on macOS, bash's child sometimes
        # prints "child setpgid (N to N): Operation not permitted" when the parent's setpgid for
        # it ran first. The job still gets its own group. The child prints it before its own
        # redirections apply, so the braces discard it.
        # Outside the watchdog's job: under bash 5.3, a job that ran a command substitution runs
        # the EXIT trap when it's killed, and cleanup would remove $tmp while tests still run
        limit="$(test_timeout "$t")"
        set -m
        {
            "$BASH" "$t" < /dev/null > "$tmp/output" 2>&1 &
            pid=$!
            watchdog "$pid" "$tmp/timed-out" "$limit" < /dev/null > /dev/null 2>&1 &
            watchdog_pid=$!
        } 2>/dev/null
        set +m
        # Bash prints "Terminated" for a killed job on the wait's stderr, which the braces discard
        { wait "$pid"; } 2>/dev/null
        status=$?
        { kill -- "-$watchdog_pid" && wait "$watchdog_pid"; } 2>/dev/null
        pid=""
        watchdog_pid=""
        if [ -e "$tmp/timed-out" ]; then
            cat "$tmp/timed-out" >> "$tmp/output"
            status=1
        fi
    fi
    if [ "$status" -eq 0 ]; then
        echo "PASS  $t"
    elif [ "$status" -eq 77 ] && [ "${TEST_FAIL_ON_SKIP:-}" != 1 ]; then
        echo "SKIP  $t"
        sed 's/^/    /' "$tmp/output"
        skipped=$((skipped + 1))
    else
        [ "$status" -ne 77 ] || echo "Skipped, and TEST_FAIL_ON_SKIP=1 fails a skip" >> "$tmp/output"
        echo "FAIL  $t"
        sed 's/^/    /' "$tmp/output"
        failed+=("$t")
    fi
done

echo ""
echo "$((${#tests[@]} - ${#failed[@]} - skipped)) passed, ${#failed[@]} failed, $skipped skipped"
[ "$broken" -eq 0 ] || echo "$broken script(s) with a syntax error"
[ ${#failed[@]} -eq 0 ] && [ "$broken" -eq 0 ]
