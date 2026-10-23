#!/bin/bash
# shellcheck disable=SC2329

# The item helpers: status, pending lists, and apply with sudo items, --no-sudo, and failed fixes.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script lib/common.sh

fixes="$SANDBOX/fixes"
: > "$fixes"
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
# C's fix fails, and comes before B's
items() {
    items_reset
    item --sudo "A is set up" "Set up A" a_done fix_a
    item --sudo "C is set up" "Set up C" c_done fix_c
    item --sudo --hint "run make-b" "B is set up" "Set up B" b_done fix_b
    item "D is set up" "Set up D" d_done fix_d
}
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

assert_eq "Set up A
Set up C
Set up B" "$(pending_list)" "pending items"
assert_exit 3 report
assert_eq "  missing    A is set up
  missing    C is set up
  missing    B is set up; run make-b
  missing    D is set up" "$RUN_OUTPUT" "status"

# Named checks pick items in the order they were added
assert_eq "Set up A
Set up C" "$(pending_list c_done a_done)" "pending items for c_done and a_done"
assert_exit 3 report b_done
assert_eq "  missing    B is set up; run make-b" "$RUN_OUTPUT" "status for b_done"

assert_exit 0 items_apply --no-sudo
assert_eq "d" "$(cat "$fixes")" "fixes run with --no-sudo"
: > "$fixes"

# apply re-checks each item, so A, set up after the list was built, doesn't run, and C's failure
# doesn't stop B's fix
touch "$SANDBOX/a"
assert_exit 1 items_apply
assert_eq "c
b" "$(cat "$fixes")" "fixes run"
assert_exit 3 report
assert_eq "  ok         A is set up
  missing    C is set up
  ok         B is set up
  ok         D is set up" "$RUN_OUTPUT" "status after apply"

touch "$SANDBOX/c"
assert_eq "" "$(pending_list)" "pending items once set up"
assert_exit 0 report
assert_not_contains "$RUN_OUTPUT" "missing"
assert_exit 0 items_ok

assert_exit 2 item --sudo "E is set up" "Set up E" e_done

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
