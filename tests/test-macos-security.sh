#!/bin/bash

# The macos step: its defaults, Activity Monitor's ShowCategory, and Spotlight's Cmd+Space shortcut;
# and its sudo items: the hostname, the firewall, its stealth mode, and automatic App Store updates.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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
    "--get LocalHostName") echo Garvits-Mac ;;
    "--set HostName") echo "$3" > "$state/hostname" ;;
    *) exit 1 ;;
esac'
# A defaults keeping each key in $SANDBOX/defaults/<domain>.<key>, by the domain's last path part,
# with a -bool read back as 1 or 0. A write to a domain listed in $SANDBOX/defaults-fail fails. The
# optional body runs first.
stub_defaults() {
    mkdir -p "$SANDBOX/defaults"
    stub defaults "${1:-}
$(printf 'sandbox=%q' "$SANDBOX")"'
file="$sandbox/defaults/${2##*/}.$3"
case "$1" in
    read) cat "$file" 2> /dev/null ;;
    write)
        ! grep -qxF "$2" "$sandbox/defaults-fail" 2> /dev/null || exit 1
        value="$5"
        [ "$4" != -bool ] || { [ "$5" == true ] && value=1 || value=0; }
        printf "%s\n" "$value" > "$file"
        ;;
    *) exit 1 ;;
esac'
}

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
stub pgrep '[ -e "$SANDBOX/running" ]'
stub osascript 'rm -f "$SANDBOX/running"'
stub fdesetup 'echo "FileVault is On."'
stub_sudo_exec

load_script macos/install.sh
as_os macos
# sudo and what it runs come from the system's dirs, after the stubs
case "$PATH" in
    "$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin:"*) ;;
    *) fail "the system's dirs don't lead PATH: $PATH" ;;
esac
# shellcheck disable=SC2034 # the step reads them
APP_FIREWALL_DIR="$STUB_DIR" APP_STORE_PREFS="$STATE/com.apple.commerce"
# shellcheck disable=SC2034
SOFTWARE_UPDATE_PREFS="$STATE/com.apple.SoftwareUpdate"

# --- the defaults; sudo_items covers the sudo items ---
security_on() {
    replace_fn firewall_on 'return 0'
    replace_fn stealth_mode_on 'return 0'
    replace_fn app_store_auto_updates 'return 0'
}

defaults_items() {
    local show_category="$DEFAULTS_DIR/com.apple.ActivityMonitor.ShowCategory"
    echo Garvits-Mac > "$STATE/hostname"
    security_on

    touch "$SANDBOX/running"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Activity Monitor is running"
    [ ! -e "$show_category" ] || fail "ShowCategory was written while Activity Monitor ran"
    assert_file_not_contains "$STUB_LOG" "osascript"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    com.apple.ActivityMonitor ShowCategory = 100"

    rm "$SANDBOX/running"
    assert_exit 0 main
    assert_eq 100 "$(cat "$show_category")" "ShowCategory"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "macOS defaults are already set."
    assert_exit 0 main --status

    touch "$SANDBOX/running"
    rm "$show_category"
    answer yes
    run main
    assert_eq 0 "$RUN_STATUS" "exit status after quitting Activity Monitor: $RUN_OUTPUT"
    assert_file_contains "$STUB_LOG" 'osascript -e quit app "Activity Monitor"'
    assert_eq 100 "$(cat "$show_category")" "ShowCategory after quitting Activity Monitor"

    rm -f "$DEFAULTS_DIR"/*
    : > "$STUB_LOG"
    load_script macos/install.sh
    as_os macos
    security_on

    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Spotlight's Cmd+Space shortcut off, so Vicinae can take it"
    assert_exit 0 main
    assert_eq 0 "$(cat "$HOTKEYS.64")" "hotkey 64's enabled"
    assert_file_contains "$STUB_LOG" "activateSettings -u"
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         Spotlight's Cmd+Space shortcut off"

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
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "unverified com.apple.TextEdit RichText = 0"
    rm -rf "$HOME/Library/Containers/com.apple.TextEdit"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    com.apple.TextEdit RichText = 0"
    rm -f "$SANDBOX/defaults-fail" "$DEFAULTS_DIR"/* "$STATE"/*
}
subtest defaults_items

# --- the sudo items ---
sudo_items() {
    replace_fn each_default
    replace_fn hotkey_off 'return 0'
    replace_fn status_filevault
    : > "$STUB_LOG"

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
    assert_eq Garvits-Mac "$(cat "$STATE/hostname")" "hostname"
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         Hostname set"
    assert_contains "$RUN_OUTPUT" "ok         Application firewall on"
    assert_contains "$RUN_OUTPUT" "ok         Firewall stealth mode on"
    assert_contains "$RUN_OUTPUT" "ok         App Store apps update automatically"

    assert_exit 0 main
    assert_file_not_contains "$STUB_LOG" "sudo"

    # Only one of the two App Store keys set still needs the fix
    rm "$DEFAULTS_DIR/com.apple.SoftwareUpdate.AutomaticallyInstallAppUpdates"
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
}
subtest sudo_items

stub defaults '[ "$1" == read ] || exit 1
printf "{\n    64 =     {\n        value =         {\n            type = standard;\n        };\n    };\n    65 =     {\n        enabled = 0;\n    };\n}\n"'
hotkey_off 64 && fail "hotkey 64 read as off from the next entry's enabled key"
hotkey_off 65 || fail "hotkey 65 read as on"
test_done
