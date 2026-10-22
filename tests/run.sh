#!/bin/bash
set -uo pipefail

# Run every tests/test-*.sh, or the named ones, $TEST_JOBS at a time, under this script's bash.
# - A "# serial" line: the test runs alone, after the others.
# - "# os: macos" or "# os: ubuntu" in the first 20 lines: left out of a full run on the other
#   OS, and skipped there when named.
# - Exit 77 skips; TEST_FAIL_ON_SKIP=1 (CI) makes a skip fail.
# - A test over $TEST_TIMEOUT seconds (default 120) is killed and fails.

CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" || exit 1
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

# Sourcing all of lib/common.sh would change the tests' PATH and environment
eval "$(sed -n '/^run_bounded() {$/,/^}$/p' ../lib/common.sh)"
if ! declare -F run_bounded > /dev/null; then
    echo "No run_bounded() in lib/common.sh" >&2
    exit 1
fi

# For a test SIGKILLed before its EXIT trap ran
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

# The xargs worker; it exits 0 regardless, since xargs stops at a command that exits 255
run_test() {
    local dir="$tmp/$1" t="$2" pid status
    mkdir "$dir/home" "$dir/tmux"
    export HOME="$dir/home" TMUX_TMPDIR="$dir/tmux" TEST_SANDBOX_PARENT="$dir"
    if ! "$BASH" -n "$t" > "$dir/output" 2>&1; then
        status=2
    else
        # Own process group, so a timeout reaches what the test started, and SIGINT stays
        # deliverable. The braces hide macOS bash's harmless "child setpgid" error.
        set -m
        { run_bounded "$TEST_TIMEOUT" "$BASH" "$t" < /dev/null > "$dir/output" 2>&1 & } 2>/dev/null
        pid=$!
        set +m
        echo "$pid" > "$dir/pgid"
        # Hides bash's "Terminated"
        { wait "$pid"; } 2>/dev/null
        status=$?
        if [ "$status" -eq 124 ]; then
            echo "Killed: took longer than ${TEST_TIMEOUT}s" >> "$dir/output"
            status=1
            # Without timeout(1), run_bounded kills only the test, not what it started
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

# Prints the OS a test's "# os:" mark names, and succeeds, when it isn't this one
other_os() {
    case "$(sed -n '1,20s/^# os: \(.*\)$/\1/p' "$1" | head -n 1)" in
        macos) ! "$on_macos" && echo macOS ;;
        ubuntu) "$on_macos" && echo Ubuntu ;;
        *) return 1 ;;
    esac
}

tests=()
other_os_left_out=0
other_os_named=()
if [ $# -eq 0 ]; then
    for t in test-*.sh; do
        [ -e "$t" ] || continue
        if other_os "$t" > /dev/null; then
            other_os_left_out=$((other_os_left_out + 1))
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
        if os="$(other_os "$t")"; then
            other_os_named+=("$t $os")
            continue
        fi
        tests+=("$t")
    done
fi

jobs="${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
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

# Process groups of this runner's descendants, other than its own
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
# Ctrl-C doesn't reach the tests' own process groups
# shellcheck disable=SC2329
interrupted() {
    local groups group i alive
    trap '' INT TERM
    # The recorded groups too, should ps be missing
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

# Report in the order given, so output doesn't depend on which test ends first
run_batch() {
    local jobs="$1" i
    shift
    [ $# -gt 0 ] || return 0
    for i in "$@"; do
        mkdir "$tmp/$i"
        printf '%s\0%s\0' "$i" "${tests[i]}"
    done > "$tmp/batch"
    # Job control: see run_test
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

for named in ${other_os_named[@]+"${other_os_named[@]}"}; do
    t="${named%% *}"
    if [ "${TEST_FAIL_ON_SKIP:-}" == 1 ]; then
        echo "FAIL  $t"
        echo "    Skipped, as it runs only on ${named#* }, and TEST_FAIL_ON_SKIP=1 fails a skip"
        failed+=("$t")
    else
        echo "SKIP  $t"
        echo "    It runs only on ${named#* }"
        skipped=$((skipped + 1))
    fi
done

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
echo "$((${#tests[@]} + ${#other_os_named[@]} - ${#failed[@]} - skipped)) passed, ${#failed[@]} failed, $skipped skipped"
[ "$other_os_left_out" -eq 0 ] || echo "$other_os_left_out left out, as they need commands only the other OS ships"
[ ${#failed[@]} -eq 0 ]
