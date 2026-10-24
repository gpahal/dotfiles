#!/bin/bash
# The step's functions call the replaced ones
# shellcheck disable=SC2329

# ai_tools/manual-steps/install.sh: which apps' notifications still need allowing, read from macOS's
# notification settings, opening those settings only on a yes, and its other checks.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script ai_tools/manual-steps/install.sh

# expect <status> <check...>: runs the check in this shell, so the test can read its MANUAL_DETAIL
expect() {
    local want="$1" got=0
    shift
    MANUAL_DETAIL=""
    "$@" > "$SANDBOX/check-output" 2>&1 || got=$?
    assert_eq "$want" "$got" "'$*' exit status"
}

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

# The other macOS checks: signed out of Claude Code, and no answer from GitHub
stub claude 'exit 1'
stub gh 'exit 1'
as_os macos

# Ghostty's notifications are the main README's manual step, so they don't count here. With every
# app set and the extension installed, nothing opens.
ok=$((ALLOWED | PERSISTENT))
apps com.mitchellh.ghostty $((ALLOWED | TEMPORARY)) com.anthropic.claudefordesktop $ok com.openai.codex $ok com.t3tools.t3code $ok
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Default/Extensions/$CLAUDE_CHROME_EXTENSION_ID"
stub open
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Claude, ChatGPT, and T3 Code. "
assert_not_contains "$RUN_OUTPUT" "Open "
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "ok         Claude, ChatGPT, and T3 Code notifications allowed, with the Persistent style"
assert_contains "$RUN_OUTPUT" "unverified Squash merging allowed in your GitHub repositories: couldn't list your GitHub repositories with gh"
assert_not_contains "$RUN_OUTPUT" "Signed in to Claude Code"

apps com.mitchellh.ghostty $ok com.anthropic.claudefordesktop $((ALLOWED | TEMPORARY)) com.t3tools.t3code $ok
# DOTFILES_ASSUME_YES counts only on a test machine
stub systemd-detect-virt
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Not opening the notification settings: DOTFILES_ASSUME_YES is set."
cp "$STUB_LOG" "$SANDBOX/both.log"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" 'Claude, ChatGPT, and T3 Code. `manual-steps` opens the ones it can tell aren'"'"'t set.'
cat "$STUB_LOG" >> "$SANDBOX/both.log"
assert_eq "" "$(grep -E '^(open|sudo)' "$SANDBOX/both.log" || true)" "commands run without a yes"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Claude, ChatGPT, and T3 Code notifications allowed, with the Persistent style: not yet for com.anthropic.claudefordesktop, com.openai.codex"

answer yes
run main <<< $'\n\n'
assert_eq 0 "$RUN_STATUS" "exit status after opening the settings"
assert_eq "open x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.anthropic.claudefordesktop
open x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.openai.codex" \
    "$(grep '^open' "$STUB_LOG")" "settings opened"

# Settings it can't read leave the step shown and nothing opened
rm "$NCPREFS"
run main < /dev/null
assert_eq 0 "$RUN_STATUS" "exit status when the notification settings can't be read"
assert_contains "$RUN_OUTPUT" 'Claude, ChatGPT, and T3 Code. `manual-steps` opens'
assert_not_contains "$RUN_OUTPUT" "notification settings now?"
assert_eq "" "$(grep '^open' "$STUB_LOG" || true)" "settings opened when they can't be read"
run main --status
assert_contains "$RUN_OUTPUT" "unverified Claude, ChatGPT, and T3 Code notifications allowed, with the Persistent style: $NOTIFICATIONS_UNREADABLE"

# GitHub repositories without squash merging are named
stub gh 'printf "%s\n" me/one me/two'
expect 1 github_squash_merge
assert_eq "off for me/one, me/two" "$MANUAL_DETAIL" "the repositories without squash merging"
stub gh
expect 0 github_squash_merge

# Claude in Chrome needs the extension and claude --chrome's native messaging host
as_os ubuntu
chrome="$HOME/.config/google-chrome"
expect 1 claude_in_chrome
assert_eq "the extension isn't installed in Chrome, and claude --chrome hasn't run" "$MANUAL_DETAIL" "the detail for neither"
mkdir -p "$chrome/Profile 1/Extensions/$CLAUDE_CHROME_EXTENSION_ID" "$chrome/NativeMessagingHosts"
expect 1 claude_in_chrome
touch "$chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json"
expect 0 claude_in_chrome

# T3 Code's sessions show a client paired, but sessions expire, so none can't tell
stub_at "$HOME/.local/bin/t3" '[ "$*" == "auth session list --json" ] && cat "$SANDBOX/sessions.json"'
echo '[{"client":{"os":"macOS","deviceType":"desktop","browser":"Electron"}}]' > "$SANDBOX/sessions.json"
expect 0 t3_mac_paired
expect 2 t3_phone_connected
echo '[{"client":{"os":"iOS","deviceType":"mobile"}}]' > "$SANDBOX/sessions.json"
expect 0 t3_phone_connected
expect 2 t3_mac_paired

# HTTPS certificates show as the tailnet's certificate domains
stub tailscale 'cat "$SANDBOX/ts.json"'
echo '{"BackendState":"Running","CertDomains":null}' > "$SANDBOX/ts.json"
expect 1 tailscale_https_on
echo '{"BackendState":"Running","CertDomains":["desktop.example.ts.net"]}' > "$SANDBOX/ts.json"
expect 0 tailscale_https_on

# On Ubuntu, nothing opens
rm -f "$HOME/.local/bin/t3"
for cmd in dpkg-query bwrap; do
    stub "$cmd" 'exit 1'
done
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Remaining AI tool steps on Ubuntu"
assert_eq "" "$(grep -E '^(open|sudo)' "$STUB_LOG" || true)" "commands run on Ubuntu"
test_done
