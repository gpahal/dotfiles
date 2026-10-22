#!/bin/bash
set -euo pipefail

# The macos step's defaults, Activity Monitor's ShowCategory, and Spotlight's Cmd+Space shortcut.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# defaults prints AppleSymbolicHotKeys as an old-style plist, with 64 on until it's written off
DEFAULTS_DIR="$SANDBOX/defaults"
HOTKEYS="$DEFAULTS_DIR/com.apple.symbolichotkeys.AppleSymbolicHotKeys"
stub_defaults 'hotkeys="'"$HOTKEYS"'"
case "$1 $2" in
    "read com.apple.symbolichotkeys")
        enabled=1
        [ ! -f "$hotkeys.64" ] || enabled="$(cat "$hotkeys.64")"
        printf "{\n    164 =     {\n        enabled = 1;\n    };\n    64 =     {\n        enabled = %s;\n        value =         {\n            parameters =             (\n                32,\n                49,\n                1048576\n            );\n            type = standard;\n        };\n    };\n}\n" "$enabled"
        exit 0
        ;;
    "write com.apple.symbolichotkeys")
        [ "$4 $5" == "-dict-add 64" ] || exit 1
        case "$6" in *"<key>enabled</key><false/>"*"<integer>1048576</integer>"*) echo 0 > "$hotkeys.64" ;; *) exit 1 ;; esac
        exit 0
        ;;
esac'
stub killall
stub activateSettings
stub pgrep '[ -e "'"$SANDBOX"'/running" ]'
stub osascript 'rm -f "'"$SANDBOX"'/running"'
# test-macos-security.sh covers the hostname
stub fdesetup 'echo "FileVault is On."'
stub scutil 'echo Garvits-MacBook-Pro'

# test-macos-security.sh covers these sudo items
security_on() {
    replace_fn firewall_on 'return 0'
    replace_fn stealth_mode_on 'return 0'
    replace_fn app_store_auto_updates 'return 0'
}

load_script macos/install.sh
as_os macos
security_on
SHOW_CATEGORY="$DEFAULTS_DIR/com.apple.ActivityMonitor.ShowCategory"

touch "$SANDBOX/running"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Activity Monitor is running"
[ ! -e "$SHOW_CATEGORY" ] || fail "ShowCategory was written while Activity Monitor ran"
assert_file_not_contains "$STUB_LOG" "osascript"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    com.apple.ActivityMonitor ShowCategory = 100"

rm "$SANDBOX/running"
assert_exit 0 main
assert_eq 100 "$(cat "$SHOW_CATEGORY")" "ShowCategory"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "macOS defaults are already set."
assert_exit 0 status

touch "$SANDBOX/running"
rm "$SHOW_CATEGORY"
answer yes
run main
assert_eq 0 "$RUN_STATUS" "exit status after quitting Activity Monitor: $RUN_OUTPUT"
assert_file_contains "$STUB_LOG" 'osascript -e quit app "Activity Monitor"'
assert_eq 100 "$(cat "$SHOW_CATEGORY")" "ShowCategory after quitting Activity Monitor"

rm -f "$DEFAULTS_DIR"/*
: > "$STUB_LOG"
load_script macos/install.sh
as_os macos
security_on

assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Spotlight's Cmd+Space shortcut off, so Vicinae can take it"
assert_exit 0 main
assert_eq 0 "$(cat "$HOTKEYS.64")" "hotkey 64's enabled"
assert_file_contains "$STUB_LOG" "activateSettings -u"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Spotlight's Cmd+Space shortcut off"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "macOS defaults are already set."
assert_file_not_contains "$STUB_LOG" "activateSettings"
assert_file_not_contains "$STUB_LOG" "defaults write"

# A failed write fails the step after it sets the rest
rm -f "$DEFAULTS_DIR"/*
: > "$STUB_LOG"
echo com.apple.finder > "$SANDBOX/defaults-fail"
assert_exit 1 main
assert_eq 1 "$(cat "$DEFAULTS_DIR/com.apple.dock.autohide")" "dock autohide after a failed Finder write"
assert_file_contains "$STUB_LOG" "killall Dock"

# A sandboxed app's domain needs Full Disk Access, which doesn't fail the step, and status can't
# read it
rm -f "$DEFAULTS_DIR"/*
echo com.apple.TextEdit > "$SANDBOX/defaults-fail"
mkdir -p "$HOME/Library/Containers/com.apple.TextEdit"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Full Disk Access"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "com.apple.TextEdit RichText"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified com.apple.TextEdit RichText = 0"
rm -rf "$HOME/Library/Containers/com.apple.TextEdit"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    com.apple.TextEdit RichText = 0"
rm "$SANDBOX/defaults-fail"

stub defaults '[ "$1" == read ] || exit 1
printf "{\n    64 =     {\n        value =         {\n            type = standard;\n        };\n    };\n    65 =     {\n        enabled = 0;\n    };\n}\n"'
hotkey_off 64 && fail "hotkey 64 read as off from the next entry's enabled key"
hotkey_off 65 || fail "hotkey 65 read as on"
test_done
