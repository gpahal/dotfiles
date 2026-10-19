#!/bin/bash
set -euo pipefail

# Check settings keys against claude-settings-keys.txt (default: what the claude-code step writes).
# Usage: check-claude-keys.sh [<settings.json>]

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$REPO_DIR/scripts/claude-settings-keys.txt"
command -v jq &>/dev/null || { echo "check-claude-keys.sh needs jq" >&2; exit 1; }
# shellcheck source=lib/ai-settings.sh
source "$REPO_DIR/scripts/lib/ai-settings.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ $# -gt 0 ]; then
    settings="$1"
    what="$1"
else
    what="the claude-code step"
    for os in macos ubuntu; do
        (
            temp_tool_home "$tmp/$os"
            # shellcheck source=../ai_tools/claude-code/install.sh
            source "$REPO_DIR/ai_tools/claude-code/install.sh"
            # shellcheck disable=SC2329 # the step's functions call them
            if [ "$os" = macos ]; then
                is_macos() { return 0; }
                is_ubuntu() { return 1; }
            else
                is_macos() { return 1; }
                is_ubuntu() { return 0; }
            fi
            write_claude_settings
            cp "$CLAUDE_CODE_SETTINGS" "$tmp/settings-$os.json"
        ) < /dev/null
    done
    jq -s '.[0] * .[1]' "$tmp/settings-macos.json" "$tmp/settings-ubuntu.json" > "$tmp/settings.json"
    settings="$tmp/settings.json"
fi

# Object key paths only, not into lists; model IDs become *
jq -r '[paths | select(all(.[]; type == "string"))
    | if .[0] == "modelSettings" and length > 1 then .[1] = "*" else . end | join(".")]
    | unique[]' "$settings" > "$tmp/keys"
grep -v '^#' "$CONTRACT" | sed '/^$/d' > "$tmp/contract"

errors=0
while IFS= read -r key; do
    if ! grep -qxF -- "$key" "$tmp/contract"; then
        echo "$key isn't a Claude Code setting in scripts/claude-settings-keys.txt. Fix the typo, or check the key against Claude Code and add it." >&2
        errors=$((errors + 1))
    fi
done < "$tmp/keys"
[ "$errors" -eq 0 ] || exit 1
[ $# -gt 0 ] || echo "Every key $what writes is in scripts/claude-settings-keys.txt"
