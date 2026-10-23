#!/bin/bash
set -euo pipefail

# The macos step's sudo items: the hostname, the firewall, its stealth mode, and automatic App Store
# updates.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# socketfilterfw and scutil keep their settings as files in $STATE. The step runs socketfilterfw
# from $APP_FIREWALL_DIR, set to the stubs' dir below.
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
stub scutil 'state="'"$STATE"'"
case "$1 $2" in
    "--get HostName") cat "$state/hostname" 2> /dev/null ;;
    "--get LocalHostName") echo Garvits-MacBook-Pro ;;
    "--set HostName") echo "$3" > "$state/hostname" ;;
    *) exit 1 ;;
esac'
stub_defaults
stub_sudo_exec

load_script macos/install.sh
as_os macos
# sudo and what it runs come from the system's dirs, after the stubs
case "$PATH" in
    "$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin:"*) ;;
    *) fail "the system's dirs don't lead PATH: $PATH" ;;
esac
replace_fn each_default
replace_fn hotkey_off 'return 0'
replace_fn status_filevault
# shellcheck disable=SC2034 # the step reads them
APP_FIREWALL_DIR="$STUB_DIR" APP_STORE_PREFS="$STATE/com.apple.commerce"
# shellcheck disable=SC2034
SOFTWARE_UPDATE_PREFS="$STATE/com.apple.SoftwareUpdate"

# Ghostty drops an OSC 7 report whose host has characters a URL can't hold
echo "Unknown_d6:96:0e:05:c6:0a" > "$STATE/hostname"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Hostname set"
assert_contains "$RUN_OUTPUT" "missing    Application firewall on"
assert_contains "$RUN_OUTPUT" "missing    Firewall stealth mode on"
assert_contains "$RUN_OUTPUT" "missing    App Store apps update automatically"
assert_file_not_contains "$STUB_LOG" "sudo"

answer no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged."
assert_file_not_contains "$STUB_LOG" "sudo"
assert_exit 3 main --status

# One confirm covers all four sudo items
answer yes
wrap_fn confirm 'echo "$1" >> "$SANDBOX/confirms"
real_confirm "$@"'
assert_exit 0 main
assert_eq 1 "$(wc -l < "$SANDBOX/confirms" | tr -d ' ')" "confirms for four sudo items"
restore_fn confirm
assert_eq Garvits-MacBook-Pro "$(cat "$STATE/hostname")" "hostname"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Hostname set"
assert_contains "$RUN_OUTPUT" "ok         Application firewall on"
assert_contains "$RUN_OUTPUT" "ok         Firewall stealth mode on"
assert_contains "$RUN_OUTPUT" "ok         App Store apps update automatically"

: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "sudo"

# Only one of the two App Store keys set still needs the fix
rm "$SANDBOX/defaults/com.apple.SoftwareUpdate.AutomaticallyInstallAppUpdates"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    App Store apps update automatically"

# An unset hostname needs the fix too
rm "$STATE/hostname"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Hostname set"

rm -f "$STATE"/*
stub sudo 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't set the hostname."
assert_contains "$RUN_OUTPUT" "Couldn't turn on the application firewall."
assert_contains "$RUN_OUTPUT" "Couldn't turn on the firewall's stealth mode."
assert_contains "$RUN_OUTPUT" "Couldn't turn on automatic App Store updates."
test_done
