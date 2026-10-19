#!/bin/bash
# The items' check and fix functions are called by name
# shellcheck disable=SC2329
set -euo pipefail

# item lists a step's simple item once, and its drivers build the pending list, apply the fixes,
# and print the status from it: every item, or only the ones named, in the order they were added.
# Only --sudo items are pending, and --no-sudo applies only the rest. Apply re-checks each item
# first, runs each fix whether or not the one before it failed, and fails when any did. A --hint
# goes on a missing status item.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

fixes="$SANDBOX/fixes"
: > "$fixes"
# Items a, b, c, and d are set up once their file exists. c's fix fails. d needs no sudo.
a_done() { [ -e "$SANDBOX/a" ]; }
b_done() { [ -e "$SANDBOX/b" ]; }
c_done() { [ -e "$SANDBOX/c" ]; }
d_done() { [ -e "$SANDBOX/d" ]; }
fix_a() { echo a >> "$fixes" && touch "$SANDBOX/a"; }
fix_b() { echo b >> "$fixes" && touch "$SANDBOX/b"; }
fix_c() {
    echo c >> "$fixes"
    return 1
}
fix_d() { echo d >> "$fixes" && touch "$SANDBOX/d"; }
items() {
    items_reset
    item --sudo "A is set up" "Set up A" a_done fix_a
    item --sudo --hint "run make-b" "B is set up" "Set up B" b_done fix_b
    item --sudo "C is set up" "Set up C" c_done fix_c
    item "D is set up" "Set up D" d_done fix_d
}
# Print the pending list the drivers build for the checks given, one item per line
pending_list() {
    local pending=()
    items_pending "$@"
    printf '%s\n' ${pending[@]+"${pending[@]}"}
}
report() {
    items_status "$@"
    status_result
}
items

# Nothing set up: every sudo item is pending, and every item missing, B with its hint
assert_eq "Set up A
Set up B
Set up C" "$(pending_list)" "pending items"
assert_exit 3 report
assert_eq "  missing    A is set up
  missing    B is set up; run make-b
  missing    C is set up
  missing    D is set up" "$RUN_OUTPUT" "status"

# Named checks pick the items, in the order they were added
assert_eq "Set up A
Set up C" "$(pending_list c_done a_done)" "pending items for c_done and a_done"
assert_exit 3 report b_done
assert_eq "  missing    B is set up; run make-b" "$RUN_OUTPUT" "status for b_done"

# The pending list adds to the caller's
pending=(earlier)
items_pending b_done
assert_eq "earlier|Set up B" "$(printf '%s|' "${pending[@]}" | sed 's/|$//')" "pending after an earlier item"

# Declined sudo: --no-sudo runs only the items without --sudo
assert_exit 0 items_apply --no-sudo
assert_eq "d" "$(cat "$fixes")" "fixes run with --no-sudo"
: > "$fixes"

# A is set up after the list was built: apply re-checks it, so only B's and C's fixes run. C's
# fix fails, which doesn't stop B's, and apply fails.
touch "$SANDBOX/a"
assert_exit 1 items_apply
assert_eq "b
c" "$(cat "$fixes")" "fixes run"
assert_exit 3 report
assert_eq "  ok         A is set up
  ok         B is set up
  missing    C is set up
  ok         D is set up" "$RUN_OUTPUT" "status after apply"

# Applying only named items leaves the rest
: > "$fixes"
rm -f "$SANDBOX/b" "$SANDBOX/d"
assert_exit 0 items_apply a_done b_done
assert_eq "b" "$(cat "$fixes")" "fixes run for a_done and b_done"
assert_exit 0 items_apply --no-sudo d_done
touch "$SANDBOX/c"

# Everything set up: nothing pending, and status is clean
assert_eq "" "$(pending_list)" "pending items once set up"
assert_exit 0 report
assert_not_contains "$RUN_OUTPUT" "missing"

# A malformed item fails
assert_exit 2 item --sudo "E is set up" "Set up E" e_done
assert_contains "$RUN_OUTPUT" "item: expected <status text> <pending text> <check-fn> <fix-fn>, got 3 arguments"

# reset empties the list, so a step that adds its items again doesn't list them twice
items
items
assert_eq 4 "${#ITEM_CHECK[@]}" "items after adding them twice"
items_reset
rm -f "$SANDBOX/a"
assert_eq "" "$(pending_list)" "pending items after reset"
assert_exit 0 items_apply
assert_exit 0 report
assert_eq "" "$RUN_OUTPUT" "status after reset"
test_done
