#!/bin/bash
# run_steps calls the step_script this test defines
# shellcheck disable=SC2329
set -euo pipefail

# run_steps, which both runners use: a failing step doesn't stop the rest, and the run ends with the
# "Failed steps" summary and exits 1. A step that exits 129, 130, or 143, as one does on SIGHUP,
# Ctrl-C, or SIGTERM, stops the run, and so does one of those signals reaching the runner while a
# step that carries on runs. A real runner stopped that way dies of the signal, so the script
# that ran it stops too. With --status, a step whose report has a missing or unknown item needs
# attention, whether it exits 0 or 3, and one that exits 3 without such an item failed. Fake steps
# stand in for the real ones. Then every step in each runner's real STEPS, on
# macOS and on Ubuntu, resolves through step_script to a script that exists, and a name outside
# both lists doesn't resolve. Those steps come from each runner's --help, with uname stubbed to
# report the OS.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

steps="$SANDBOX/steps"
mkdir -p "$steps"
# fake_step <name> <body>: a step script that logs its name and arguments, then runs the body
fake_step() {
    printf '%s\n' '#!/bin/bash' "echo \"$1\${*:+ \$*}\" >> \"$SANDBOX/ran\"" "$2" > "$steps/$1.sh"
}
fake_step first 'echo "first ran"'
fake_step broken 'echo "broken output" >&2; exit 1'
fake_step last 'echo "last ran"'
# Signals itself, as a step does when Ctrl-C reaches it
fake_step interrupted 'kill -INT $$'
fake_step attention '[ "${1:-}" != --status ] || { echo "  missing    something"; exit 3; }'
fake_step unknown '[ "${1:-}" != --status ] || { echo "  unknown    something"; exit 3; }'
# Exits 3 with no item needing attention, as a report that set -e cut short at a command that
# exited 3, such as jq on a filter that doesn't compile
fake_step cut-short '[ "${1:-}" != --status ] || { echo "  ok         something"; echo "  missing in the text is not an item"; exit 3; }'
# Reports a missing item, then exits 0, as a report that forgot status_result does
fake_step quiet-missing '[ "${1:-}" != --status ] || echo "  missing    something"'
# Exits 141, as one does on SIGPIPE
fake_step sigpipe 'exit 141'
# Ctrl-C reaches the runner too, but the step carries on and fails, as one does when brew catches
# SIGINT and exits 130 under `|| result=1`. Each signal the runner traps.
for sig in INT TERM HUP; do
    fake_step "caught-$sig" "kill -$sig \$PPID; echo \"caught-$sig carried on\"; exit 1"
done

# shellcheck disable=SC2034 # run_steps reads it
STEPS=(first last)
step_script() {
    [ -f "$steps/$1.sh" ] || return 1
    echo "$steps/$1.sh"
}

# Every step passes
assert_exit 0 run_steps "" first last
assert_contains "$RUN_OUTPUT" "first ran"
assert_contains "$RUN_OUTPUT" "last ran"
assert_not_contains "$RUN_OUTPUT" "Failed steps"

# With no names, every step in STEPS runs, in order
rm -f "$SANDBOX/ran"
assert_exit 0 run_steps ""
assert_eq "first
last" "$(cat "$SANDBOX/ran")" "steps run with no names"

# A failed step: the rest still run, and the summary names it with the command to re-run it
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" first broken last
assert_contains "$RUN_OUTPUT" "broken output"
assert_contains "$RUN_OUTPUT" "The broken step failed."
assert_contains "$RUN_OUTPUT" "last ran"
assert_contains "$RUN_OUTPUT" "Failed steps: broken
Fix the errors above, then re-run them with: bash $0 broken"
assert_eq "first
broken
last" "$(cat "$SANDBOX/ran")" "steps run around a failed one"

# An interrupted step stops the run with its status, before the next step and the summary
rm -f "$SANDBOX/ran"
assert_exit 130 run_steps "" first interrupted last
assert_contains "$RUN_OUTPUT" "The interrupted step was interrupted; stopping."
assert_not_contains "$RUN_OUTPUT" "last ran"
assert_not_contains "$RUN_OUTPUT" "Failed steps"
assert_eq "first
interrupted" "$(cat "$SANDBOX/ran")" "steps run up to an interrupted one"

