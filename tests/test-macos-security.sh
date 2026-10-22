#!/bin/bash
set -euo pipefail

# The macos step's sudo items for the firewall, its stealth mode, and automatic App Store updates.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# socketfilterfw and defaults keep their settings as files in $STATE
STATE="$SANDBOX/state"
mkdir -p "$STATE" "$HOME/Screenshots"
stub socketfilterfw 'state="'"$STATE"'"
case "$1 ${2:-}" in
    "--getglobalstate ") [ -f "$state/firewall" ] && echo "Firewall is enabled. (State = 1)" || echo "Firewall is disabled. (State = 0)" ;;
    "--getstealthmode ") [ -f "$state/stealth" ] && echo "Firewall stealth mode is on" || echo "Firewall stealth mode is off" ;;
    "--setglobalstate on") touch "$state/firewall" ;;
    "--setstealthmode on") touch "$state/stealth" ;;
    *) exit 1 ;;
esac'
stub defaults 'file="$2.$3"
case "$1 ${4:-} ${5:-}" in
    "read  ") cat "$file" 2> /dev/null ;;
    "write -bool true") echo 1 > "$file" ;;
    *) exit 1 ;;
esac'
stub scutil 'echo Garvits-MacBook-Pro'
stub_sudo_exec

load_script macos/install.sh
as_os macos
replace_fn each_default
replace_fn hotkey_off 'return 0'
replace_fn status_filevault
APP_STORE_PREFS="$STATE/com.apple.commerce"
SOFTWARE_UPDATE_PREFS="$STATE/com.apple.SoftwareUpdate"

assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Application firewall on"
assert_contains "$RUN_OUTPUT" "missing    Firewall stealth mode on"
assert_contains "$RUN_OUTPUT" "missing    App Store apps update automatically"
assert_file_not_contains "$STUB_LOG" "sudo"

answer no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turn on the application firewall"
assert_contains "$RUN_OUTPUT" "Left unchanged."
assert_file_not_contains "$STUB_LOG" "sudo"
assert_exit 3 status

answer yes
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turned on the application firewall"
assert_contains "$RUN_OUTPUT" "Turned on the firewall's stealth mode"
assert_contains "$RUN_OUTPUT" "Turned on automatic App Store updates"
assert_file_contains "$STUB_LOG" "socketfilterfw --setglobalstate on"
assert_file_contains "$STUB_LOG" "socketfilterfw --setstealthmode on"
assert_file_contains "$STUB_LOG" "defaults write $APP_STORE_PREFS AutoUpdate -bool true"
assert_file_contains "$STUB_LOG" "defaults write $SOFTWARE_UPDATE_PREFS AutomaticallyInstallAppUpdates -bool true"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Application firewall on"
assert_contains "$RUN_OUTPUT" "ok         Firewall stealth mode on"
assert_contains "$RUN_OUTPUT" "ok         App Store apps update automatically"

: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "sudo"

# Only one of the two App Store keys set still needs the fix
rm "$SOFTWARE_UPDATE_PREFS.AutomaticallyInstallAppUpdates"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    App Store apps update automatically"

rm -f "$STATE"/*
stub sudo 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't turn on the application firewall."
assert_contains "$RUN_OUTPUT" "Couldn't turn on the firewall's stealth mode."
assert_contains "$RUN_OUTPUT" "Couldn't turn on automatic App Store updates."
test_done
