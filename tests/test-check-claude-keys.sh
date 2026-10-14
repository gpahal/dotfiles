#!/bin/bash
set -euo pipefail

# scripts/check-claude-keys.sh passes on the settings the claude-code step writes, and fails,
# naming the key, on a settings file with an unknown key, a misspelled nested key, or a key the
# contract in scripts/claude-settings-keys.txt lost.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &> /dev/null || skip "jq isn't installed"

check="$REPO_DIR/scripts/check-claude-keys.sh"

assert_exit 0 "$BASH" "$check"
assert_contains "$RUN_OUTPUT" "Every key the claude-code step writes is in scripts/claude-settings-keys.txt"

# The negative control: a key Claude Code doesn't have, and a typo in a nested one
printf '%s\n' '{"model": "x", "notARealSetting": true, "statusLine": {"type": "command", "refreshIntreval": 5},' \
    '"modelSettings": {"any-model": {"effortLevel": "low"}}, "hooks": {"WorktreeCreate": [{"hooks": []}]}}' \
    > "$SANDBOX/settings.json"
assert_exit 1 "$BASH" "$check" "$SANDBOX/settings.json"
assert_contains "$RUN_OUTPUT" "notARealSetting isn't a Claude Code setting in scripts/claude-settings-keys.txt"
assert_contains "$RUN_OUTPUT" "statusLine.refreshIntreval isn't a Claude Code setting"
assert_not_contains "$RUN_OUTPUT" "modelSettings"
assert_not_contains "$RUN_OUTPUT" "WorktreeCreate"

# A contract that lost a key the step writes
mkdir -p "$SANDBOX/repo/scripts"
cp -R "$REPO_DIR/lib" "$SANDBOX/repo/"
mkdir -p "$SANDBOX/repo/ai_tools"
cp -R "$REPO_DIR/ai_tools/claude-code" "$SANDBOX/repo/ai_tools/"
cp "$check" "$SANDBOX/repo/scripts/"
grep -vx tui "$REPO_DIR/scripts/claude-settings-keys.txt" > "$SANDBOX/repo/scripts/claude-settings-keys.txt"
assert_exit 1 "$BASH" "$SANDBOX/repo/scripts/check-claude-keys.sh"
assert_contains "$RUN_OUTPUT" "tui isn't a Claude Code setting"

# A contract that lost a key only the Ubuntu branch writes fails on either OS
grep -vx preferredNotifChannel "$REPO_DIR/scripts/claude-settings-keys.txt" > "$SANDBOX/repo/scripts/claude-settings-keys.txt"
assert_exit 1 "$BASH" "$SANDBOX/repo/scripts/check-claude-keys.sh"
assert_contains "$RUN_OUTPUT" "preferredNotifChannel isn't a Claude Code setting"
test_done
