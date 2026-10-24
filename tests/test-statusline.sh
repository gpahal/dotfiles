#!/bin/bash

# Claude Code's status line script: a missing field leaves no gap, and no jq says so.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

script="$REPO_DIR/ai_tools/claude-code/statusline.sh"

command -v jq &> /dev/null || skip "jq isn't installed"

# No effort: whitespace separators would collapse the empty field and shift context into its place
input='{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":42.6}}'
assert_eq "Opus 5.5 · ctx 43%" "$(printf '%s' "$input" | /bin/bash "$script")" \
    "status line with an empty middle field"

mkdir -p "$SANDBOX/nojq"
for cmd in git cat; do
    ln -s "$(command -v "$cmd")" "$SANDBOX/nojq/$cmd"
done
assert_eq "statusline: jq missing" \
    "$(printf '%s' "$input" | PATH="$SANDBOX/nojq" /bin/bash "$script")" "status line without jq"
test_done
