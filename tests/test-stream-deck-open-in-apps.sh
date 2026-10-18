#!/bin/bash
set -euo pipefail
# os: macos

# The Stream Deck plugin's open-in opens Claude, Chrome, T3 Code, or Activity Monitor. For a new
# tab it brings Chrome to the front, telling a running Chrome to activate rather than reopening it,
# presses Cmd+T, then Cmd+V and Cmd+A only when the clipboard holds more than whitespace, however
# large, and only while Chrome is still in front. For Gmail it has Chrome select a Gmail tab or open
# the inbox. A failed open, a missing permission, or Chrome not coming to the front fails with a
# notification. Stubs stand in for open, lsappinfo, pbpaste, and osascript.
# tests/test-stream-deck-open-in.sh covers its other targets.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
OPEN_IN="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-in"

# CLIPBOARD is the clipboard's text, or with BIG_CLIPBOARD, hundreds of KB of lines, more than a
# pipe holds. The new tab's script logs the keystrokes it would press, or fails with NEW_TAB_ERROR.
# With FRONT_CHANGES, another app comes to the front during the delay before the paste: a script
# that checks for that before pressing Cmd+V returns "moved". Gmail's script logs the URL it would
# open and prints GMAIL_RESULT, or fails with GMAIL_ERROR. CHROME_RUNNING makes Chrome running.
# shellcheck disable=SC2016 # stub bodies, expanded when they run
stub pbpaste 'if [ -n "${BIG_CLIPBOARD:-}" ]; then yes https://example.com/a/long/path | head -n 20000; else printf "%s" "${CLIPBOARD:-}"; fi'
# shellcheck disable=SC2016
stub lsappinfo '[ -n "${CHROME_RUNNING:-}" ] && [ "$*" == "find bundleid=com.google.Chrome" ] && echo "ASN:0x0-0x3-\"Google Chrome\":"'
# shellcheck disable=SC2016
stub osascript 'script="$(cat)"
case "$script" in
    *"keystroke \"t\""*)
        if [ -n "${NEW_TAB_ERROR:-}" ]; then echo "$NEW_TAB_ERROR" >&2; exit 1; fi
        case "$script" in *"first application process whose frontmost"*"com.google.Chrome"*) ;; *) exit 1 ;; esac
        echo "  Cmd+T" >> "$STUB_LOG"
        [ "$2" == paste ] || exit 0
        if [ -n "${FRONT_CHANGES:-}" ] &&
            printf "%s\n" "$script" | sed -n "/delay 0.15/,/keystroke \"v\"/p" | grep -q frontmost; then
            echo moved
            exit 0
        fi
        echo "  Cmd+V Cmd+A" >> "$STUB_LOG"
        ;;
    *"active tab index"*)
        if [ -n "${GMAIL_ERROR:-}" ]; then echo "$GMAIL_ERROR" >&2; exit 1; fi
        echo "  gmail: $2" >> "$STUB_LOG"
        echo "$GMAIL_RESULT"
        ;;
    *"to activate"*) echo "  activate: ${script#*application id }" >> "$STUB_LOG" ;;
    *"display notification"*) echo "  notification: $2" >> "$STUB_LOG" ;;
esac'
stub open
export CLIPBOARD="" BIG_CLIPBOARD="" FRONT_CHANGES="" CHROME_RUNNING="" NEW_TAB_ERROR="" \
    GMAIL_RESULT=found GMAIL_ERROR=""

# Run open-in for a target, and check its exit status and the lines it added to the stub log,
# other than osascript's, pbpaste's, and lsappinfo's own
check() {
    : > "$STUB_LOG"
    assert_exit "$2" bash "$OPEN_IN" "$1"
    assert_eq "$3" "$(grep -vE '^(osascript|pbpaste|lsappinfo)( |$)' "$STUB_LOG")" "$1"
}

check claude 0 "open -b com.anthropic.claudefordesktop"
check chrome 0 "open -b com.google.Chrome"
check t3-code 0 "open -b com.t3tools.t3code"
check activity-monitor 0 "open -b com.apple.ActivityMonitor"
# A running Chrome, which with no window would open one on a reopen event: the Chrome key opens
# it, which shows a window, and New Tab tells it to activate, so Cmd+T opens the only tab
CHROME_RUNNING=1 check chrome 0 "open -b com.google.Chrome"
CHROME_RUNNING=1 check chrome-tab 0 "  activate: \"com.google.Chrome\" to activate
  Cmd+T"
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
# More text than a pipe holds is pasted too: pbpaste isn't cut off partway, which would fail it
BIG_CLIPBOARD=1 check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T
  Cmd+V Cmd+A"
# Another app comes to the front before the paste: no paste, into it or anywhere
CLIPBOARD="https://example.com" FRONT_CHANGES=1 check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T"
assert_contains "$RUN_OUTPUT" "chrome-tab: opened a new tab, but another app came to the front before the paste"

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

# Gmail: an open tab comes to the front, or a new tab opens the inbox
check gmail 0 "open -b com.google.Chrome
  gmail: https://mail.google.com/mail/u/0/#inbox"
assert_contains "$RUN_OUTPUT" "gmail: brought the Gmail tab to the front"
GMAIL_RESULT=opened check gmail 0 "open -b com.google.Chrome
  gmail: https://mail.google.com/mail/u/0/#inbox"
assert_contains "$RUN_OUTPUT" "gmail: opened Gmail in a new tab"
# A denied Automation prompt for Chrome fails, with a notification that says so
export GMAIL_ERROR="execution error: Not authorized to send Apple events to Google Chrome. (-1743)"
check gmail 1 "open -b com.google.Chrome
  notification: Stream Deck lacks a permission: $GMAIL_ERROR"
assert_contains "$RUN_OUTPUT" "ERROR $GMAIL_ERROR"
export GMAIL_ERROR="execution error: Google Chrome got an error: something else (-2700)"
check gmail 1 "open -b com.google.Chrome
  notification: Couldn't open Gmail. See ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log"
export GMAIL_ERROR=""

# A failed open fails, with a notification, and sends no keystrokes
stub open 'exit 1'
check chrome-tab 1 "open -b com.google.Chrome
  notification: Couldn't open Google Chrome. Is it installed?"
assert_contains "$RUN_OUTPUT" "ERROR couldn't open Google Chrome"

assert_exit 2 bash "$OPEN_IN" safari
test_done
