#!/bin/bash
# The steps' functions call the replaced ones
# shellcheck disable=SC2329
set -euo pipefail

# A failed install or settings write fails the AI tool steps after they set up the rest.
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
stub brew 'exit 1'
stub pgrep 'exit 1'

claude_failure() {
    load_script ai_tools/claude-code/install.sh
    replace_fn install_claude_code 'return 1'
    replace_fn claude_code_have_git_wt 'true'
    main
}
assert_exit 1 claude_failure
assert_file_contains "$HOME/.claude/settings.json" '"autoMemoryEnabled": false'
[ -x "$HOME/.claude/statusline.sh" ] || fail "Claude skipped its scripts after installation failed"
[ -f "$HOME/.claude/CLAUDE.md" ] || fail "Claude skipped its instructions after installation failed"
rm -rf "$HOME/.claude"

installer_without_claude() {
    load_script ai_tools/claude-code/install.sh
    hide claude
    replace_fn run_installer 'echo "run_installer $*" >> "$STUB_LOG"'
    install_claude_code
}
assert_exit 1 installer_without_claude

desktop_failure() {
    load_script ai_tools/claude-desktop/install.sh
    as_os macos
    replace_fn install_cask 'return 1'
    main
}
assert_exit 1 desktop_failure
assert_file_contains "$HOME/Library/Application Support/Claude/claude_desktop_config.json" '"menuBarEnabled": false'

stub launchctl
t3_failure() {
    load_script ai_tools/t3-code/install.sh
    as_os macos
    replace_fn t3_code_app_path 'return 1'
    main
}
assert_exit 1 t3_failure
assert_file_contains "$HOME/.t3/userdata/client-settings.json" '"followUpBehavior": "steer"'
assert_file_contains "$STUB_LOG" "launchctl setenv T3CODE_TELEMETRY_ENABLED false"

# Aggregating main's failures disables errexit in its callees, so a failed merge must still fail
claude_write_failure() {
    load_script ai_tools/claude-code/install.sh
    replace_fn install_claude_code 'return 0'
    replace_fn claude_code_have_git_wt 'true'
    replace_fn json_merge 'return 1'
    main
}
rm -rf "$HOME/.claude"
assert_exit 1 claude_write_failure
assert_not_contains "$RUN_OUTPUT" "Turned on push notifications"
[ -f "$HOME/.claude/CLAUDE.md" ] || fail "Claude skipped its instructions after a failed merge"

# These need mikefarah's yq, and a brew, since the step fails early without one
stub brew 'exit 1'
yq --version 2> /dev/null | grep -q mikefarah || skip "mikefarah's yq isn't installed"
codex_failure() {
    load_script ai_tools/codex/install.sh
    as_os "$TEST_OS"
    replace_fn install_cask 'return 1'
    replace_fn setup_codex_sandbox 'echo sandbox >> "$STUB_LOG"'
    main
}
for TEST_OS in macos ubuntu; do
    rm -rf "$HOME/.codex"
    assert_exit 1 codex_failure
    assert_file_contains "$HOME/.codex/config.toml" 'model_reasoning_effort = "high"'
    [ -f "$HOME/.codex/AGENTS.md" ] ||
        fail "Codex skipped its instructions after installation failed"
done
assert_file_contains "$STUB_LOG" sandbox
test_done
