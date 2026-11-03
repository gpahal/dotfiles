#!/bin/bash

# The justfile: status runs setup.sh --status and exits with its code, and no recipe runs its
# arguments.

just="$(command -v just || true)"
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
[ -n "$just" ] || skip "just isn't installed"

repo="$SANDBOX/repo"
mkdir -p "$repo"
cp "$REPO_DIR/justfile" "$repo/"
printf '%s\n' 'echo "setup.sh $*" >> "$RAN"' 'exit "$SETUP_CODE"' > "$repo/setup.sh"
export RAN="$SANDBOX/ran"

for code in 0 1 3; do
    rm -f "$RAN"
    SETUP_CODE=$code assert_exit "$code" "$just" --justfile "$repo/justfile" status
    assert_eq "setup.sh --status" "$(cat "$RAN")" "the runner run for code $code"
done

# Arguments must reach the recipes as text, never run as code. status takes none, so just
# rejects one before running anything.
rm -f "$RAN"
assert_exit 1 "$just" --justfile "$repo/justfile" status '$(touch '"$SANDBOX"'/marker)'
[ ! -e "$SANDBOX/marker" ] || fail "just status ran its argument"
[ ! -e "$RAN" ] || fail "just status ran a runner when given an argument"
mkdir -p "$repo/tests" "$repo/monitor-input" "$repo/ssh" "$repo/scripts" "$repo/ubuntu"
for script in setup.sh tests/run.sh monitor-input/setup.sh ssh/add-host.sh \
    scripts/copy-back.sh scripts/clean-caches.sh ubuntu/setup-alerts.sh; do
    printf '%s\n' 'printf "%s|" "$@" > "$RAN"' > "$repo/$script"
done
for recipe in setup test monitor-input ssh-host; do
    rm -f "$RAN" "$SANDBOX/marker"
    assert_exit 0 "$just" --justfile "$repo/justfile" "$recipe" 'a b' '$(touch '"$SANDBOX"'/marker)'
    [ ! -e "$SANDBOX/marker" ] || fail "just $recipe ran its argument"
    assert_contains "$(cat "$RAN")" 'a b|$(touch '"$SANDBOX"'/marker)|'
done
# A mode these don't know is a usage error that runs nothing
for recipe in copy-back clean-caches alerts; do
    rm -f "$RAN" "$SANDBOX/marker"
    assert_exit 2 "$just" --justfile "$repo/justfile" "$recipe" '$(touch '"$SANDBOX"'/marker)'
    [ ! -e "$SANDBOX/marker" ] || fail "just $recipe ran its argument"
    [ ! -e "$RAN" ] || fail "just $recipe ran its script given an unknown mode"
done
test_done
