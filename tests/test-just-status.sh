#!/bin/bash
set -euo pipefail

# The justfile: status runs both runners and combines their codes, and no recipe runs its arguments.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

just="$(command -v just || true)"
[ -n "$just" ] || skip "just isn't installed"
setup_sandbox

repo="$SANDBOX/repo"
mkdir -p "$repo/ai_tools"
cp "$REPO_DIR/justfile" "$repo/"
printf '%s\n' 'echo "setup.sh $*" >> "$RAN"' 'exit "$SETUP_CODE"' > "$repo/setup.sh"
printf '%s\n' 'echo "ai_tools/setup.sh $*" >> "$RAN"' 'exit "$AI_CODE"' > "$repo/ai_tools/setup.sh"
export RAN="$SANDBOX/ran"

# <setup.sh's code> <ai_tools/setup.sh's code> <the recipe's code>
for codes in "0 0 0" "3 0 3" "0 1 1" "3 1 1"; do
    read -r a b want <<< "$codes"
    rm -f "$RAN"
    SETUP_CODE=$a AI_CODE=$b assert_exit "$want" "$just" --justfile "$repo/justfile" status
    assert_eq "setup.sh --status
ai_tools/setup.sh --status" "$(cat "$RAN")" "runners run for codes $a and $b"
done

# Arguments must reach the recipes as text, never run as code. status takes none, so just
# rejects one before running anything.
rm -f "$RAN"
assert_exit 1 "$just" --justfile "$repo/justfile" status '$(touch '"$SANDBOX"'/marker)'
[ ! -e "$SANDBOX/marker" ] || fail "just status ran its argument"
[ ! -e "$RAN" ] || fail "just status ran a runner when given an argument"
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
