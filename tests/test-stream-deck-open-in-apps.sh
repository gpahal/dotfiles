#!/bin/bash
set -euo pipefail

# open-in's apps, Chrome tabs, and Gmail; test-stream-deck-open-in.sh covers other targets.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
OPEN_IN="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-in"

# BIG_CLIPBOARD is more than a pipe holds. The osascript stub flags a Cmd+T sent with modifiers
# held, and with FRONT_CHANGES answers "moved" if the script rechecks the front app before Cmd+V.
stub pbpaste 'if [ -n "${BIG_CLIPBOARD:-}" ]; then yes https://example.com/a/long/path | head -n 20000; else printf "%s" "${CLIPBOARD:-}"; fi'
stub lsappinfo '[ -n "${CHROME_RUNNING:-}" ] && [ "$*" == "find bundleid=com.google.Chrome" ] && echo "ASN:0x0-0x3-\"Google Chrome\":"'
stub osascript 'script="$(cat)"
case "$script" in
    *"keystroke \"t\""*)
        if [ -n "${NEW_TAB_ERROR:-}" ]; then echo "$NEW_TAB_ERROR" >&2; exit 1; fi
        case "$script" in *"first application process whose frontmost"*"com.google.Chrome"*) ;; *) exit 1 ;; esac
        case "$script" in
            *"modifierFlags"*"if modifiersHeld() then error"*"keystroke \"t\""*) echo "  Cmd+T" >> "$STUB_LOG" ;;
            *) echo "  Cmd+T with the modifiers still held" >> "$STUB_LOG" ;;
        esac
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

# Check open-in's exit status and the stub log, minus osascript, pbpaste, and lsappinfo
check() {
    : > "$STUB_LOG"
    assert_exit "$2" bash "$OPEN_IN" "$1"
    assert_eq "$3" "$(grep -vE '^(osascript|pbpaste|lsappinfo)( |$)' "$STUB_LOG")" "$1"
}

check claude 0 "open -b com.anthropic.claudefordesktop"
check chrome 0 "open -b com.google.Chrome"
check t3-code 0 "open -b com.t3tools.t3code"
check activity-monitor 0 "open -b com.apple.ActivityMonitor"
# A running Chrome with no window would open one on reopen, so New Tab activates it instead
CHROME_RUNNING=1 check chrome 0 "open -b com.google.Chrome"
CHROME_RUNNING=1 check chrome-tab 0 "  activate: \"com.google.Chrome\" to activate
  Cmd+T"
check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T"
assert_contains "$RUN_OUTPUT" "chrome-tab: opened a new tab"
CLIPBOARD=$'  \n\t' check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T"
CLIPBOARD="https://example.com" check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T
  Cmd+V Cmd+A"
assert_contains "$RUN_OUTPUT" "chrome-tab: opened a new tab with the clipboard pasted"
BIG_CLIPBOARD=1 check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T
  Cmd+V Cmd+A"
CLIPBOARD="https://example.com" FRONT_CHANGES=1 check chrome-tab 0 "open -b com.google.Chrome
  Cmd+T"
assert_contains "$RUN_OUTPUT" "chrome-tab: opened a new tab, but another app came to the front before the paste"
# While another New Tab runs, from Hammerspoon or Stream Deck, this one does nothing
mkdir "$TMPDIR/dotfiles-new-tab.lock"
echo "$$" > "$TMPDIR/dotfiles-new-tab.lock/pid"
check chrome-tab 0 ""
assert_contains "$RUN_OUTPUT" "chrome-tab: another New Tab is still running, so this one did nothing"
rm -r "$TMPDIR/dotfiles-new-tab.lock"

export NEW_TAB_ERROR="execution error: System Events got an error: osascript is not allowed to send keystrokes. (1002)"
check chrome-tab 1 "open -b com.google.Chrome
  notification: Stream Deck lacks a permission: $NEW_TAB_ERROR"
assert_contains "$RUN_OUTPUT" "ERROR $NEW_TAB_ERROR"
export NEW_TAB_ERROR="execution error: Google Chrome didn't come to the front (-2700)"
check chrome-tab 1 "open -b com.google.Chrome
  notification: Couldn't open a new Chrome tab. See ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log"
export NEW_TAB_ERROR=""

check gmail 0 "open -b com.google.Chrome
  gmail: https://mail.google.com/mail/u/0/#inbox"
assert_contains "$RUN_OUTPUT" "gmail: brought the Gmail tab to the front"
GMAIL_RESULT=opened check gmail 0 "open -b com.google.Chrome
  gmail: https://mail.google.com/mail/u/0/#inbox"
assert_contains "$RUN_OUTPUT" "gmail: opened Gmail in a new tab"
export GMAIL_ERROR="execution error: Not authorized to send Apple events to Google Chrome. (-1743)"
check gmail 1 "open -b com.google.Chrome
  notification: Stream Deck lacks a permission: $GMAIL_ERROR"
assert_contains "$RUN_OUTPUT" "ERROR $GMAIL_ERROR"
export GMAIL_ERROR="execution error: Google Chrome got an error: something else (-2700)"
check gmail 1 "open -b com.google.Chrome
  notification: Couldn't open Gmail. See ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log"
export GMAIL_ERROR=""

stub open 'exit 1'
check chrome-tab 1 "open -b com.google.Chrome
  notification: Couldn't open Google Chrome. Is it installed?"
assert_contains "$RUN_OUTPUT" "ERROR couldn't open Google Chrome"

assert_exit 2 bash "$OPEN_IN" safari
test_done
