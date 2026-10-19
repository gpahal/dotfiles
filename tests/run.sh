#!/bin/bash
set -uo pipefail

# Run every tests/test-*.sh, or the named ones (e.g. bash tests/run.sh vim copy-file), each in its
# own process group under the bash running this script (so /bin/bash tests/run.sh tests bash 3.2),
# with stdin from /dev/null, $TEST_JOBS at a time (one per CPU by default).
# Prints PASS, FAIL, or SKIP per test in name order, with a failing or skipped test's output, and
# exits 1 when any fails.
# - "# serial": a test whose timing can flake under load runs after the others, one at a time.
# - "# os: macos" in a test's first 20 lines: it needs a command only macOS ships, such as ls -e,
#   so a run of every test leaves it out on Ubuntu; a named test always runs.
# - A test skips by exiting 77; with TEST_FAIL_ON_SKIP=1, as CI sets, a skip fails.
# - A test that runs longer than $TEST_TIMEOUT seconds (120 by default) is killed and fails.
# Each test is syntax-checked first (a syntax error exits 2), and gets its own HOME and
# TMUX_TMPDIR, with XDG_* and DOTFILES_* unset, as a backstop for one that forgets setup_sandbox.
# A run of every test also syntax-checks the repo's other scripts, since a syntax error in a
# sourced script can let a test pass. Ctrl-C or SIGTERM stops every test and exits 130.

CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" || exit 1
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

# run_bounded alone: sourcing lib/common.sh would change PATH and export variables to the tests
eval "$(sed -n '/^run_bounded() {$/,/^}$/p' ../lib/common.sh)"
if ! declare -F run_bounded > /dev/null; then
    echo "No run_bounded() in lib/common.sh" >&2
    exit 1
fi

# Remove test $1's HOME, TMUX_TMPDIR, and sandbox, which the test's EXIT trap removes unless it
# was SIGKILLed, stopping any tmux server it left running there
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

# The worker xargs runs: run test $2 as number $1 in $tmp/$1, leaving its output in output and,
# last, its exit status in status. It exits 0 whatever the test does, since xargs stops at a
# command that exits 255.
run_test() {
    local dir="$tmp/$1" t="$2" pid status
    mkdir "$dir/home" "$dir/tmux"
    # setup_sandbox makes the sandbox in TEST_SANDBOX_PARENT
    export HOME="$dir/home" TMUX_TMPDIR="$dir/tmux" TEST_SANDBOX_PARENT="$dir"
    if ! "$BASH" -n "$t" > "$dir/output" 2>&1; then
        status=2
    else
        # Job control gives the test its own process group, so a timeout reaches what it started,
        # and keeps SIGINT deliverable: a background job would ignore it, and tests check how steps
        # handle an interrupt. The braces discard macOS bash's harmless "child setpgid ...
        # Operation not permitted", printed before the job's own redirections apply.
        set -m
        { run_bounded "$TEST_TIMEOUT" "$BASH" "$t" < /dev/null > "$dir/output" 2>&1 & } 2>/dev/null
        pid=$!
        set +m
        echo "$pid" > "$dir/pgid"
        # Bash prints "Terminated" for a killed job on the wait's stderr, which the braces discard
        { wait "$pid"; } 2>/dev/null
        status=$?
        if [ "$status" -eq 124 ]; then
            echo "Killed: took longer than ${TEST_TIMEOUT}s" >> "$dir/output"
            status=1
            # Without timeout(1), run_bounded's alarm kills only the test, not what it started
            if kill -TERM -- "-$pid" 2>/dev/null; then
                sleep 2
                kill -KILL -- "-$pid" 2>/dev/null
            fi
        fi
    fi
    clean_test_dirs "$1"
    echo "$status" > "$dir/status.tmp" && mv "$dir/status.tmp" "$dir/status"
}

if [ "${1:-}" == --worker ]; then
    tmp="$2" TEST_TIMEOUT="$3"
    run_test "$4" "$5"
    exit 0
fi

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

# Print the repo's *.sh files and the files in */bin/, as paths from here. In a git checkout, only
# those git lists, as `just check` lints, so ignored dirs such as .scratch/ are left out.
repo_scripts() {
    if git -C .. rev-parse --is-inside-work-tree &>/dev/null; then
        git -C .. ls-files --cached --others --exclude-standard '*.sh' '*/bin/*' | sed 's|^|../|' | sort -u
    else
        find .. \( -name .git -o -name node_modules \) -prune -o -type f \( -name '*.sh' -o -path '*/bin/*' \) -print | sort
    fi
}

# The *.sh files, and the scripts in */bin/ that run under bash, on a run of every test. Each test
# gets its own check in run_test.
broken=0
if [ $# -eq 0 ]; then
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
fi

jobs="${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
# A TEST_JOBS of 0 would start no test, and a TEST_TIMEOUT that isn't a number would turn the
# timeout off
for setting in "TEST_JOBS=$jobs" "TEST_TIMEOUT=$TEST_TIMEOUT"; do
    case "${setting#*=}" in
        '' | *[!0-9]* | 0*)
            echo "${setting%%=*} must be a positive integer, not '${setting#*=}'" >&2
            exit 1
            ;;
    esac
