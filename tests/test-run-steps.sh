#!/bin/bash
set -euo pipefail
# serial

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

steps="$SANDBOX/steps"
mkdir -p "$steps"
fake_step() {
    printf '%s\n' '#!/bin/bash' "echo \"$1\${*:+ \$*}\" >> \"$SANDBOX/ran\"" "$2" > "$steps/$1.sh"
}
fake_step first 'echo "first ran"'
fake_step broken 'echo "broken output" >&2; exit 1'
fake_step last 'echo "last ran"'
fake_step interrupted 'kill -INT $$'
fake_step attention '[ "${1:-}" != --status ] || { echo "  missing    something"; exit 3; }'
fake_step unknown '[ "${1:-}" != --status ] || { echo "  unknown    something"; exit 3; }'
# A report set -e cut short at a command that exited 3, such as jq
fake_step cut-short '[ "${1:-}" != --status ] || { echo "  ok         something"; echo "  missing in the text is not an item"; exit 3; }'
# A report that forgot status_result
fake_step quiet-missing '[ "${1:-}" != --status ] || echo "  missing    something"'
fake_step sigpipe 'exit 141'
# The step carries on after the runner's signal, as brew does under `|| result=1`
for sig in INT TERM HUP; do
    fake_step "caught-$sig" "kill -$sig \$PPID; echo \"caught-$sig carried on\"; exit 1"
done

# shellcheck disable=SC2034 # run_steps reads it
STEPS=(first last)
replace_fn step_script '[ -f "$steps/$1.sh" ] && echo "$steps/$1.sh"'

assert_exit 0 run_steps "" first last
assert_contains "$RUN_OUTPUT" "first ran"
assert_contains "$RUN_OUTPUT" "last ran"
assert_not_contains "$RUN_OUTPUT" "Failed steps"

rm -f "$SANDBOX/ran"
assert_exit 0 run_steps ""
assert_eq "first
last" "$(cat "$SANDBOX/ran")" "steps run with no names"

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

if is_macos; then
    this=macos other=ubuntu label="Ubuntu only"
else
    this=ubuntu other=macos label="macOS only"
fi
fake_step elsewhere "STEP_OS=$other"
fake_step here "STEP_OS=\"$this\""
rm -f "$SANDBOX/ran"
assert_exit 0 run_steps "" elsewhere here
assert_eq "elsewhere: skipped, $label" "$RUN_OUTPUT" "a run with a step for the other OS"
assert_eq "here" "$(cat "$SANDBOX/ran")" "steps run beside one for the other OS"
assert_exit 0 run_steps --status elsewhere
assert_eq "elsewhere:
  skipped    $label" "$RUN_OUTPUT" "the status of a step for the other OS"

rm -f "$SANDBOX/ran"
assert_exit 130 run_steps "" first interrupted last
assert_contains "$RUN_OUTPUT" "The interrupted step was interrupted; stopping."
assert_not_contains "$RUN_OUTPUT" "last ran"
assert_not_contains "$RUN_OUTPUT" "Failed steps"
assert_eq "first
interrupted" "$(cat "$SANDBOX/ran")" "steps run up to an interrupted one"

for sig in INT:130 TERM:143 HUP:129; do
    rm -f "$SANDBOX/ran"
    assert_exit "${sig#*:}" run_steps "" first "caught-${sig%:*}" last
    assert_contains "$RUN_OUTPUT" "caught-${sig%:*} carried on"
    assert_contains "$RUN_OUTPUT" "The caught-${sig%:*} step was interrupted; stopping."
    assert_not_contains "$RUN_OUTPUT" "Failed steps"
    assert_eq "first
caught-${sig%:*}" "$(cat "$SANDBOX/ran")" "steps run up to one during which the runner got SIG${sig%:*}"
done
rm -f "$SANDBOX/ran"
assert_exit 130 run_steps --status caught-INT last
assert_eq "caught-INT --status" "$(cat "$SANDBOX/ran")" "reports run up to one during which the runner got SIGINT"

rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" sigpipe last
assert_contains "$RUN_OUTPUT" "The sigpipe step failed."
assert_contains "$RUN_OUTPUT" "last ran"
assert_contains "$RUN_OUTPUT" "Failed steps: sigpipe"
assert_not_contains "$RUN_OUTPUT" "interrupted"

rm -f "$SANDBOX/ran"
assert_exit 3 run_steps --status first attention
assert_contains "$RUN_OUTPUT" "Needs attention: attention. Run: bash $0 attention"
assert_eq "first --status
attention --status" "$(cat "$SANDBOX/ran")" "steps run with --status"
assert_exit 3 run_steps --status unknown
assert_contains "$RUN_OUTPUT" "Needs attention: unknown."
assert_exit 3 run_steps --status quiet-missing
assert_contains "$RUN_OUTPUT" "Needs attention: quiet-missing."
assert_exit 1 run_steps --status cut-short
assert_contains "$RUN_OUTPUT" "The cut-short step failed."
assert_contains "$RUN_OUTPUT" "Failed steps: cut-short"
assert_not_contains "$RUN_OUTPUT" "Needs attention"
assert_exit 1 run_steps --status attention broken
assert_contains "$RUN_OUTPUT" "Needs attention: attention."
assert_contains "$RUN_OUTPUT" "Failed steps: broken"
assert_contains "$RUN_OUTPUT" "re-run them with: bash $0 --status broken"

as_os macos

stub uname '[ "$1" != -m ] || echo x86_64'
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" first
assert_contains "$RUN_OUTPUT" "Intel Macs aren't supported"
assert_exit 1 run_steps --status first
[ ! -e "$SANDBOX/ran" ] || fail "a step ran on an Intel Mac"
stub uname '[ "$1" != -m ] || echo arm64'

# shellcheck disable=SC2034 # run_steps reads them
MACOS_STEPS=(first mac) UBUNTU_STEPS=(first linux)
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" first nope
assert_contains "$RUN_OUTPUT" "Unknown step: nope. Steps on macOS: first mac. On Ubuntu: first linux"
[ ! -e "$SANDBOX/ran" ] || fail "a step ran despite an unknown step name"

# The runner must die of SIGINT, not exit 130: bash stops a caller after a command SIGINT killed
# but carries on after one that exited 130, as `just status` relies on
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
on_exit '[ -z "$CALLER_PID" ] || kill -KILL -- "-$CALLER_PID" 2> /dev/null'
# kill -0 still finds a zombie, so check ps
exited() {
    case "$(ps -o stat= -p "$1" 2> /dev/null)" in
        '' | Z*) return 0 ;;
    esac
    return 1
}
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
    # Job control keeps SIGINT deliverable; a background job ignores it
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

# Reload so step_script is the real one again
load_script lib/common.sh
# shellcheck source=../scripts/lib/runners.sh
source "$REPO_DIR/scripts/lib/runners.sh"
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
