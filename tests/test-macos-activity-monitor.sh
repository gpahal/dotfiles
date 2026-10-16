#!/bin/bash
set -euo pipefail

# The macos step sets Activity Monitor's View to All Processes, whose menu tag is 100. Activity
# Monitor saves its own value when it quits, so the step offers to quit it first, and skips that
# write when it keeps running. Its status also checks ~/Screenshots.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# A defaults that keeps each value in a file. Activity Monitor runs while $SANDBOX/running exists.
DEFAULTS_DIR="$SANDBOX/defaults"
mkdir -p "$DEFAULTS_DIR"
stub defaults 'file="'"$DEFAULTS_DIR"'/$2.$3"
case "$1" in
    read) [ -f "$file" ] && cat "$file" ;;
    write)
        value="$5"
        [ "$4" != -bool ] || { [ "$5" == true ] && value=1 || value=0; }
        printf "%s\n" "$value" > "$file"
        ;;
esac'
stub killall
# test-diagnostics.sh covers what status reports about FileVault and the firewall
stub fdesetup 'echo "FileVault is On."'
# test-macos-hostname.sh covers the hostname
stub scutil 'echo Garvits-MacBook-Pro'
stub socketfilterfw 'echo "Firewall is enabled. (State = 1)"'
stub pgrep '[ -e "'"$SANDBOX"'/running" ]'
# Quitting it through AppleScript
stub osascript 'rm -f "'"$SANDBOX"'/running"'

load_script macos/install.sh
# shellcheck disable=SC2329 # main calls it
is_macos() { true; }
# test-macos-spotlight.sh covers Spotlight's shortcut
spotlight_shortcut_off() { true; }
SHOW_CATEGORY="$DEFAULTS_DIR/com.apple.ActivityMonitor.ShowCategory"

# Running, and confirm says no without a terminal: the other settings are written, ShowCategory
# isn't, and the step says why
touch "$SANDBOX/running"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Activity Monitor is running"
[ ! -e "$SHOW_CATEGORY" ] || fail "ShowCategory was written while Activity Monitor ran"
assert_file_not_contains "$STUB_LOG" "osascript"
assert_contains "$RUN_OUTPUT" "Set com.apple.dock autohide to true"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    com.apple.ActivityMonitor ShowCategory = 100"

# Not running: it's set to 100, and a re-run has nothing to do
rm "$SANDBOX/running"
assert_exit 0 main
assert_eq 100 "$(cat "$SHOW_CATEGORY")" "ShowCategory"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "macOS defaults are already set."
assert_exit 0 status

# Already 100 while it runs: nothing to say
touch "$SANDBOX/running"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Activity Monitor is running"

# Approved: it quits Activity Monitor, then writes ShowCategory
rm "$SHOW_CATEGORY"
DOTFILES_ASSUME_YES=1 run main
assert_eq 0 "$RUN_STATUS" "exit status after quitting Activity Monitor: $RUN_OUTPUT"
assert_file_contains "$STUB_LOG" 'osascript -e quit app "Activity Monitor"'
assert_eq 100 "$(cat "$SHOW_CATEGORY")" "ShowCategory after quitting Activity Monitor"

# Status reports ~/Screenshots, which the location key points to, when it's gone
rm -rf "$SANDBOX/running" "$HOME/Screenshots"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $HOME/Screenshots directory"
test_done
