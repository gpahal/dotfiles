#!/bin/bash

# The justfile: status runs both runners and combines their codes, and no recipe runs its arguments.

just="$(command -v just || true)"
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
[ -n "$just" ] || skip "just isn't installed"

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
    assert_eq "ai_tools/setup.sh --status
setup.sh --status" "$(sort "$RAN")" "runners run for codes $a and $b"
done

# The runners run at once: setup.sh ends only after the AI runner has, yet its report prints first,
# then a blank line and the AI report
printf '%s\n' 'i=0' 'until [ -e "$SANDBOX/ai-done" ]; do' \
    '    [ "$i" -lt 100 ] || { echo "the AI runner never finished" >&2; exit 1; }' \
    '    sleep 0.1; i=$((i + 1))' 'done' 'echo "setup report"' > "$repo/setup.sh"
printf '%s\n' 'echo "AI report"' 'echo "AI warning" >&2' 'touch "$SANDBOX/ai-done"' 'exit 3' \
    > "$repo/ai_tools/setup.sh"
status=0
out="$("$just" --justfile "$repo/justfile" status 2> "$SANDBOX/status.err")" || status=$?
assert_eq 3 "$status" "just status's exit with runners run at once"
assert_eq "setup report

AI report" "$out" "the reports of runners run at once"
assert_file_contains "$SANDBOX/status.err" "AI warning"
assert_eq "" "$(ls -A "$TMPDIR")" "temp files left after just status"

# Ctrl-C during setup.sh's report stops the AI runner too, and the recipe dies of SIGINT
printf '%s\n' 'touch "$SANDBOX/setup-started"' 'sleep 30' > "$repo/setup.sh"
printf '%s\n' 'echo "$$" > "$SANDBOX/ai-pid"' 'sleep 30 &' 'trap '\''kill "$!"; exit 143'\'' TERM' 'wait' \
    > "$repo/ai_tools/setup.sh"
status=0
caller=""
# A failed assertion or timeout mustn't leave the recipe's group running
trap 'status=$?; set +e; [ -z "$caller" ] || kill -KILL -- "-$caller" 2> /dev/null; (exit "$status"); _sandbox_exit' EXIT
# Job control keeps SIGINT deliverable; a background job ignores it
set -m
"$just" --justfile "$repo/justfile" status > "$SANDBOX/status.out" 2>&1 &
caller=$!
set +m
if wait_for test -s "$SANDBOX/ai-pid" && wait_for test -e "$SANDBOX/setup-started"; then
    kill -INT -- "-$caller"
    wait_for process_exited "$caller" || kill -KILL -- "-$caller"
else
    fail "the runners didn't start"
    kill -KILL -- "-$caller"
fi
wait "$caller" || status=$?
caller=""
assert_eq 130 "$status" "just status's exit after Ctrl-C"
wait_for process_exited "$(cat "$SANDBOX/ai-pid")" || fail "the AI runner outlived Ctrl-C"
assert_eq "" "$(ls -A "$TMPDIR")" "temp files left after an interrupted just status"

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
