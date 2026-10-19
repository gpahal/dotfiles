#!/bin/bash
set -euo pipefail

# The status format lib/common.sh defines once, and its two consumers. A fake step prints an item
# in each state with status_item; run_steps' classifier counts only missing and unknown as needing
# attention, and ubuntu/health-alert.sh's attention_lines pushes only those, under their step,
# after the summary line. Text that only looks like an item is neither.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ubuntu/health-alert.sh

# Every state renders as two spaces, the state padded to its width, a space, and the text, and
# parses back to the same state and text
for state in $STATUS_STATES; do
    line="$(status_item "$state" "the $state item: with  spaces")"
    assert_eq "$(printf '  %-10s %s' "$state" "the $state item: with  spaces")" "$line" "how $state renders"
    status_parse_line "$line" || fail "status_parse_line didn't parse the $state item"
    assert_eq "$state" "$STATUS_LINE_STATE" "the state parsed from the $state item"
    assert_eq "the $state item: with  spaces" "$STATUS_LINE_TEXT" "the text parsed from the $state item"
done
for line in "  missing in the text is not an item" "  bogus      text" "missing    no indent" \
    "Needs attention: x. Run: bash setup.sh x"; do
    ! status_parse_line "$line" || fail "status_parse_line parsed '$line'"
done

# A fake step whose report has an item in each state, with the lib's status_item
steps="$SANDBOX/steps"
mkdir -p "$steps"
{
    echo '#!/bin/bash'
    echo "source \"$REPO_DIR/lib/common.sh\""
    for state in $STATUS_STATES; do
        echo "status_item $state \"the $state item\""
    done
    echo 'echo "  missing in the text is not an item"'
    echo 'status_result'
} > "$steps/every.sh"
{
    echo '#!/bin/bash'
    echo "source \"$REPO_DIR/lib/common.sh\""
    for state in ok skipped unverified info; do
        echo "status_item $state \"the $state item\""
    done
    echo 'status_result'
} > "$steps/calm.sh"
# shellcheck disable=SC2034 # run_steps reads it
STEPS=(every calm)
replace_fn step_script '[ -f "$steps/$1.sh" ] && echo "$steps/$1.sh"'

# run_steps: the step with missing and unknown items needs attention, the other doesn't
assert_exit 3 run_steps --status
report="$RUN_OUTPUT"
assert_contains "$report" "every:
  ok         the ok item"
assert_contains "$report" "$STATUS_SUMMARY_ATTENTION: every. Run: bash $0 every"
assert_not_contains "$report" "calm."
assert_exit 0 run_steps --status calm

# health-alert.sh: the summary line, then each item that needs attention, under its step
assert_eq "$STATUS_SUMMARY_ATTENTION: every. Run: bash $0 every
every: the missing item
every: the unknown item" "$(attention_lines <<< "$report")" "the lines health-alert.sh pushes"
test_done
