#!/bin/bash
set -euo pipefail

# Claude Code's status line script prints the fields Claude Code sends, and says when jq is
# missing instead of printing an empty line.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
script="$REPO_DIR/ai_tools/claude-code/statusline.sh"

command -v jq &> /dev/null || {
    echo "jq isn't installed" >&2
    exit 1
}

git init -q -b feat "$SANDBOX/repo"
input="$(printf '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"medium"},"context_window":{"used_percentage":42.6},"rate_limits":{"five_hour":{"used_percentage":24.2}},"workspace":{"current_dir":"%s"}}' "$SANDBOX/repo")"
assert_eq "Opus 5.5 · medium · ctx 43% · 5h 24% · feat" \
    "$(printf '%s' "$input" | /bin/bash "$script")" "status line with every field"
assert_eq "Opus 5.5" "$(echo '{"model":{"display_name":"Opus 5.5"}}' | /bin/bash "$script")" \
    "status line with only the model"

# Without jq on PATH: only git and cat
mkdir -p "$SANDBOX/nojq"
for cmd in git cat; do
    ln -s "$(command -v "$cmd")" "$SANDBOX/nojq/$cmd"
done
assert_eq "statusline: jq missing" \
    "$(printf '%s' "$input" | PATH="$SANDBOX/nojq" /bin/bash "$script")" "status line without jq"
test_done
