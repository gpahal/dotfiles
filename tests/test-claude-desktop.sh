#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The claude-desktop step merges its settings into the app's config, keeping the keys it doesn't
# set, changes nothing on a re-run, leaves the config alone while Claude runs, and skips on Ubuntu.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v jq &>/dev/null || skip "jq isn't installed"
load_script ai_tools/claude-desktop/install.sh
# The test may run inside the Claude app, which ensure_app_quit handles on its own
running_inside() { false; }
# Keep the real /Applications/Claude.app, present or not, out of the cask checks: the step passes
# that path to install_cask and status_cask, and brew info would give it too
APP="$HOME/Applications/Claude.app"
cask_app_path() { printf '%s\n' "$APP"; }
eval "real_$(declare -f cask_state)"
cask_state() { real_cask_state "$1" "$APP"; }
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
assert_eq "$CONFIG" "$CLAUDE_DESKTOP_CONFIG" "config path"

# Ubuntu: nothing to do
is_macos() { false; }
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "macOS-only"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    Claude desktop app: macOS only"
[ ! -e "$CONFIG" ] || fail "the config was written on Ubuntu"

# macOS, with neither the cask nor the app: status reports it, and the step installs it
is_macos() { true; }
stub brew '[ "$*" == "install --cask claude" ]'
stub pgrep 'exit 1'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    claude (cask)"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installing claude..."
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

# Re-run: nothing to change, so a running Claude doesn't matter
before="$(/bin/ls -i "$CONFIG")"
stub pgrep 'exit 0'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set"
assert_eq "$before" "$(/bin/ls -i "$CONFIG")" "config after a re-run"

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
test_done
