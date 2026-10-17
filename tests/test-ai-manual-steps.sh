#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# ai_tools/manual-steps.sh prints the README's manual steps for the OS. On macOS it reads each
# app's notification flags, counting only Allowed with the Persistent style, and offers to open
# the settings for the apps still to do, and only those.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/manual-steps.sh

# plutil reads the notification settings from $SANDBOX/ncprefs, as lines of <key>=<value>. With
# no file, it fails, as it does without Full Disk Access.
NCPREFS="$SANDBOX/ncprefs"
stub plutil '[ "$1" == -extract ] && [ -f "'"$NCPREFS"'" ] || exit 1
value="$(grep -F "$2=" "'"$NCPREFS"'" | head -1)"
[ -n "$value" ] || exit 1
echo "${value#*=}"'
ALLOWED=$((1 << 25)) TEMPORARY=$((1 << 3)) PERSISTENT=$((1 << 4))
# Usage: apps <bundle id> <flags> ...
apps() {
    local i=0
    : > "$NCPREFS"
    while [ $# -gt 0 ]; do
        printf 'apps.%s.bundle-id=%s\napps.%s.flags=%s\n' "$i" "$1" "$i" "$2" >> "$NCPREFS"
        i=$((i + 1))
        shift 2
    done
    echo "apps=$i" >> "$NCPREFS"
}

# notifications_pending
assert_exit 1 notifications_pending com.mitchellh.ghostty
apps com.other.app $((ALLOWED | PERSISTENT)) com.mitchellh.ghostty $((ALLOWED | PERSISTENT | 7))
assert_eq "com.openai.codex" "$(notifications_pending com.mitchellh.ghostty com.openai.codex)" "persistent, and no entry"
apps com.mitchellh.ghostty $((ALLOWED | TEMPORARY))
assert_eq "com.mitchellh.ghostty" "$(notifications_pending com.mitchellh.ghostty)" "banners"
apps com.mitchellh.ghostty "$PERSISTENT"
assert_eq "com.mitchellh.ghostty" "$(notifications_pending com.mitchellh.ghostty)" "not allowed"
apps com.mitchellh.ghostty $((ALLOWED | PERSISTENT | TEMPORARY))
assert_eq "com.mitchellh.ghostty" "$(notifications_pending com.mitchellh.ghostty)" "both styles"

# Everything done: nothing to offer. The extension is installed, so the real Chrome doesn't count.
ok=$((ALLOWED | PERSISTENT))
apps com.mitchellh.ghostty $ok com.anthropic.claudefordesktop $ok com.openai.codex $ok com.t3tools.t3code $ok
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Default/Extensions/$CLAUDE_CHROME_EXTENSION_ID"
stub open
is_macos() { true; }
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Remaining AI tool steps on macOS"
assert_contains "$RUN_OUTPUT" "Notifications for Ghostty, Claude, ChatGPT, and T3 Code are already allowed and Persistent."
assert_contains "$RUN_OUTPUT" "Claude in Chrome extension already installed."
assert_not_contains "$RUN_OUTPUT" "Open "

# Two apps still to do. DOTFILES_ASSUME_YES doesn't open anything, nor does a no.
apps com.mitchellh.ghostty $ok com.anthropic.claudefordesktop $((ALLOWED | TEMPORARY)) com.t3tools.t3code $ok
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Not opening the notification settings: DOTFILES_ASSUME_YES is set."
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Not opening"
assert_eq "" "$(cat "$STUB_LOG" | grep -v '^plutil' || true)" "commands run without a yes"

# A yes opens each one's settings, waiting for Enter in between
confirm() { true; }
run open_manual_steps <<< $'\n\n'
assert_eq 0 "$RUN_STATUS" "exit status after opening the settings"
assert_eq "open x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.anthropic.claudefordesktop
open x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.openai.codex" \
    "$(grep '^open' "$STUB_LOG")" "settings opened"
assert_contains "$RUN_OUTPUT" "scripts/test-notification.sh"

# Settings it can't read, as without Full Disk Access: it prints the instruction without asking
# to open them
rm "$NCPREFS"
: > "$STUB_LOG"
run open_manual_steps < /dev/null
assert_eq 0 "$RUN_STATUS" "exit status when the notification settings can't be read"
assert_contains "$RUN_OUTPUT" "Couldn't read the notification settings"
assert_not_contains "$RUN_OUTPUT" "notification settings now?"
assert_eq "" "$(grep '^open' "$STUB_LOG" || true)" "settings opened when they can't be read"

# Ubuntu prints its own section, and --status prints nothing
is_macos() { false; }
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Remaining AI tool steps on Ubuntu"
assert_not_contains "$RUN_OUTPUT" "Notifications for"
assert_eq "" "$(cat "$STUB_LOG")" "commands run on Ubuntu"
assert_exit 0 main --status
assert_eq "" "$RUN_OUTPUT" "--status output"
test_done
