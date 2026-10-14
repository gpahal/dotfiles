#!/bin/bash
# The step mains invoke these replacements.
# shellcheck disable=SC2329
set -euo pipefail

# Failed downloads or config writes still permit independent AI setup work.
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
stub brew 'exit 1'
stub pgrep 'exit 1'

claude_failure() {
    load_script ai_tools/claude-code/install.sh
    install_claude_code() { return 1; }
    claude_code_have_git_wt() { true; }
    main
}
assert_exit 1 claude_failure
assert_file_contains "$HOME/.claude/settings.json" '"autoMemoryEnabled": false'
[ -x "$HOME/.claude/statusline.sh" ] || fail "Claude skipped its scripts after installation failed"
assert_file_contains "$HOME/.claude/settings.json" "worktree-hook.sh"
[ -f "$HOME/.claude/CLAUDE.md" ] || fail "Claude skipped its instructions after installation failed"

# A worktree hook that couldn't be copied isn't registered, and the other settings still are
rm -rf "$HOME/.claude"
mkdir -p "$HOME/.claude"
touch "$HOME/.claude/hooks"
assert_exit 1 claude_failure
assert_file_contains "$HOME/.claude/settings.json" '"autoMemoryEnabled": false'
assert_not_contains "$(cat "$HOME/.claude/settings.json")" "worktree-hook.sh"
rm -rf "$HOME/.claude"

desktop_failure() {
    load_script ai_tools/claude-desktop/install.sh
    is_macos() { true; }
    install_cask() { return 1; }
    main
}
assert_exit 1 desktop_failure
assert_file_contains "$HOME/Library/Application Support/Claude/claude_desktop_config.json" '"menuBarEnabled": false'

# A failed t3-code cask on macOS still turns off T3 Code's telemetry and writes its settings
stub launchctl
t3_failure() {
    load_script ai_tools/t3-code/install.sh
    is_macos() { true; }
    t3_code_app_path() { return 1; }
    main
}
assert_exit 1 t3_failure
assert_file_contains "$HOME/.t3/userdata/client-settings.json" '"followUpBehavior": "steer"'
assert_file_contains "$STUB_LOG" "launchctl setenv T3CODE_TELEMETRY_ENABLED false"

# Aggregating main's failures disables errexit inside its callees. A failed merge must still
# fail and leave no success message, while independent instruction copying carries on.
claude_write_failure() {
    load_script ai_tools/claude-code/install.sh
    install_claude_code() { return 0; }
    claude_code_have_git_wt() { true; }
    json_merge() { return 1; }
    main
}
rm -rf "$HOME/.claude"
assert_exit 1 claude_write_failure
assert_not_contains "$RUN_OUTPUT" "Turned on push notifications"
[ -f "$HOME/.claude/CLAUDE.md" ] || fail "Claude skipped its instructions after a failed merge"

# Without brew, install_cask fails with missing_cmd_hint's message, and codex_cask_path prints
# nothing rather than /bin/codex
load_script ai_tools/codex/install.sh
hide brew
codex_outside_homebrew() { return 1; }
cask_state() { echo "cask_state $*" >> "$STUB_LOG"; }
assert_exit 1 install_cask claude /Applications/Claude.app
assert_eq "  $(missing_cmd_hint brew)" "$RUN_OUTPUT" "install_cask without brew"
assert_exit 1 install_codex_cli
assert_eq "  $(missing_cmd_hint brew)" "$RUN_OUTPUT" "Codex without brew"
assert_eq "" "$(codex_cask_path)" "codex_cask_path without brew"
assert_file_not_contains "$STUB_LOG" "cask_state"

# The codex step edits config.toml with mikefarah's yq, so these run last. They need a brew, since
# the step fails before changing anything without one, and its casks then fail to install.
stub brew 'exit 1'
if yq --version 2>/dev/null | grep -q mikefarah; then
    codex_failure() {
        load_script ai_tools/codex/install.sh
        is_macos() { [ "$TEST_OS" == macos ]; }
        is_ubuntu() { [ "$TEST_OS" == ubuntu ]; }
        codex_outside_homebrew() { return 1; }
        install_cask() { return 1; }
        setup_codex_sandbox() { echo sandbox >> "$STUB_LOG"; }
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
else
    skip_rest "mikefarah's yq isn't installed"
fi
test_done
