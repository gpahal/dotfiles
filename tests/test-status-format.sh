#!/bin/bash
set -euo pipefail

# Status lines: how each state renders and parses, which states need attention, and the lines
# health-alert.sh pushes.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ubuntu/health-alert.sh

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

every="source \"$REPO_DIR/lib/common.sh\""
for state in $STATUS_STATES; do
    every="$every
status_item $state \"the $state item\""
done
fake_step every "$every
echo \"  missing in the text is not an item\"
status_result"
calm="source \"$REPO_DIR/lib/common.sh\""
for state in ok skipped unverified info; do
    calm="$calm
status_item $state \"the $state item\""
done
fake_step calm "$calm
status_result"
# shellcheck disable=SC2034 # run_steps reads it
STEPS=(every calm)

assert_exit 3 run_steps --status
report="$RUN_OUTPUT"
assert_exit 0 run_steps --status calm

assert_eq "$STATUS_SUMMARY_ATTENTION: every. Run: bash $0 every
every: the missing item
every: the unknown item" "$(attention_lines <<< "$report")" "the lines health-alert.sh pushes"
test_done
