#!/bin/bash
set -euo pipefail

# Check that every key in a Claude Code settings file is one scripts/claude-settings-keys.txt
# lists. With no argument, it checks the settings the claude-code step writes on either OS, made
# in a temp HOME with the step's own functions. Claude Code ignores unknown keys, so a misspelled
# one would do nothing without a word. Needs jq. `just check` runs it, and so does
# scripts/check-ai-settings.sh.
# Usage: check-claude-keys.sh [<settings.json>]

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$REPO_DIR/scripts/claude-settings-keys.txt"
command -v jq &>/dev/null || { echo "check-claude-keys.sh needs jq" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ $# -gt 0 ]; then
    settings="$1"
    what="$1"
else
    what="the claude-code step"
    # Build the settings once per OS branch, so a run on either OS checks the keys both write
    for os in macos ubuntu; do
        (
            # Nothing may read or write the real ~/.claude
            export HOME="$tmp/$os"
            unset CLAUDE_CONFIG_DIR
            for var in $(compgen -v XDG_); do unset "$var"; done
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
            # The step adds the worktree hooks only once git wt is installed
            mkdir -p "$HOME/.local/bin" "$HOME/.claude"
            printf '#!/bin/sh\n' > "$HOME/.local/bin/git-wt"
            chmod +x "$HOME/.local/bin/git-wt"
            echo '{}' > "$CLAUDE_CODE_SETTINGS"
            json_merge "$CLAUDE_CODE_SETTINGS" "$(claude_code_settings)" > /dev/null
            cp "$CLAUDE_CODE_SETTINGS" "$tmp/settings-$os.json"
        ) < /dev/null
    done
    # Object keys merge, so the union holds every key either branch writes
    jq -s '.[0] * .[1]' "$tmp/settings-macos.json" "$tmp/settings-ubuntu.json" > "$tmp/settings.json"
    settings="$tmp/settings.json"
fi

# Every object key's path, not descending into lists, with the model IDs under modelSettings as *
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
