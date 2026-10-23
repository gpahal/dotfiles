#!/bin/bash

# run_steps with fake steps: failures, interrupts, OS and STEP_NEEDS skips, and --status summaries.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script lib/common.sh
load_script lib/runner.sh

fake_step first 'echo "first ran"'
fake_step broken 'echo "broken output" >&2; exit 1'
fake_step last 'echo "last ran"'
fake_step interrupted 'kill -INT $$'
fake_step attention '[ "${1:-}" != --status ] || { echo "  missing    something"; exit 3; }'
fake_step unknown '[ "${1:-}" != --status ] || { echo "  unknown    something"; exit 3; }'
# A report set -e cut short at a command that exited 3, such as jq
fake_step cut-short '[ "${1:-}" != --status ] || { echo "  ok         something"; echo "  missing in the text is not an item"; exit 3; }'
fake_step sigpipe 'exit 141'
# The step carries on after the runner's SIGINT, as brew does under `|| result=1`
fake_step caught-INT 'kill -INT $PPID; echo "caught-INT carried on"; exit 1'

# shellcheck disable=SC2034 # run_steps reads it
STEPS=(first last)

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
# The step's own main skips it, as it does when run alone
for step in elsewhere:$other here:$this; do
    fake_step "${step%%:*}" "STEP_OS=${step#*:}
