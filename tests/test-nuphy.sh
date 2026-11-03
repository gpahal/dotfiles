#!/bin/bash
# shellcheck disable=SC2329

# nuphy/setup.sh: it stops before opening anything when it can't reach the keyboard, walks through
# each import with the file's path on the clipboard, and saves only new, matching exports under the
# repo's names.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script nuphy/setup.sh
sandbox_paths nuphy/setup.sh
as_os macos
NUPHY_DIR="$SANDBOX/nuphy"
CHROME_APP="$SANDBOX/Google Chrome.app"
mkdir -p "$NUPHY_DIR" "$CHROME_APP" "$HOME/Downloads"
cp "$REPO_DIR"/nuphy/*.json "$NUPHY_DIR/"
replace_fn is_interactive true
answer yes
stub pbcopy 'cat >> "$SANDBOX/clipboard"; echo >> "$SANDBOX/clipboard"'
stub open
plugged_in() {
    stub ioreg 'echo "  |   \"idVendor\" = 6645"'
}
unplugged() {
    stub ioreg 'echo "  |   \"idVendor\" = 1133"'
}

# The repo's files are what the script names
for backup in "${BACKUPS[@]}"; do
    [ -f "$REPO_DIR/nuphy/${backup%%|*}" ] || fail "nuphy/${backup%%|*} is missing"
done

# Nothing opens without the keyboard on USB, Chrome, or a terminal
unplugged
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "The Air75 V3 isn't on USB."
assert_file_not_contains "$STUB_LOG" "open"
plugged_in
mv "$CHROME_APP" "$CHROME_APP.gone"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Google Chrome isn't installed."
mv "$CHROME_APP.gone" "$CHROME_APP"
replace_fn is_interactive false
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run this from a terminal"
replace_fn is_interactive true
rm "$NUPHY_DIR/air75-v3-windows-mode.json"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "air75-v3-windows-mode.json is missing."
assert_file_not_contains "$STUB_LOG" "open"
cp "$REPO_DIR/nuphy/air75-v3-windows-mode.json" "$NUPHY_DIR/"

# A no leaves the keyboard alone
answer no
assert_exit 0 main import
assert_contains "$RUN_OUTPUT" "Left the keyboard unchanged."
assert_file_not_contains "$STUB_LOG" "open"
answer yes

# Each import gets its file's path on the clipboard, in order
rm -f "$SANDBOX/clipboard"
assert_exit 0 main import < /dev/null
assert_file_contains "$STUB_LOG" "open -a $CHROME_APP $NUPHY_IO_URL"
assert_eq "$NUPHY_DIR/air75-v3-mac-mode.json
$NUPHY_DIR/air75-v3-windows-mode.json
$NUPHY_DIR/air75-v3-macro-screenshot.json" "$(cat "$SANDBOX/clipboard")" "the paths put on the clipboard"
assert_contains "$RUN_OUTPUT" "4/4. Import macro 1"
assert_contains "$RUN_OUTPUT" "Cmd+Shift+G"

# Export saves the newest new export of each under the repo's name, and leaves the rest
cd "$HOME/Downloads"
echo '{"c": "old", "k": "old"}' > "Air75_V3_Mode_Config_mac.json"
touch -t 202601010000 "Air75_V3_Mode_Config_mac.json"
echo "not an export" > "Notes.json"
# The person exports while the script waits: a mode twice, so Chrome adds " (1)", and the macro
stub open 'cd "$HOME/Downloads"
echo "{\"c\": \"first\", \"k\": \"x\"}" > "Air75_V3_Mode_Config_mac.json"
touch -t 203001010000 "Air75_V3_Mode_Config_mac.json"
echo "{\"c\": \"second\", \"k\": \"x\"}" > "Air75_V3_Mode_Config_mac (1).json"
touch -t 203001010001 "Air75_V3_Mode_Config_mac (1).json"
printf "%%7B%%22used%%22%%7D" > "MACRO 1.json"
touch -t 203001010000 "MACRO 1.json"'
snapshot "$NUPHY_DIR/air75-v3-windows-mode.json"
assert_exit 0 main export < /dev/null
assert_eq '{"c": "second", "k": "x"}' "$(cat "$NUPHY_DIR/air75-v3-mac-mode.json")" "the Mac mode saved"
assert_eq '%7B%22used%22%7D' "$(cat "$NUPHY_DIR/air75-v3-macro-screenshot.json")" "the macro saved"
assert_unchanged "$NUPHY_DIR/air75-v3-windows-mode.json" "without a new export"
assert_contains "$RUN_OUTPUT" "Found no new export of the Windows mode"
assert_contains "$RUN_OUTPUT" "Commit $NUPHY_DIR to keep them."
[ -f "Air75_V3_Mode_Config_mac.json" ] && [ -f "Notes.json" ] || fail "export moved a file it didn't save"
[ ! -e "MACRO 1.json" ] || fail "the saved macro was left in Downloads"

# A new file with an export's name but not its contents stays where it is, and fails the run
rm "Air75_V3_Mode_Config_mac.json"
stub open 'echo "<html>" > "$HOME/Downloads/Air75_V3_Mode_Config_windows.json"
touch -t 203001010000 "$HOME/Downloads/Air75_V3_Mode_Config_windows.json"'
assert_exit 1 main export < /dev/null
assert_contains "$RUN_OUTPUT" "isn't a NuPhy IO export of the Windows mode"
assert_unchanged "$NUPHY_DIR/air75-v3-windows-mode.json" "after a bad export"
[ -f "Air75_V3_Mode_Config_windows.json" ] || fail "the bad export was moved"

# Ubuntu: the keyboard from sysfs, and Chrome only at the desktop
as_os ubuntu
cd "$SANDBOX"
USB_DEVICES_DIR="$SANDBOX/usb-devices"
stub google-chrome
stub wl-copy
mkdir -p "$USB_DEVICES_DIR/1-1" "$USB_DEVICES_DIR/1-2"
echo 046d > "$USB_DEVICES_DIR/1-1/idVendor"
unset WAYLAND_DISPLAY DISPLAY
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run this at the desktop"
export WAYLAND_DISPLAY=wayland-0
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "The Air75 V3 isn't on USB."
echo 19f5 > "$USB_DEVICES_DIR/1-2/idVendor"
assert_exit 0 main < /dev/null
# Chrome starts in the background, so its stub may log after the script ends
wait_for grep -qF "google-chrome $NUPHY_IO_URL" "$STUB_LOG" || fail "Chrome wasn't opened at NuPhy IO"
assert_contains "$RUN_OUTPUT" "Ctrl+L"
test_done
