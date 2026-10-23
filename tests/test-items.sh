#!/bin/bash
# shellcheck disable=SC2329,SC2034 # the item drivers call the checks and read what they set

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

# An item with no status text is apply-only: status leaves it out, apply lists and fixes it. The
# items reset leaves only these.
items_reset
item --sudo "" "Set up A" a_done fix_a
item "D is set up" "Set up D" d_done fix_d
rm -f "$SANDBOX/a" "$SANDBOX/d"
assert_exit 3 report
assert_eq "  missing    D is set up" "$RUN_OUTPUT" "status skips an apply-only item"
assert_eq "Set up A" "$(pending_list)" "pending apply-only item"

# A check may set ITEM_DETAIL and ITEM_STATE; each check starts with both empty, and an exit code
# other than 0 or 1 is still missing
e_check() {
    ITEM_DETAIL="written but not in effect"
    return 1
}
f_check() {
    ITEM_STATE=info
    ITEM_DETAIL="nothing to do here"
    return 1
}
g_check() {
    ITEM_STATE=unverified
    return 1
}
h_check() { return 2; }
fix_named() { echo "$1" >> "$fixes"; }
items_reset
item --sudo --hint "re-run it" "E is set up" "Set up E" e_check "fix_named e"
item --sudo "F is set up" "Set up F" f_check "fix_named f"
item --sudo --hint "re-run it" "G is set up" "Set up G" g_check "fix_named g"
item --sudo --hint "re-run it" "H is set up" "Set up H" h_check "fix_named h"
item "I is set up" "Set up I" true "fix_named i"
assert_exit 3 report
assert_eq "  missing    E is set up: written but not in effect; re-run it
  info       F is set up: nothing to do here
  unverified G is set up
  missing    H is set up; re-run it
  ok         I is set up" "$RUN_OUTPUT" "status with details and states"
# skipped and info count as done; other states as pending
assert_eq "Set up E
Set up G
Set up H" "$(pending_list)" "pending items with states"
assert_exit 0 items_ok f_check true
assert_exit 1 items_ok g_check
: > "$fixes"
assert_exit 0 items_apply
assert_eq "e
g
h" "$(cat "$fixes")" "fixes run for items with states"

# items_apply_confirmed: --done when nothing is pending; notes join the sudo list; a result line
# follows a yes
rm -f "$SANDBOX"/[abcd]
items
touch "$SANDBOX/a" "$SANDBOX/b" "$SANDBOX/c" "$SANDBOX/d"
: > "$fixes"
assert_exit 0 items_apply_confirmed --done "  A to D are already set up."
assert_eq "  A to D are already set up." "$RUN_OUTPUT" "nothing pending, with --done"
assert_exit 0 items_apply_confirmed
assert_eq "" "$RUN_OUTPUT" "nothing pending, without --done"
assert_eq "" "$(cat "$fixes")" "fixes run with nothing pending"

answer yes
rm -f "$SANDBOX/a"
assert_exit 0 items_apply_confirmed --done "  Unused." --note "Set up E" --note "Set up F"
assert_eq "  These need sudo:
    - Set up A
    - Set up E
    - Set up F
  Apply them?
  Applied." "$RUN_OUTPUT" "a yes with notes"
assert_eq "a" "$(cat "$fixes")" "fixes run after a yes"

# A note alone asks too
assert_exit 0 items_apply_confirmed --note "Set up E"
assert_eq "  These need sudo:
    - Set up E
  Apply them?
  Applied." "$RUN_OUTPUT" "a note alone"

rm -f "$SANDBOX/c" "$SANDBOX/d"
: > "$fixes"
assert_exit 1 items_apply_confirmed
assert_eq "  These need sudo:
    - Set up C
  Apply them?
c
d" "$(printf '%s\n' "$RUN_OUTPUT" | sed '/Applied the rest/d'; cat "$fixes")" "a yes with a failing fix"
assert_contains "$RUN_OUTPUT" "  Applied the rest. Some changes failed; see the errors above."
assert_eq "  Applied the rest. Some changes failed; see the errors above." \
    "$(items_apply_confirmed 2>&1 > /dev/null)" "the failure line, on stderr"

# A no applies only what needs no sudo, after one line saying so
answer no
rm -f "$SANDBOX/d"
: > "$fixes"
assert_exit 0 items_apply_confirmed
assert_eq "  These need sudo:
    - Set up C
  Apply them?
  Left unchanged. Run this step from a terminal to apply them." "$RUN_OUTPUT" "a no"
assert_eq "d" "$(cat "$fixes")" "fixes run after a no"

# No sudo needed: no question and no result line
touch "$SANDBOX/c"
rm -f "$SANDBOX/d"
: > "$fixes"
assert_exit 0 items_apply_confirmed
assert_eq "" "$RUN_OUTPUT" "only items that need no sudo"
assert_eq "d" "$(cat "$fixes")" "fixes run without sudo"

# One memo scope asks once, and its checks can tell when the answer was yes
confirmed_log="$SANDBOX/confirmed"
logged_c_done() {
    if sudo_confirmed; then echo yes >> "$confirmed_log"; else echo no >> "$confirmed_log"; fi
    c_done
}
twice() {
    local MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    items_reset
    item --sudo "A is set up" "Set up A" a_done fix_a
    item --sudo "C is set up" "Set up C" logged_c_done fix_c
    item --sudo "B is set up" "Set up B" b_done fix_b
    item "D is set up" "Set up D" d_done fix_d
    items_apply_confirmed a_done logged_c_done || true
    items_apply_confirmed b_done d_done
}
rm -f "$SANDBOX"/[abcd]
: > "$fixes"
: > "$confirmed_log"
answer yes
assert_exit 0 twice
assert_eq "  These need sudo:
    - Set up A
    - Set up C
  Apply them?
  Applied." "$(printf '%s\n' "$RUN_OUTPUT" | sed '/Applied the rest/d')" "two calls in one scope after a yes"
assert_eq "a
c
b
d" "$(cat "$fixes")" "fixes run by two calls in one scope after a yes"
assert_eq "no
yes" "$(cat "$confirmed_log")" "sudo_confirmed while listing, then applying"
rm -f "$SANDBOX"/[abcd]
: > "$fixes"
answer no
assert_exit 0 twice
assert_eq "  These need sudo:
    - Set up A
    - Set up C
  Apply them?
  Left unchanged. Run this step from a terminal to apply them." "$RUN_OUTPUT" "two calls in one scope after a no"
assert_eq "d" "$(cat "$fixes")" "fixes run by two calls in one scope after a no"
# Without a scope, each call asks
rm -f "$SANDBOX"/[abcd]
items_reset
item --sudo "A is set up" "Set up A" a_done fix_a
item --sudo "B is set up" "Set up B" b_done fix_b
assert_exit 0 eval 'items_apply_confirmed a_done; items_apply_confirmed b_done'
assert_eq 2 "$(grep -c 'These need sudo' <<< "$RUN_OUTPUT")" "questions without a scope"
test_done
