#!/bin/bash
set -euo pipefail

# just status runs both runners whatever the first returns, then exits 1 when either failed, 3
# when either needs attention, and 0 otherwise, so a scheduled run notices a step that needs
# attention. Stub runners that exit a given code stand in for the real ones.

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
test_done
