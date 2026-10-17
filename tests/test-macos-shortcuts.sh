#!/bin/bash
set -euo pipefail
# os: macos

# The macos step turns off Spotlight's Cmd+Space shortcut (symbolic hotkey 64), so Raycast can
# take it, and the next input source's Ctrl+Opt+Space (61), so Hammerspoon can, and applies them
# with activateSettings. Its status checks them. The step says to log out only after a change that
# needs it: an NSGlobalDomain key, or a shortcut when activateSettings can't apply it.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# A defaults that keeps each value in a file. AppleSymbolicHotKeys reads back in the old-style
# plist format defaults prints, with hotkeys 64 and 61 on until a -dict-add turns each off. 61
# starts unset, as on a Mac whose input source shortcuts were never changed.
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
            "-dict-add 61") want=786432 ;;
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
stub pgrep 'exit 1'
# test-diagnostics-macos.sh covers what status reports about FileVault and the firewall
stub fdesetup 'echo "FileVault is On."'
# test-macos-hostname.sh covers the hostname
stub scutil 'echo Garvits-MacBook-Pro'
stub socketfilterfw 'echo "Firewall is enabled. (State = 1)"'

load_script macos/install.sh
# shellcheck disable=SC2329 # main calls it
is_macos() { true; }
HOTKEYS="$DEFAULTS_DIR/com.apple.symbolichotkeys.AppleSymbolicHotKeys"

# First run: the shortcuts go off and apply now, and the global keys need a logout
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Spotlight's Cmd+Space shortcut off, so Raycast can take it"
assert_contains "$RUN_OUTPUT" "missing    The next input source's Ctrl+Opt+Space shortcut off, so Hammerspoon can take it"
assert_exit 0 main
assert_eq 0 "$(cat "$HOTKEYS.64")" "hotkey 64's enabled"
assert_eq 0 "$(cat "$HOTKEYS.61")" "hotkey 61's enabled"
assert_contains "$RUN_OUTPUT" "Turned off Spotlight's Cmd+Space shortcut"
assert_contains "$RUN_OUTPUT" "Turned off the next input source's Ctrl+Opt+Space shortcut"
assert_file_contains "$STUB_LOG" "activateSettings -u"
assert_contains "$RUN_OUTPUT" "log out"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Spotlight's Cmd+Space shortcut off"
assert_contains "$RUN_OUTPUT" "ok         The next input source's Ctrl+Opt+Space shortcut off"

# Re-run: nothing to do, nothing applied, no logout note
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "macOS defaults are already set."
assert_file_not_contains "$STUB_LOG" "activateSettings"
assert_file_not_contains "$STUB_LOG" "defaults write"
assert_not_contains "$RUN_OUTPUT" "log out"

# Only one shortcut changed, and activateSettings fails: log out to apply it
rm "$HOTKEYS.61"
stub activateSettings 'exit 1'
assert_exit 0 main
assert_eq 0 "$(cat "$HOTKEYS.61")" "hotkey 61's enabled"
assert_not_contains "$RUN_OUTPUT" "Spotlight"
assert_contains "$RUN_OUTPUT" "log out"

# A failed write fails the step
rm "$HOTKEYS.64"
stub defaults '[ "$1 $2" != "write com.apple.symbolichotkeys" ] || exit 1
[ "$1" != read ] || [ "$2" == com.apple.symbolichotkeys ] || exit 1
[ "$1" != read ] || printf "{\n    64 =     {\n        enabled = 1;\n    };\n}\n"'
default_matches() { true; }
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't turn off Spotlight's Cmd+Space shortcut"
test_done
