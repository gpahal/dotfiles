#!/bin/bash
set -euo pipefail

# just status runs both runners whatever the first returns, then exits 1 when either failed, 3
# when either needs attention, and 0 otherwise, so a scheduled run notices a step that needs
# attention. Stub runners that exit a given code stand in for the real ones. No recipe runs an
# argument as shell code.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

just="$(command -v just || true)"
[ -n "$just" ] || skip "just isn't installed"
setup_sandbox

repo="$SANDBOX/repo"
mkdir -p "$repo/ai_tools"
cp "$REPO_DIR/justfile" "$repo/"
# Each stub logs its arguments and exits the code in its variable
printf '%s\n' 'echo "setup.sh $*" >> "$RAN"' 'exit "$SETUP_CODE"' > "$repo/setup.sh"
printf '%s\n' 'echo "ai_tools/setup.sh $*" >> "$RAN"' 'exit "$AI_CODE"' > "$repo/ai_tools/setup.sh"
export RAN="$SANDBOX/ran"

for a in 0 1 3; do
    for b in 0 1 3; do
        if [ "$a" -eq 1 ] || [ "$b" -eq 1 ]; then
            want=1
        elif [ "$a" -eq 3 ] || [ "$b" -eq 3 ]; then
            want=3
        else
            want=0
        fi
        rm -f "$RAN"
        SETUP_CODE=$a AI_CODE=$b assert_exit "$want" "$just" --justfile "$repo/justfile" status
        assert_eq "setup.sh --status
ai_tools/setup.sh --status" "$(cat "$RAN")" "runners run for codes $a and $b"
    done
done

# Another failure code also fails the recipe, and quick passes --quick to both
rm -f "$RAN"
SETUP_CODE=0 AI_CODE=2 assert_exit 1 "$just" --justfile "$repo/justfile" status quick
assert_eq "setup.sh --status --quick
ai_tools/setup.sh --status --quick" "$(cat "$RAN")" "runners run for quick"
# An argument reaches the recipes as text, never run as a command: status rejects it with its
# usage, and setup, setup-ai, and test pass each one on whole
assert_exit 2 "$just" --justfile "$repo/justfile" status '$(touch '"$SANDBOX"'/marker)'
assert_contains "$RUN_OUTPUT" "Usage: just status [quick]"
[ ! -e "$SANDBOX/marker" ] || fail "just status ran its argument"
mkdir -p "$repo/tests"
for script in setup.sh ai_tools/setup.sh tests/run.sh; do
    printf '%s\n' 'printf "%s|" "$@" > "$RAN"' > "$repo/$script"
done
for recipe in setup setup-ai test; do
    rm -f "$RAN" "$SANDBOX/marker"
    assert_exit 0 "$just" --justfile "$repo/justfile" "$recipe" 'a b' '$(touch '"$SANDBOX"'/marker)'
    [ ! -e "$SANDBOX/marker" ] || fail "just $recipe ran its argument"
    assert_contains "$(cat "$RAN")" 'a b|$(touch '"$SANDBOX"'/marker)|'
done
test_done
