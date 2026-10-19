#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The claude-desktop step merges its settings into the app's config, keeping the keys it doesn't
# set, copies the LaunchAgent that opens Claude at login, changes nothing on a re-run, leaves the
# config alone while Claude runs, and is macOS only.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
load_script ai_tools/claude-desktop/install.sh
# The test may run inside the Claude app, which ensure_app_quit handles on its own
replace_fn running_inside 'false'
# Keep the real /Applications/Claude.app, present or not, out of the cask checks: the step passes
# that path to install_cask and status_cask, and brew info would give it too
APP="$HOME/Applications/Claude.app"
replace_fn cask_app_path 'echo "$APP"'
eval "real_$(declare -f cask_state)"
replace_fn cask_state 'real_cask_state "$1" "$APP"'
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
assert_eq "$CONFIG" "$CLAUDE_DESKTOP_CONFIG" "config path"
AGENT="$HOME/Library/LaunchAgents/dotfiles.claude-desktop.plist"

# Ubuntu: STEP_OS skips the step, which writes nothing
as_os ubuntu
assert_exit 0 main
[ ! -e "$CONFIG" ] || fail "the config was written on Ubuntu"
[ ! -e "$AGENT" ] || fail "the LaunchAgent was written on Ubuntu"

# macOS, with neither the cask nor the app: status reports it, and the step installs it
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

# The app installed outside brew: nothing to install
rm -f "$CONFIG"
mkdir -p "$APP"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "claude already installed, but not by Homebrew"
assert_file_not_contains "$STUB_LOG" "brew install"

# The cask installed and Claude not running
stub brew '[ "$*" == "list --cask claude" ]'
stub pgrep 'exit 1'
mkdir -p "$APP" "$(dirname "$CONFIG")"
echo '{"mcpServers": {"x": {"command": "y"}}, "preferences": {"sidebarMode": "chat", "menuBarEnabled": true}}' > "$CONFIG"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Claude desktop app settings"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "claude already installed."
assert_contains "$RUN_OUTPUT" "Set notifications, keep-awake"
assert_file_not_contains "$STUB_LOG" "brew install"
assert_eq '{
  "mcpServers": {
    "x": {
      "command": "y"
    }
  },
  "preferences": {
    "sidebarMode": "chat",
    "menuBarEnabled": false,
    "dockBounceEnabled": true,
    "ccAutoArchiveInactiveDays": 30,
    "ccKeepAwakeWhileWorking": true,
    "ccKeepAwakeOnBattery": true,
    "ccdScheduledTasksEnabled": true,
    "quickEntryShortcut": {
      "accelerator": "Alt+Space"
    },
    "coworkBrowserToolsEnabled": true,
    "coworkPreferredBrowser": "chrome",
    "coworkWebSearchEnabled": true,
    "coworkScheduledTasksEnabled": true
  }
}' "$(cat "$CONFIG")" "config after the step"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Claude desktop app settings"
assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"

# Re-run: nothing to change, so a running Claude doesn't matter
before="$(/bin/ls -i "$CONFIG")"
stub pgrep 'exit 0'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set"
assert_contains "$RUN_OUTPUT" "$AGENT is already up to date"
assert_eq "$before" "$(/bin/ls -i "$CONFIG")" "config after a re-run"

# A key Claude adds to the quick entry shortcut stays, so the settings still count as set
jq '.preferences.quickEntryShortcut.enabled = true' "$CONFIG" > "$SANDBOX/q.json" && cp "$SANDBOX/q.json" "$CONFIG"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Claude desktop app settings"

# A quick entry shortcut that isn't an object is replaced by one
stub pgrep 'exit 1'
for value in true '"Alt+Space"'; do
    jq --argjson v "$value" '.preferences.quickEntryShortcut = $v' "$CONFIG" > "$SANDBOX/q.json"
    cp "$SANDBOX/q.json" "$CONFIG"
    assert_exit 0 main
    assert_eq '{"accelerator":"Alt+Space"}' "$(jq -c .preferences.quickEntryShortcut "$CONFIG")" \
        "quick entry shortcut replacing $value"
done
stub pgrep 'exit 0'

# A setting changed while Claude runs: without a terminal, it isn't quit and the config stays
jq '.preferences.menuBarEnabled = true' "$CONFIG" > "$SANDBOX/changed.json"
cp "$SANDBOX/changed.json" "$CONFIG"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Claude is running; skipping."
assert_eq "$(cat "$SANDBOX/changed.json")" "$(cat "$CONFIG")" "config while Claude runs"
assert_file_not_contains "$STUB_LOG" "osascript"

# brew lists the claude cask, but its app was deleted: status reports it, and the step
# reinstalls it
rm -rf "$APP"
stub brew 'case "$*" in
    "list --cask claude" | "reinstall --cask claude") ;;
    *) exit 1 ;;
esac'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    claude (cask): brew lists it, but its app is gone; run brew reinstall --cask claude"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "brew reinstall --cask claude"

# Without jq, status still reports the cask and the LaunchAgent; only the settings are unknown
no_jq_status() {
    hide jq
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "claude (cask): brew lists it"
    assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.claude-desktop.plist"
    assert_contains "$RUN_OUTPUT" "unknown    Claude desktop app settings: $(missing_cmd_hint jq)"
}
subtest no_jq_status
test_done
