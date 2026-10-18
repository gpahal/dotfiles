#!/bin/bash
# The items' check and fix functions are called by name
# shellcheck disable=SC2329
set -euo pipefail

# sudo_item lists a step's simple sudo item once, and its drivers build the pending list, apply the
# fixes, and print the status from it: every item, or only the ones named, in the order they were
# added. Apply re-checks each item first, runs each fix whether or not the one before it failed,
# and fails when any did.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

fixes="$SANDBOX/fixes"
: > "$fixes"
# Items a, b, and c are set up once their file exists. c's fix fails.
a_done() { [ -e "$SANDBOX/a" ]; }
b_done() { [ -e "$SANDBOX/b" ]; }
c_done() { [ -e "$SANDBOX/c" ]; }
fix_a() { echo a >> "$fixes" && touch "$SANDBOX/a"; }
fix_b() { echo b >> "$fixes" && touch "$SANDBOX/b"; }
fix_c() {
    echo c >> "$fixes"
    return 1
}
items() {
    sudo_items_reset
    sudo_item "A is set up" "Set up A" a_done fix_a
    sudo_item "B is set up" "Set up B" b_done fix_b
    sudo_item "C is set up" "Set up C" c_done fix_c
}
# Print the pending list the drivers build for the checks given, one item per line
pending_list() {
    local pending=()
    sudo_items_pending "$@"
    printf '%s\n' ${pending[@]+"${pending[@]}"}
}
report() {
    sudo_items_status "$@"
    status_result
}
items

# Nothing set up: every item is pending and missing
assert_eq "Set up A
Set up B
Set up C" "$(pending_list)" "pending items"
assert_exit 3 report
assert_eq "  missing    A is set up
  missing    B is set up
  missing    C is set up" "$RUN_OUTPUT" "status"

# Named checks pick the items, in the order they were added
assert_eq "Set up A
Set up C" "$(pending_list c_done a_done)" "pending items for c_done and a_done"
assert_exit 3 report b_done
assert_eq "  missing    B is set up" "$RUN_OUTPUT" "status for b_done"

# The pending list adds to the caller's
pending=(earlier)
sudo_items_pending b_done
assert_eq "earlier|Set up B" "$(printf '%s|' "${pending[@]}" | sed 's/|$//')" "pending after an earlier item"

# A is set up after the list was built: apply re-checks it, so only B's and C's fixes run. C's
# fix fails, which doesn't stop B's, and apply fails.
touch "$SANDBOX/a"
assert_exit 1 sudo_items_apply
assert_eq "b
c" "$(cat "$fixes")" "fixes run"
assert_exit 3 report
assert_eq "  ok         A is set up
  ok         B is set up
  missing    C is set up" "$RUN_OUTPUT" "status after apply"

# Applying only named items leaves the rest
: > "$fixes"
rm -f "$SANDBOX/b"
assert_exit 0 sudo_items_apply a_done b_done
assert_eq "b" "$(cat "$fixes")" "fixes run for a_done and b_done"

# Everything set up: nothing pending, and status is clean
touch "$SANDBOX/c"
assert_eq "" "$(pending_list)" "pending items once set up"
assert_exit 0 report
assert_not_contains "$RUN_OUTPUT" "missing"

# reset empties the list, so a step that adds its items again doesn't list them twice
items
items
assert_eq 3 "${#SUDO_ITEM_CHECK[@]}" "items after adding them twice"
sudo_items_reset
rm -f "$SANDBOX/a"
assert_eq "" "$(pending_list)" "pending items after reset"
assert_exit 0 sudo_items_apply
assert_exit 0 report
assert_eq "" "$RUN_OUTPUT" "status after reset"
test_done