# A signal the runner got stops it after the step, whatever the step's status, with the status
# that signal gives
for sig in INT:130 TERM:143 HUP:129; do
    rm -f "$SANDBOX/ran"
    assert_exit "${sig#*:}" run_steps "" first "caught-${sig%:*}" last
    assert_contains "$RUN_OUTPUT" "caught-${sig%:*} carried on"
    assert_contains "$RUN_OUTPUT" "The caught-${sig%:*} step was interrupted; stopping."
    assert_not_contains "$RUN_OUTPUT" "Failed steps"
    assert_eq "first
caught-${sig%:*}" "$(cat "$SANDBOX/ran")" "steps run up to one during which the runner got SIG${sig%:*}"
done
# With --status too
rm -f "$SANDBOX/ran"
assert_exit 130 run_steps --status caught-INT last
assert_eq "caught-INT --status" "$(cat "$SANDBOX/ran")" "reports run up to one during which the runner got SIGINT"

# Any other status above 128 is a failure, and the rest still run
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" sigpipe last
assert_contains "$RUN_OUTPUT" "The sigpipe step failed."
assert_contains "$RUN_OUTPUT" "last ran"
assert_contains "$RUN_OUTPUT" "Failed steps: sigpipe"
assert_not_contains "$RUN_OUTPUT" "interrupted"

# --status: each step gets --status, and one that exits 3 needs attention
rm -f "$SANDBOX/ran"
assert_exit 3 run_steps --status first attention
assert_contains "$RUN_OUTPUT" "Needs attention: attention. Run: bash $0 attention"
assert_eq "first --status
attention --status" "$(cat "$SANDBOX/ran")" "steps run with --status"
# An unknown item needs attention too
assert_exit 3 run_steps --status unknown
assert_contains "$RUN_OUTPUT" "Needs attention: unknown."
# So does a report with a missing item that exits 0
assert_exit 3 run_steps --status quiet-missing
assert_contains "$RUN_OUTPUT" "Needs attention: quiet-missing."
# A report that exits 3 without a missing or unknown item failed
assert_exit 1 run_steps --status cut-short
assert_contains "$RUN_OUTPUT" "The cut-short step failed."
assert_contains "$RUN_OUTPUT" "Failed steps: cut-short"
assert_not_contains "$RUN_OUTPUT" "Needs attention"
# A failure outranks needing attention, and the hint to re-run a failed report keeps --status
assert_exit 1 run_steps --status attention broken
assert_contains "$RUN_OUTPUT" "Needs attention: attention."
assert_contains "$RUN_OUTPUT" "Failed steps: broken"
assert_contains "$RUN_OUTPUT" "re-run them with: bash $0 --status broken"

is_macos() { true; }
is_ubuntu() { false; }

# An Intel Mac fails before any step runs, status included
stub uname '[ "$1" != -m ] || echo x86_64'
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" first
assert_contains "$RUN_OUTPUT" "Intel Macs aren't supported"
assert_exit 1 run_steps --status first
[ ! -e "$SANDBOX/ran" ] || fail "a step ran on an Intel Mac"
stub uname '[ "$1" != -m ] || echo arm64'

# An unknown step stops the run before any step runs. step_script takes either OS's steps, so the
# error lists both.
# shellcheck disable=SC2034 # run_steps reads them
MACOS_STEPS=(first mac) UBUNTU_STEPS=(first linux)
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" first nope
assert_contains "$RUN_OUTPUT" "Unknown step: nope. Steps on macOS: first mac. On Ubuntu: first linux"
[ ! -e "$SANDBOX/ran" ] || fail "a step ran despite an unknown step name"