done
# test-ubuntu-sandbox.sh copies the repo to /var/tmp, outside the dir removed below, so a test
# killed before its EXIT trap leaves the copy there. Remove those a day old, which no run still uses.
find /var/tmp/ -maxdepth 1 -type d -name 'dotfiles-test.*' -user "$(id -u)" -mtime +0 2>/dev/null |
    while IFS= read -r dir; do
        chmod -R u+w "$dir" 2>/dev/null
        rm -rf "$dir"
    done
# /tmp, not $TMPDIR, keeps the tests' TMUX_TMPDIR under tmux's socket path length limit on macOS
tmp="$(mktemp -d /tmp/dotfiles-run.XXXXXX)" || exit 1

# Print the process groups of the processes this runner started, other than its own group:
# xargs's, which holds the workers, each test's, and each one timeout(1) makes for itself
child_groups() {
    ps -A -o pid= -o ppid= -o pgid= 2>/dev/null | awk -v root="$$" '
        { parent[$1] = $2; group[$1] = $3 }
        END {
            for (p in parent) {
                q = parent[p]
                for (n = 0; q != root && (q in parent) && n < 100; n++) q = parent[q]
                if (q == root && group[p] != group[root] && !(group[p] in seen)) {
                    seen[group[p]] = 1
                    print group[p]
                }
            }
        }'
}

xargs_pid=""
# shellcheck disable=SC2329 # the traps run them
cleanup() {
    rm -rf "$tmp"
}
# The tests run in process groups of their own, which Ctrl-C doesn't reach, so stop each one,
# giving it 5 s to run its EXIT trap, then remove what it left
# shellcheck disable=SC2329
interrupted() {
    local groups group i alive
    trap '' INT TERM
    # Also xargs's group and the tests' recorded ones, should ps be missing
    groups="$(child_groups) $xargs_pid $(cat "$tmp"/*/pgid 2>/dev/null)"
    for group in $groups; do
        kill -TERM -- "-$group" 2>/dev/null
    done
    for ((i = 0; i < 50; i++)); do
        alive=false
        for group in $groups; do
            ! kill -0 -- "-$group" 2>/dev/null || alive=true
        done
        "$alive" || break
        sleep 0.1
    done
    for group in $groups; do
        kill -KILL -- "-$group" 2>/dev/null
    done
    wait 2>/dev/null
    for i in "$tmp"/*/; do
        [ ! -d "$i" ] || clean_test_dirs "$(basename "$i")"
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

# Print test number $1's result, with its output unless it passed
report() {
    local t="${tests[$1]}" dir="$tmp/$1" status=1
    if [ -e "$dir/status" ]; then
        status="$(cat "$dir/status")"
    else
        echo "It didn't finish: xargs stopped first" >> "$dir/output"
    fi
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
}

# Run the tests numbered $2..., $1 at a time, and report each in the order given, so the output
# doesn't depend on which ends first
run_batch() {
    local jobs="$1" i
    shift
    [ $# -gt 0 ] || return 0
    for i in "$@"; do
        mkdir "$tmp/$i"
        printf '%s\0%s\0' "$i" "${tests[i]}"
    done > "$tmp/batch"
    # Job control puts xargs and its workers in a process group of their own, which interrupted
    # stops, and keeps SIGINT deliverable to the tests (see run_test). xargs's stderr has only
    # its complaint about a worker killed by a signal.
    set -m
    { xargs -0 -n 2 -P "$jobs" "$BASH" "$PWD/run.sh" --worker "$tmp" "$TEST_TIMEOUT" < "$tmp/batch" > /dev/null 2>&1 & } 2>/dev/null
    xargs_pid=$!
    set +m
    for i in "$@"; do
        while [ ! -e "$tmp/$i/status" ] && kill -0 "$xargs_pid" 2>/dev/null; do
            sleep 0.1
        done
        report "$i"
    done
    wait "$xargs_pid" 2>/dev/null
    xargs_pid=""
}

pool=()
serial=()
for i in "${!tests[@]}"; do
    if grep -qx '# serial' "${tests[i]}"; then
        serial+=("$i")
    else
        pool+=("$i")
    fi
done
run_batch "$jobs" ${pool[@]+"${pool[@]}"}
run_batch 1 ${serial[@]+"${serial[@]}"}

echo ""
echo "$((${#tests[@]} - ${#failed[@]} - skipped)) passed, ${#failed[@]} failed, $skipped skipped"
[ "$macos_only" -eq 0 ] || echo "$macos_only left out, as they need commands only macOS ships"
[ "$broken" -eq 0 ] || echo "$broken script(s) with a syntax error"
[ ${#failed[@]} -eq 0 ] && [ "$broken" -eq 0 ]
