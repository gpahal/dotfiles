#!/bin/bash
set -euo pipefail

# Check the settings the claude-code and codex steps write with the installed claude and codex
# CLIs, written in a temp HOME with the steps' own functions:
# - claude doctor lists no invalid settings. It skips unknown keys and exits 0 either way, so the
#   keys go through scripts/check-claude-keys.sh too, and the check reads its output.
# - codex doctor loads config.toml with no warning. It skips unknown [desktop] keys, so check
#   those by hand against the ChatGPT app's version.
# - the interrogate skill's run-reviewer.sh passes only flags the CLIs' --help lists.
# - codex sandbox runs true with the step's config. On Linux it needs a bwrap that can sandbox.
# Each doctor first gets a broken file, which it must reject, so a change to its output can't turn
# the check into a pass. Needs claude, codex, jq, and yq, and no login: auth failures are ignored.
# CI runs it with the latest CLIs; `just check` doesn't.

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for cmd in claude codex jq yq; do
    command -v "$cmd" &>/dev/null || { echo "$cmd isn't installed" >&2; exit 1; }
done
echo "$(claude --version), $(codex --version)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=lib/ai-settings.sh
source "$REPO_DIR/scripts/lib/ai-settings.sh"
temp_tool_home "$tmp"
# claude doctor also reads the settings in the current directory
cd "$HOME"

# shellcheck source=../ai_tools/claude-code/install.sh
source "$REPO_DIR/ai_tools/claude-code/install.sh"
# shellcheck source=../ai_tools/codex/install.sh
source "$REPO_DIR/ai_tools/codex/install.sh"

errors=0
fail() {
    echo "FAIL: $1" >&2
    errors=$((errors + 1))
}

# Print claude doctor's "Invalid settings" section, if any
claude_invalid_settings() {
    claude doctor < /dev/null 2>&1 | sed -n '/^Invalid settings/,/^$/p'
}

# Print codex doctor's config.load check as JSON. codex doctor exits 1 without a login.
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

# Flags read from run-reviewer.sh's claude) and codex) branches, so a renamed or dropped flag
# shows up here rather than as a failed review. A made-up flag must be missing.
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
