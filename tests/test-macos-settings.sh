#!/bin/bash
set -euo pipefail

# The macos step's defaults, Activity Monitor's ShowCategory, and Spotlight's Cmd+Space shortcut.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# defaults prints AppleSymbolicHotKeys as an old-style plist; 61 starts unset, as on a fresh Mac
DEFAULTS_DIR="$SANDBOX/defaults"
mkdir -p "$DEFAULTS_DIR"
stub defaults 'file="'"$DEFAULTS_DIR"'/$2.$3"
case "$1 $2" in
    "read com.apple.symbolichotkeys")
        enabled=1
        [ ! -f "$file.64" ] || enabled="$(cat "$file.64")"
        printf "{\n    164 =     {\n        enabled = 1;\n    };\n    64 =     {\n        enabled = %s;\n        value =         {\n            parameters =             (\n                32,\n                49,\n                1048576\n            );\n            type = standard;\n        };\n    };\n" "$enabled"
        [ ! -f "$file.61" ] || printf "    61 =     {\n        enabled = %s;\n    };\n" "$(cat "$file.61")"
        echo "}"
        ;;
    "write com.apple.symbolichotkeys")
        case "$4 $5" in
            "-dict-add 64") want=1048576 ;;
            "-dict-add 61") echo "wrote 61" >> "$STUB_LOG"; want=786432 ;;
            *) exit 1 ;;
        esac
        case "$6" in *"<key>enabled</key><false/>"*"<integer>$want</integer>"*) echo 0 > "$file.$5" ;; *) exit 1 ;; esac
        ;;
    read*) [ -f "$file" ] && cat "$file" ;;
    write*)
        value="$5"
        [ "$4" != -bool ] || { [ "$5" == true ] && value=1 || value=0; }
        printf "%s\n" "$value" > "$file"
        ;;
esac'
stub killall
stub activateSettings
stub pgrep '[ -e "'"$SANDBOX"'/running" ]'
stub osascript 'rm -f "'"$SANDBOX"'/running"'
# test-diagnostics-macos.sh, test-macos-hostname.sh, and test-macos-security.sh cover these
stub fdesetup 'echo "FileVault is On."'
stub scutil 'echo Garvits-MacBook-Pro'

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
assert_contains "$RUN_OUTPUT" "Set com.apple.dock autohide to true"
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

HOTKEYS="$DEFAULTS_DIR/com.apple.symbolichotkeys.AppleSymbolicHotKeys"

# Ctrl+Opt+Space (61) stays on, since Hammerspoon's hotkeys add Cmd
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Spotlight's Cmd+Space shortcut off, so Vicinae can take it"
assert_not_contains "$RUN_OUTPUT" "input source"
assert_exit 0 main
assert_eq 0 "$(cat "$HOTKEYS.64")" "hotkey 64's enabled"
assert_contains "$RUN_OUTPUT" "Turned off Spotlight's Cmd+Space shortcut"
assert_not_contains "$RUN_OUTPUT" "input source"
assert_file_not_contains "$STUB_LOG" "wrote 61"
[ ! -e "$HOTKEYS.61" ] || fail "the step turned off the next input source's shortcut"
assert_file_contains "$STUB_LOG" "activateSettings -u"
assert_contains "$RUN_OUTPUT" "log out"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Spotlight's Cmd+Space shortcut off"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "macOS defaults are already set."
assert_file_not_contains "$STUB_LOG" "activateSettings"
assert_file_not_contains "$STUB_LOG" "defaults write"
assert_not_contains "$RUN_OUTPUT" "log out"

rm "$HOTKEYS.64"
stub activateSettings 'exit 1'
assert_exit 0 main
assert_eq 0 "$(cat "$HOTKEYS.64")" "hotkey 64's enabled"
assert_contains "$RUN_OUTPUT" "log out"

stub defaults '[ "$1" == read ] || exit 1
printf "{\n    64 =     {\n        value =         {\n            type = standard;\n        };\n    };\n    65 =     {\n        enabled = 0;\n    };\n}\n"'
hotkey_off 64 && fail "hotkey 64 read as off from the next entry's enabled key"
hotkey_off 65 || fail "hotkey 65 read as on"

rm "$HOTKEYS.64"
stub defaults '[ "$1 $2" != "write com.apple.symbolichotkeys" ] || exit 1
[ "$1" != read ] || [ "$2" == com.apple.symbolichotkeys ] || exit 1
[ "$1" != read ] || printf "{\n    64 =     {\n        enabled = 1;\n    };\n}\n"'
replace_fn default_matches 'return 0'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't turn off Spotlight's Cmd+Space shortcut"
test_done
