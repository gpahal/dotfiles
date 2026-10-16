#!/bin/bash
set -euo pipefail
# os: macos

# The Stream Deck plugin's open-app opens Claude or Chrome. For a new tab it presses Cmd+T in
# Chrome, then Cmd+V and Cmd+A only when the clipboard holds more than whitespace. A failed open,
# a missing permission, or Chrome not coming to the front fails with a notification. Stubs stand
# in for open, pbpaste, and osascript.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
OPEN_APP="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-app"

# CLIPBOARD is the clipboard's text. The new tab's script logs the keystrokes it would press, or
# fails with NEW_TAB_ERROR.
# shellcheck disable=SC2016 # stub bodies, expanded when they run
stub pbpaste 'printf "%s" "${CLIPBOARD:-}"'
# shellcheck disable=SC2016
stub osascript 'script="$(cat)"
case "$script" in
    *"keystroke \"t\""*)
        if [ -n "${NEW_TAB_ERROR:-}" ]; then echo "$NEW_TAB_ERROR" >&2; exit 1; fi
        case "$script" in *"first application process whose frontmost"*"com.google.Chrome"*) ;; *) exit 1 ;; esac
        echo "  Cmd+T" >> "$STUB_LOG"
        [ "$2" != paste ] || echo "  Cmd+V Cmd+A" >> "$STUB_LOG"
        ;;
    *"display notification"*) echo "  notification: $2" >> "$STUB_LOG" ;;
esac'
stub open
export CLIPBOARD="" NEW_TAB_ERROR=""

# Run open-app for a target, and check its exit status and the lines it added to the stub log,
# other than osascript's and pbpaste's own
check() {
    : > "$STUB_LOG"
    assert_exit "$2" bash "$OPEN_APP" "$1"
    assert_eq "$3" "$(grep -vE '^(osascript|pbpaste)( |$)' "$STUB_LOG")" "$1"
}

check claude 0 "open -b com.anthropic.claudefordesktop"
check chrome 0 "open -b com.google.Chrome"
# An empty clipboard, or only whitespace: a new tab, no paste
check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T"
assert_contains "$RUN_OUTPUT" "chrome-tab: opened a new tab"
CLIPBOARD=$'  \n\t' check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T"
# Text on the clipboard: pasted and selected
CLIPBOARD="https://example.com" check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T
  Cmd+V Cmd+A"
assert_contains "$RUN_OUTPUT" "chrome-tab: opened a new tab with the clipboard pasted"

# A missing permission fails, with a notification that says so
export NEW_TAB_ERROR="execution error: System Events got an error: osascript is not allowed to send keystrokes. (1002)"
check chrome-tab 1 "open -b com.google.Chrome
  notification: Stream Deck lacks a permission: $NEW_TAB_ERROR"
assert_contains "$RUN_OUTPUT" "ERROR $NEW_TAB_ERROR"
# Chrome not coming to the front fails, with a notification pointing at the log
export NEW_TAB_ERROR="execution error: Google Chrome didn't come to the front (-2700)"
check chrome-tab 1 "open -b com.google.Chrome
  notification: Couldn't open a new Chrome tab. See ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log"
export NEW_TAB_ERROR=""

# A failed open fails, with a notification, and sends no keystrokes
stub open 'exit 1'
check chrome-tab 1 "open -b com.google.Chrome
  notification: Couldn't open Google Chrome. Is it installed?"
assert_contains "$RUN_OUTPUT" "ERROR couldn't open Google Chrome"

assert_exit 2 bash "$OPEN_APP" safari
test_done
