#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
command -v yq &>/dev/null || skip "yq isn't installed"

REVIEWER="$REPO_DIR/ai_tools/skills/engineering/interrogate/scripts/run-reviewer.sh"
# Files in $SANDBOX/broken switch the stubs. The help is run-reviewer.sh, which names every flag it passes.
mkdir -p "$SANDBOX/broken"
broken="$SANDBOX/broken"
stub claude 'case "$*" in
    --version) echo "2.0.0 (Claude Code)" ;;
    doctor)
        if [ -e "'"$broken"'/claude-doctor" ] ||
            { [ ! -e "'"$broken"'/lax-doctors" ] && grep -q not-a-mode "$HOME/.claude/settings.json"; }; then
            printf "Invalid settings\n  tui: invalid value\n\n"
        fi
        echo "All good" ;;
    --help) [ -e "'"$broken"'/no-flags" ] || cat "'"$REVIEWER"'" ;;
esac'
stub codex 'case "$*" in
    --version) echo "codex-cli 1.0.0" ;;
    "doctor --json")
        status=ok
        if [ -e "'"$broken"'/codex-doctor" ] ||
            { [ ! -e "'"$broken"'/lax-doctors" ] && grep -qx "model = 5" "$HOME/.codex/config.toml"; }; then
            status=error
        fi
        echo "{\"checks\": [{\"id\": \"auth\", \"status\": \"error\"}, {\"id\": \"config.load\", \"status\": \"$status\"}]}"
        exit 1 ;;
    "exec --help") [ -e "'"$broken"'/no-flags" ] || cat "'"$REVIEWER"'" ;;
    "sandbox -- true") [ ! -e "'"$broken"'/no-sandbox" ] ;;
esac'
check() {
    : > "$STUB_LOG"
    assert_exit "$1" "$BASH" "$REPO_DIR/scripts/check-ai-settings.sh"
    assert_eq "" "$(ls -A "$HOME")" "what check-ai-settings.sh left in HOME"
}

check 0
assert_contains "$RUN_OUTPUT" "2.0.0 (Claude Code), codex-cli 1.0.0"
assert_contains "$RUN_OUTPUT" "claude doctor accepts them"
assert_contains "$RUN_OUTPUT" "its keys are all in scripts/claude-settings-keys.txt"
assert_contains "$RUN_OUTPUT" "codex doctor loads it"
assert_contains "$RUN_OUTPUT" "claude's help lists every flag run-reviewer.sh passes (-"
assert_contains "$RUN_OUTPUT" "codex's help lists every flag run-reviewer.sh passes (-"
assert_contains "$RUN_OUTPUT" "All checks passed"

touch "$broken/claude-doctor" "$broken/codex-doctor" "$broken/no-flags" "$broken/no-sandbox"
check 1
assert_contains "$RUN_OUTPUT" "claude doctor rejects settings the claude-code step writes"
assert_contains "$RUN_OUTPUT" "codex doctor doesn't load the config the codex step writes cleanly"
assert_contains "$RUN_OUTPUT" "claude's help doesn't list these flags run-reviewer.sh passes: -"
assert_contains "$RUN_OUTPUT" "codex's help doesn't list these flags run-reviewer.sh passes: -"
assert_contains "$RUN_OUTPUT" "codex sandbox can't run true"
assert_contains "$RUN_OUTPUT" "5 check(s) failed"
rm "$broken"/*

# Doctors that accept anything can't check the settings
touch "$broken/lax-doctors"
check 1
assert_contains "$RUN_OUTPUT" "claude doctor didn't report a broken settings.json"
assert_contains "$RUN_OUTPUT" "codex doctor didn't reject a broken config.toml"
rm "$broken"/*

hide codex
check 1
assert_contains "$RUN_OUTPUT" "codex isn't installed"

test_done
