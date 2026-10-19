#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail


# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
load_script ai_tools/claude-desktop/install.sh
# The test may run inside the Claude app, which ensure_app_quit handles on its own
replace_fn running_inside 'false'
# Keep the real /Applications/Claude.app out of the cask checks
APP="$HOME/Applications/Claude.app"
replace_fn cask_app_path 'echo "$APP"'
eval "real_$(declare -f cask_state)"
replace_fn cask_state 'real_cask_state "$1" "$APP"'
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
assert_eq "$CONFIG" "$CLAUDE_DESKTOP_CONFIG" "config path"
AGENT="$HOME/Library/LaunchAgents/dotfiles.claude-desktop.plist"

as_os ubuntu
assert_exit 0 main
[ ! -e "$CONFIG" ] || fail "the config was written on Ubuntu"
[ ! -e "$AGENT" ] || fail "the LaunchAgent was written on Ubuntu"

as_os macos
stub brew '[ "$*" == "install --cask claude" ]'
stub pgrep 'exit 1'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    claude (cask)"
assert_contains "$RUN_OUTPUT" "missing    ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installing claude..."
assert_contains "$RUN_OUTPUT" "Copied ai_tools/claude-desktop/dotfiles.claude-desktop.plist to $AGENT"
assert_eq "$(cat "$DOTFILES_DIR/ai_tools/claude-desktop/dotfiles.claude-desktop.plist")" "$(cat "$AGENT")" "LaunchAgent"
assert_file_contains "$STUB_LOG" "brew install --cask claude"

stub brew '[ "$*" == "list --cask claude" ]'
stub pgrep 'exit 1'
mkdir -p "$APP" "$(dirname "$CONFIG")"
echo '{"mcpServers": {"x": {"command": "y"}}, "preferences": {"sidebarMode": "chat", "menuBarEnabled": true, "quickEntryShortcut": {"enabled": true}}}' > "$CONFIG"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Claude desktop app settings"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "claude already installed."
assert_contains "$RUN_OUTPUT" "Set notifications, keep-awake"
assert_file_not_contains "$STUB_LOG" "brew install"
assert_eq 'y chat false Alt+Space true' "$(jq -r '[.mcpServers.x.command, .preferences.sidebarMode,
    .preferences.menuBarEnabled, .preferences.quickEntryShortcut.accelerator,
    .preferences.quickEntryShortcut.enabled] | map(tostring) | join(" ")' "$CONFIG")" "merged settings"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Claude desktop app settings"
assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"

# Nothing to change, so a running Claude doesn't matter
before="$(/bin/ls -i "$CONFIG")"
stub pgrep 'exit 0'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set"
assert_contains "$RUN_OUTPUT" "$AGENT is already up to date"
assert_eq "$before" "$(/bin/ls -i "$CONFIG")" "config after a re-run"

stub pgrep 'exit 1'
for value in true '"Alt+Space"'; do
    jq --argjson v "$value" '.preferences.quickEntryShortcut = $v' "$CONFIG" > "$SANDBOX/q.json"
    cp "$SANDBOX/q.json" "$CONFIG"
    assert_exit 0 main
    assert_eq '{"accelerator":"Alt+Space"}' "$(jq -c .preferences.quickEntryShortcut "$CONFIG")" \
        "quick entry shortcut replacing $value"
done
stub pgrep 'exit 0'

jq '.preferences.menuBarEnabled = true' "$CONFIG" > "$SANDBOX/changed.json"
cp "$SANDBOX/changed.json" "$CONFIG"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Claude is running; skipping."
assert_eq "$(cat "$SANDBOX/changed.json")" "$(cat "$CONFIG")" "config while Claude runs"
assert_file_not_contains "$STUB_LOG" "osascript"

no_jq_status() {
    hide jq
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "ok         claude (cask)"
    assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"
    assert_contains "$RUN_OUTPUT" "unknown    Claude desktop app settings: $(missing_cmd_hint jq)"
}
subtest no_jq_status
test_done
