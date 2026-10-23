#!/bin/bash
# The step's functions call the replaced ones
# shellcheck disable=SC2329
set -euo pipefail

# ai_tools/manual-steps.sh: which apps' notifications still need allowing, read from macOS's
# notification settings, and opening those settings only on a yes.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/manual-steps.sh

# plutil prints $SANDBOX/ncprefs; with no file it fails, as without Full Disk Access
NCPREFS="$SANDBOX/ncprefs"
stub plutil '[ "$*" == "-extract apps xml1 -o - $NOTIFICATION_SETTINGS" ] && [ -f "'"$NCPREFS"'" ] || exit 1
cat "'"$NCPREFS"'"'
export NOTIFICATION_SETTINGS
ALLOWED=$((1 << 25)) TEMPORARY=$((1 << 3)) PERSISTENT=$((1 << 4))
# Usage: apps <bundle id> <flags> ... Each app's nested dict reuses its keys, which mustn't count.
apps() {
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<array>\n'
        while [ $# -gt 0 ]; do
            printf '\t<dict>\n\t\t<key>bundle-id</key>\n\t\t<string>%s</string>\n\t\t<key>flags</key>\n\t\t<integer>%s</integer>\n' "$1" "$2"
            printf '\t\t<key>sub</key>\n\t\t<dict>\n\t\t\t<key>bundle-id</key>\n\t\t\t<string>%s</string>\n' "$1"
            printf '\t\t\t<key>flags</key>\n\t\t\t<integer>%s</integer>\n\t\t</dict>\n\t</dict>\n' "$((ALLOWED | PERSISTENT))"
            shift 2
        done
        printf '</array>\n</plist>\n'
    } > "$NCPREFS"
}

assert_exit 1 notifications_pending com.mitchellh.ghostty
apps com.other.app $((ALLOWED | PERSISTENT)) com.mitchellh.ghostty $((ALLOWED | PERSISTENT | 7))
assert_eq "com.openai.codex" "$(notifications_pending com.mitchellh.ghostty com.openai.codex)" "persistent, and no entry"
apps com.mitchellh.ghostty $((ALLOWED | TEMPORARY))
assert_eq "com.mitchellh.ghostty" "$(notifications_pending com.mitchellh.ghostty)" "banners"
apps com.mitchellh.ghostty "$PERSISTENT"
assert_eq "com.mitchellh.ghostty" "$(notifications_pending com.mitchellh.ghostty)" "not allowed"
apps com.mitchellh.ghostty $((ALLOWED | PERSISTENT | TEMPORARY))
assert_eq "com.mitchellh.ghostty" "$(notifications_pending com.mitchellh.ghostty)" "both styles"

# Ghostty's notifications are the main README's manual step, so they don't count here
ok=$((ALLOWED | PERSISTENT))
apps com.mitchellh.ghostty $((ALLOWED | TEMPORARY)) com.anthropic.claudefordesktop $ok com.openai.codex $ok com.t3tools.t3code $ok
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Default/Extensions/$CLAUDE_CHROME_EXTENSION_ID"
stub open
as_os macos
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Open "

apps com.mitchellh.ghostty $ok com.anthropic.claudefordesktop $((ALLOWED | TEMPORARY)) com.t3tools.t3code $ok
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_exit 0 main
assert_eq "" "$(grep -v '^plutil' "$STUB_LOG" || true)" "commands run without a yes"

answer yes
run open_manual_steps <<< $'\n\n'
assert_eq 0 "$RUN_STATUS" "exit status after opening the settings"
assert_eq "open x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.anthropic.claudefordesktop
open x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.openai.codex" \
    "$(grep '^open' "$STUB_LOG")" "settings opened"

rm "$NCPREFS"
: > "$STUB_LOG"
run open_manual_steps < /dev/null
assert_eq 0 "$RUN_STATUS" "exit status when the notification settings can't be read"
assert_contains "$RUN_OUTPUT" "Couldn't read the notification settings"
assert_not_contains "$RUN_OUTPUT" "notification settings now?"
assert_eq "" "$(grep '^open' "$STUB_LOG" || true)" "settings opened when they can't be read"

as_os ubuntu
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Notifications for"
assert_eq "" "$(cat "$STUB_LOG")" "commands run on Ubuntu"
test_done