source \"$REPO_DIR/lib/common.sh\"
status() { echo \"  ok         ${step%%:*} reported\"; }
apply() { echo \"${step%%:*} applied\"; }
main \"\$@\""
done
rm -f "$SANDBOX/ran"
assert_exit 0 run_steps "" elsewhere here
assert_eq "elsewhere: skipped, $label
here applied" "$RUN_OUTPUT" "a run with a step for the other OS"
assert_exit 0 run_steps --status elsewhere here
assert_eq "elsewhere:
  skipped    $label
here:
  ok         here reported" "$RUN_OUTPUT" "the status of a step for the other OS"

rm -f "$SANDBOX/ran"
assert_exit 130 run_steps "" first interrupted last
assert_contains "$RUN_OUTPUT" "The interrupted step was interrupted; stopping."
assert_not_contains "$RUN_OUTPUT" "last ran"
assert_not_contains "$RUN_OUTPUT" "Failed steps"
assert_eq "first
interrupted" "$(cat "$SANDBOX/ran")" "steps run up to an interrupted one"

rm -f "$SANDBOX/ran"
assert_exit 130 run_steps "" first caught-INT last
assert_contains "$RUN_OUTPUT" "caught-INT carried on"
assert_contains "$RUN_OUTPUT" "The caught-INT step was interrupted; stopping."
assert_not_contains "$RUN_OUTPUT" "Failed steps"
assert_eq "first
caught-INT" "$(cat "$SANDBOX/ran")" "steps run up to one during which the runner got SIGINT"
# Reports run at once, so later ones have started; they print nothing after the interrupted one
assert_exit 130 run_steps --status caught-INT last
assert_contains "$RUN_OUTPUT" "The caught-INT step was interrupted; stopping."
assert_not_contains "$RUN_OUTPUT" "last ran"
assert_not_contains "$RUN_OUTPUT" "Failed steps"

rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" sigpipe last
assert_contains "$RUN_OUTPUT" "The sigpipe step failed."
assert_contains "$RUN_OUTPUT" "last ran"
assert_contains "$RUN_OUTPUT" "Failed steps: sigpipe"
assert_not_contains "$RUN_OUTPUT" "interrupted"

rm -f "$SANDBOX/ran"
assert_exit 3 run_steps --status first attention
assert_contains "$RUN_OUTPUT" "Needs attention: attention. Run: bash $0 attention"
assert_eq "attention --status
first --status" "$(sort "$SANDBOX/ran")" "steps run with --status"
assert_exit 3 run_steps --status unknown
assert_contains "$RUN_OUTPUT" "Needs attention: unknown."
assert_exit 1 run_steps --status cut-short
assert_contains "$RUN_OUTPUT" "The cut-short step failed."
assert_contains "$RUN_OUTPUT" "Failed steps: cut-short"
assert_not_contains "$RUN_OUTPUT" "Needs attention"
assert_exit 1 run_steps --status attention broken
assert_contains "$RUN_OUTPUT" "Needs attention: attention."
assert_contains "$RUN_OUTPUT" "Failed steps: broken"
assert_contains "$RUN_OUTPUT" "re-run them with: bash $0 --status broken"

# Reports run at once: slow ends only after fast has, yet prints first. stdout is the serial
# run's, and each report's stderr follows it.
fake_step slow '[ "${1:-}" != --status ] || {
i=0
until [ -e "$SANDBOX/fast-done" ]; do
    [ "$i" -lt 100 ] || { echo "fast never finished" >&2; exit 1; }
    sleep 0.1
    i=$((i + 1))
done
echo "slow warning" >&2
echo "  ok         slow"
}'
fake_step fast '[ "${1:-}" != --status ] || { echo "  missing    fast"; echo "fast warning" >&2; touch "$SANDBOX/fast-done"; exit 3; }'
status=0
out="$(run_steps --status slow fast 2> "$SANDBOX/status.err")" || status=$?
assert_eq 3 "$status" "the exit of parallel reports"
assert_eq "slow:
  ok         slow
fast:
  missing    fast

Needs attention: fast. Run: bash $0 fast" "$out" "parallel reports' stdout"
assert_eq "slow warning
fast warning" "$(cat "$SANDBOX/status.err")" "parallel reports' stderr"
assert_eq "" "$(ls -A "$TMPDIR")" "temp files left after reports"

# An interrupt stops the reports and what they started, and prints none after the current one
fake_step hang '[ "${1:-}" != --status ] || { sleep 30 & echo "$!" > "$SANDBOX/hang-child"; wait; }'
fake_step stopper '[ "${1:-}" != --status ] || { until [ -s "$SANDBOX/hang-child" ]; do sleep 0.1; done; kill -INT "$PPID"; }'
fake_step after '[ "${1:-}" != --status ] || echo "  ok         after"'
assert_exit 130 run_steps --status hang stopper after
assert_contains "$RUN_OUTPUT" "The hang step was interrupted; stopping."
assert_not_contains "$RUN_OUTPUT" "after"
assert_not_contains "$RUN_OUTPUT" "Failed steps"
wait_for process_exited "$(cat "$SANDBOX/hang-child")" || fail "a report's child outlived the interrupt"
assert_eq "" "$(ls -A "$TMPDIR")" "temp files left after interrupted reports"

# STEP_NEEDS: a failed step skips the steps that need it, directly or not, but not their reports
fake_step homebrew 'exit 1'
fake_step runtimes 'STEP_NEEDS="homebrew"'
fake_step lazygit
fake_step skills 'STEP_NEEDS=runtimes'
# shellcheck disable=SC2034 # run_steps reads it
STEPS=(homebrew runtimes lazygit skills)
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps ""
assert_contains "$RUN_OUTPUT" "Failed steps: homebrew runtimes skills"
assert_eq "homebrew
lazygit" "$(cat "$SANDBOX/ran")" "steps run after homebrew failed"
rm -f "$SANDBOX/ran"
assert_exit 0 run_steps "" runtimes
assert_eq "runtimes" "$(cat "$SANDBOX/ran")" "steps run without homebrew in the run"
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps --status homebrew runtimes
assert_eq "homebrew --status
runtimes --status" "$(sort "$SANDBOX/ran")" "reports run after homebrew's failed"

as_os macos

stub_uname Darwin x86_64
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" first
assert_contains "$RUN_OUTPUT" "Intel Macs aren't supported"
assert_exit 1 run_steps --status first
[ ! -e "$SANDBOX/ran" ] || fail "a step ran on an Intel Mac"
stub_uname Darwin

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
printf '%s\n' '#!/bin/bash' 'sleep 30 &' "echo \"\$!\" > \"$SANDBOX/slow-child\"" \
    "touch \"$SANDBOX/slow-started\"" 'wait' > "$runner_dir/slow/install.sh"
printf '%s\n' '#!/bin/bash' 'set -euo pipefail' "source \"$REPO_DIR/lib/common.sh\"" \
    "source \"$REPO_DIR/lib/runner.sh\"" 'MACOS_STEPS=(slow) UBUNTU_STEPS=(slow)' \
    "STEPS_DIR=\"$runner_dir\"" 'runner_main test "" "$@"' > "$runner_dir/setup.sh"
printf '%s\n' '#!/bin/bash' "\"$BASH\" \"$runner_dir/setup.sh\" \"\$@\" || a=\$?" 'echo continued' \
    > "$runner_dir/caller.sh"
stub_uname Darwin
status=0
caller=""
# A failed assertion or timeout mustn't leave the caller's group running
trap 'status=$?; set +e; [ -z "$caller" ] || kill -KILL -- "-$caller" 2> /dev/null; (exit "$status"); _sandbox_exit' EXIT
# Job control keeps SIGINT deliverable; a background job ignores it
set -m
"$BASH" "$runner_dir/caller.sh" --status > "$SANDBOX/caller.out" 2>&1 &
caller=$!
set +m
if wait_for test -e "$SANDBOX/slow-started"; then
    kill -INT -- "-$caller"
    wait_for process_exited "$caller" || kill -KILL -- "-$caller"
else
    fail "the runner's step didn't start"
    kill -KILL -- "-$caller"
fi
wait "$caller" || status=$?
assert_eq 130 "$status" "the caller's status after Ctrl-C"
assert_file_contains "$SANDBOX/caller.out" "The slow step was interrupted; stopping."
assert_file_not_contains "$SANDBOX/caller.out" continued
wait_for process_exited "$(cat "$SANDBOX/slow-child")" || fail "the step's child outlived Ctrl-C"
test_done
