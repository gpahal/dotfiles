#!/bin/bash
set -euo pipefail

# Check the settings the claude-code and codex steps write with the installed claude and codex
# CLIs. In a temp HOME, it writes ~/.claude/settings.json and ~/.codex/config.toml with the steps'
# own functions, then:
# - claude doctor must list no invalid settings. It checks types and allowed values, but not
#   unknown keys, and exits 0 either way, so the check reads its output.
# - every key the step writes must be in scripts/claude-settings-keys.txt
#   (scripts/check-claude-keys.sh), the keys checked by hand against Claude Code. Doctor would
#   ignore an unknown one.
# - codex doctor must load config.toml with no warning. It warns about unknown top-level keys,
#   but not about a [desktop] key it doesn't know, so check those by hand against the ChatGPT
#   app's version.
# - every flag the interrogate skill's run-reviewer.sh passes must be in `claude --help` or
#   `codex exec --help`.
# - codex sandbox must run true with the step's config. On Linux it needs a bwrap that can create
#   a sandbox.
# Each doctor first gets a broken file, which it must reject, so a change to its output can't turn
# the check into a pass. Needs claude, codex, jq, and yq, and no login: auth failures are ignored.
# CI runs it with the latest CLIs (.github/workflows/check.yml); `just check` doesn't.

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for cmd in claude codex jq yq; do
    command -v "$cmd" &>/dev/null || { echo "$cmd isn't installed" >&2; exit 1; }
done
echo "$(claude --version), $(codex --version)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Nothing may read or write the real ~/.claude or ~/.codex
export HOME="$tmp"
unset CLAUDE_CONFIG_DIR CODEX_HOME
for var in $(compgen -v XDG_); do unset "$var"; done
# claude doctor also reads the settings in the current directory
cd "$HOME"

# shellcheck source=../ai_tools/claude-code/install.sh
source "$REPO_DIR/ai_tools/claude-code/install.sh"
# shellcheck source=../ai_tools/codex/install.sh
source "$REPO_DIR/ai_tools/codex/install.sh"
# The claude-code step adds the worktree hooks only once git wt is installed
mkdir -p "$HOME/.local/bin" "$HOME/.claude" "$HOME/.codex"
printf '#!/bin/sh\n' > "$HOME/.local/bin/git-wt"
chmod +x "$HOME/.local/bin/git-wt"

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
echo '{}' > "$CLAUDE_CODE_SETTINGS"
json_merge "$CLAUDE_CODE_SETTINGS" "$(claude_code_settings)" > /dev/null
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

# The flags the interrogate skill's run-reviewer.sh passes each CLI, read from its claude) and
# codex) branches, must be in `claude --help` and `codex exec --help`, so a renamed or dropped
# flag shows up here rather than as a failed review. A made-up flag must be missing.
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
