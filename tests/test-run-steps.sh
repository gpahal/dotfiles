#!/bin/bash
# run_steps calls the step_script this test defines
# shellcheck disable=SC2329
set -euo pipefail

# run_steps, which both runners use: a failing step doesn't stop the rest, and the run ends with the
# "Failed steps" summary and exits 1. A step that exits 129, 130, or 143, as one does on SIGHUP,
# Ctrl-C, or SIGTERM, stops the run. With --status, a step that exits 3 is listed as needing
# attention. Fake steps stand in for the real ones.

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
fake_step attention '[ "${1:-}" != --status ] || exit 3'
# Exits 141, as one does on SIGPIPE
fake_step sigpipe 'exit 141'
fake_step terminated 'kill -TERM $$'

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

# A step killed by SIGTERM stops the run too
rm -f "$SANDBOX/ran"
assert_exit 143 run_steps "" terminated last
assert_not_contains "$RUN_OUTPUT" "last ran"

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
# A failure outranks needing attention, and the hint to re-run a failed report keeps --status
assert_exit 1 run_steps --status attention broken
assert_contains "$RUN_OUTPUT" "Needs attention: attention."
assert_contains "$RUN_OUTPUT" "Failed steps: broken"
assert_contains "$RUN_OUTPUT" "re-run them with: bash $0 --status broken"

# macOS before 15 gets a warning, and the run carries on
is_macos() { true; }
is_ubuntu() { false; }
stub uname '[ "$1" != -m ] || echo arm64'
stub sw_vers '[ "$1" != -productVersion ] || echo 14.7.2'
assert_exit 0 run_steps "" first
assert_contains "$RUN_OUTPUT" "Warning: setup needs macOS 15 or later, not 14.7.2."
assert_contains "$RUN_OUTPUT" "first ran"
for version in 15.0 26.1; do
    stub sw_vers "[ \"\$1\" != -productVersion ] || echo $version"
    assert_exit 0 run_steps "" first
    assert_not_contains "$RUN_OUTPUT" "Warning" "the run on macOS $version"
done

# An Intel Mac fails before any step runs, status included
stub uname '[ "$1" != -m ] || echo x86_64'
stub sw_vers '[ "$1" != -productVersion ] || echo 15.7'
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" first
assert_contains "$RUN_OUTPUT" "Intel Macs aren't supported"
assert_exit 1 run_steps --status first
[ ! -e "$SANDBOX/ran" ] || fail "a step ran on an Intel Mac"
stub uname '[ "$1" != -m ] || echo arm64'

# An unknown step stops the run before any step runs
rm -f "$SANDBOX/ran"
assert_exit 1 run_steps "" first nope
assert_contains "$RUN_OUTPUT" "Unknown step: nope. Steps: first last"
[ ! -e "$SANDBOX/ran" ] || fail "a step ran despite an unknown step name"
# step_script takes either OS's steps, so the error lists both when the runner sets them
# shellcheck disable=SC2034 # unknown_step reads them
MACOS_STEPS=(first mac) UBUNTU_STEPS=(first linux)
assert_exit 1 run_steps "" nope
assert_contains "$RUN_OUTPUT" "Unknown step: nope. Steps on macOS: first mac. On Ubuntu: first linux"
test_done
