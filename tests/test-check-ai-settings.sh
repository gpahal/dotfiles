#!/bin/bash
set -euo pipefail

# scripts/check-ai-settings.sh, with the claude and codex CLIs stubbed, writes the claude-code and
# codex steps' settings in a temp HOME, never the sandbox's own, and passes when each doctor
# accepts them, rejects a broken file, every reviewer flag is in the CLIs' help, and codex sandbox
# runs. Otherwise it fails, naming what failed.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
command -v yq &>/dev/null || skip "yq isn't installed"

REVIEWER="$REPO_DIR/ai_tools/skills/engineering/interrogate/scripts/run-reviewer.sh"
# Each stub's behavior, switched by the files in $SANDBOX/broken: claude-doctor and codex-doctor
# reject every file, lax-doctors rejects none, no-flags empties the help, and no-sandbox fails
# codex sandbox. Each doctor otherwise rejects the broken file the script writes, and the help
# is run-reviewer.sh itself, which names every flag it passes.
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

# Doctors that reject the step's settings, and help that lists no flags
touch "$broken/claude-doctor" "$broken/codex-doctor" "$broken/no-flags" "$broken/no-sandbox"
check 1
assert_contains "$RUN_OUTPUT" "claude doctor rejects settings the claude-code step writes"
assert_contains "$RUN_OUTPUT" "codex doctor doesn't load the config the codex step writes cleanly"
assert_contains "$RUN_OUTPUT" "claude's help doesn't list these flags run-reviewer.sh passes: -"
assert_contains "$RUN_OUTPUT" "codex's help doesn't list these flags run-reviewer.sh passes: -"
assert_contains "$RUN_OUTPUT" "codex sandbox can't run true"
assert_contains "$RUN_OUTPUT" "5 check(s) failed"
rm "$broken"/*

# Doctors that accept anything can't check the step's settings
touch "$broken/lax-doctors"
check 1
assert_contains "$RUN_OUTPUT" "claude doctor didn't report a broken settings.json"
assert_contains "$RUN_OUTPUT" "codex doctor didn't reject a broken config.toml"
rm "$broken"/*

# A missing CLI fails it before anything runs
hide codex
check 1
assert_contains "$RUN_OUTPUT" "codex isn't installed"

test_done
