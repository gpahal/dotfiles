#!/bin/bash
set -euo pipefail

# Check the claude-code and codex steps' settings and the reviewer flags against the installed CLIs.
# Each doctor must first reject a broken file, so a change in its output can't turn this into a pass.
# claude doctor skips unknown keys; codex doctor skips unknown [desktop] keys (check those by hand).

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for cmd in claude codex jq yq; do
    command -v "$cmd" &>/dev/null || { echo "$cmd isn't installed" >&2; exit 1; }
done
echo "$(claude --version), $(codex --version)"

# shellcheck source=lib/check.sh
source "$REPO_DIR/scripts/lib/check.sh"
make_tmp
# shellcheck source=lib/ai-settings.sh
source "$REPO_DIR/scripts/lib/ai-settings.sh"
temp_tool_home "$tmp"
# claude doctor also reads the settings in the current directory
cd "$HOME"

# shellcheck source=../ai_tools/claude-code/install.sh
source "$REPO_DIR/ai_tools/claude-code/install.sh"
# shellcheck source=../ai_tools/codex/install.sh
source "$REPO_DIR/ai_tools/codex/install.sh"

claude_invalid_settings() {
    claude doctor < /dev/null 2>&1 | sed -n '/^Invalid settings/,/^$/p'
}

# codex doctor exits 1 without a login
codex_config_check() {
    local report
    report="$(codex doctor --json < /dev/null 2>/dev/null)" || true
    jq -ce '.checks[] | select(.id == "config.load")' <<< "$report"
}

echo "Claude Code settings:"
echo '{"tui": "not-a-mode"}' > "$CLAUDE_CODE_SETTINGS"
[ -n "$(claude_invalid_settings)" ] ||
    fail "claude doctor didn't report a broken settings.json, so it can't check the step's"
write_claude_settings
invalid="$(claude_invalid_settings)"
if [ -n "$invalid" ]; then
    printf '%s\n' "$invalid" >&2
    fail "claude doctor rejects settings the claude-code step writes"
else
    echo "  claude doctor accepts them"
fi
if bash "$REPO_DIR/scripts/check-claude-keys.sh" < /dev/null > /dev/null; then
    echo "  its keys are all in scripts/claude-settings-keys.txt"
else
    fail "the claude-code step writes keys that scripts/claude-settings-keys.txt doesn't list"
fi

echo "Codex config:"
echo 'model = 5' > "$CODEX_CONFIG"
check="$(codex_config_check)" || check=""
[ -n "$check" ] && [ "$(jq -r .status <<< "$check")" != ok ] ||
    fail "codex doctor didn't reject a broken config.toml, so it can't check the step's"
rm -f "$CODEX_CONFIG"
edited="$(codex_config_edited)"
mv "$edited" "$CODEX_CONFIG"
if ! check="$(codex_config_check)"; then
    fail "codex doctor --json has no config.load check"
elif [ "$(jq -r .status <<< "$check")" != ok ]; then
    jq . <<< "$check" >&2
    fail "codex doctor doesn't load the config the codex step writes cleanly"
else
    echo "  codex doctor loads it"
fi

# A made-up flag must be reported missing, so the check can fail.
echo "Reviewer flags:"
reviewer="$REPO_DIR/ai_tools/skills/engineering/interrogate/scripts/run-reviewer.sh"
for family in claude codex; do
    if [ "$family" == claude ]; then
        help="$(claude --help < /dev/null 2>&1)" || true
    else
        help="$(codex exec --help < /dev/null 2>&1)" || true
    fi
    flags="$(awk -v start="    $family)" '$0 == start { on = 1; next } on && /^ *;;$/ { exit } on' "$reviewer" |
        grep -oE -- '(^|[[:space:]])--?[a-zA-Z][a-zA-Z-]*' | tr -d '[:blank:]' | sort -u)"
    [ -n "$flags" ] || fail "couldn't read the $family flags from run-reviewer.sh"
    missing=""
    for flag in $flags --dotfiles-no-such-flag; do
        grep -qE -- "(^|[ ,])$flag([ ,=<]|\$)" <<< "$help" || missing="$missing $flag"
    done
    case "$missing" in
        *" --dotfiles-no-such-flag") missing="${missing% --dotfiles-no-such-flag}" ;;
        *) fail "the search of $family's help found a made-up flag, so it can't check the real ones" ;;
    esac
    if [ -n "$missing" ]; then
        fail "$family's help doesn't list these flags run-reviewer.sh passes:$missing"
    else
        echo "  $family's help lists every flag run-reviewer.sh passes ($(printf '%s\n' "$flags" | paste -sd' ' -))"
    fi
done

echo "Codex sandbox:"
if codex sandbox -- true < /dev/null; then
    echo "  It runs commands"
else
    fail "codex sandbox can't run true with the codex step's config"
fi

if [ "$errors" -gt 0 ]; then
    echo "$errors check(s) failed" >&2
    exit 1
fi
echo "All checks passed"