# Ctrl-C reaches the whole process group: a script that runs a runner, the runner, and its step.
# The runner dies of SIGINT rather than exiting 130, so the script stops too, as bash stops after
# a command SIGINT killed but carries on after one that exited 130. `just status` runs the AI
# tools' report after the dotfiles' one this way.
runner_dir="$SANDBOX/runner"
mkdir -p "$runner_dir/slow"
printf '%s\n' '#!/bin/bash' "touch \"$SANDBOX/slow-started\"" 'sleep 30' > "$runner_dir/slow/install.sh"
printf '%s\n' '#!/bin/bash' 'set -euo pipefail' "source \"$REPO_DIR/lib/common.sh\"" \
    'MACOS_STEPS=(slow) UBUNTU_STEPS=(slow)' "STEPS_DIR=\"$runner_dir\"" 'runner_main test "" "$@"' \
    > "$runner_dir/setup.sh"
printf '%s\n' '#!/bin/bash' "\"$BASH\" \"$runner_dir/setup.sh\" \"\$@\" || a=\$?" 'echo continued' \
    > "$runner_dir/caller.sh"
stub uname 'case "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac'
CALLER_PID=""
# shellcheck disable=SC2016 # expanded at exit
on_exit '[ -z "$CALLER_PID" ] || kill -KILL -- "-$CALLER_PID" 2> /dev/null'
# Succeeds once a process has exited. A child that exited stays a zombie until waited for, and
# kill -0 still finds it.
exited() {
    case "$(ps -o stat= -p "$1" 2> /dev/null)" in
        '' | Z*) return 0 ;;
    esac
    return 1
}
# wait_until <command> [arg...]: succeeds once the command does, failing after 10 s
wait_until() {
    local i=0
    until "$@"; do
        [ "$i" -lt 100 ] || return 1
        sleep 0.1
        i=$((i + 1))
    done
}
for mode in "" --status; do
    rm -f "$SANDBOX/slow-started"
    status=0
    # Job control puts the caller in its own process group, as a terminal does, and keeps SIGINT
    # deliverable: without it, a background job ignores SIGINT
    set -m
    "$BASH" "$runner_dir/caller.sh" $mode > "$SANDBOX/caller.out" 2>&1 &
    CALLER_PID=$!
    set +m
    if wait_until test -e "$SANDBOX/slow-started"; then
        kill -INT -- "-$CALLER_PID"
        wait_until exited "$CALLER_PID" || kill -KILL -- "-$CALLER_PID"
    else
        fail "the runner's step didn't start${mode:+ with $mode}"
        kill -KILL -- "-$CALLER_PID"
    fi
    wait "$CALLER_PID" || status=$?
    CALLER_PID=""
    assert_eq 130 "$status" "the caller's status after Ctrl-C${mode:+ with $mode}"
    assert_file_contains "$SANDBOX/caller.out" "The slow step was interrupted; stopping."
    assert_file_not_contains "$SANDBOX/caller.out" continued
done

# The real runners' steps, from a fresh lib/common.sh, so step_script is the real one again
load_script lib/common.sh
# shellcheck source=../scripts/lib/runners.sh
source "$REPO_DIR/scripts/lib/runners.sh"
# Set LISTED to a runner's default steps on an OS (Darwin or Linux)
listed() {
    LISTED="$(runner_steps "$REPO_DIR/$1" "$2")" || fail "$1 --help failed on $2"
    [ -n "$LISTED" ] || fail "no steps read from $1 --help on $2"
}
for runner in setup.sh ai_tools/setup.sh; do
    listed "$runner" Darwin
    # shellcheck disable=SC2206 # step names have no spaces
    MACOS_STEPS=($LISTED)
    listed "$runner" Linux
    # shellcheck disable=SC2206
    UBUNTU_STEPS=($LISTED)
    # shellcheck disable=SC2034 # step_script reads it
    STEPS_DIR="$(dirname "$REPO_DIR/$runner")"
    for step in "${MACOS_STEPS[@]}" "${UBUNTU_STEPS[@]}"; do
        script="$(step_script "$step")" || {
            fail "$runner: step_script doesn't resolve $step"
            continue
        }
        [ -f "$script" ] || fail "$runner: $step resolves to $script, which doesn't exist"
    done
    for name in "" nope lib ../setup; do
        ! step_script "$name" > /dev/null || fail "$runner: step_script resolved \"$name\""
    done
done
test_done
