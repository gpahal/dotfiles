#!/bin/bash
# shellcheck disable=SC2329 # the script calls the functions this test replaces

# The ntfy notifier: notify.sh showing each message once, whatever a reconnect replays, keeping the
# newest message time and at most 1000 IDs, quoting what it shows, and recording macOS refusing it;
# subscribe.sh resuming from the newest time; and just ntfy-device (ntfy/setup-device.sh) saving
# the Mac's token at mode 600 only once the server accepts it, read from stdin, never an argument.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &>/dev/null || skip "jq isn't installed"

NOTIFY="$REPO_DIR/ntfy/notify.sh"
SUBSCRIBE="$REPO_DIR/ntfy/subscribe.sh"
STATE="$HOME/.local/state/dotfiles/ntfy"

notify() {
    assert_exit "$1" env NTFY_ID="$2" NTFY_TIME="${3:-100}" NTFY_TOPIC=alerts NTFY_TITLE="${4-Disk}" \
        NTFY_MESSAGE="${5-sda is failing}" NTFY_PRIORITY="${6:-3}" "$BASH" "$NOTIFY"
}

# --- notify.sh on Linux ---
stub_uname Linux
stub notify-send '[ ! -e "$SANDBOX/notify-fails" ] || exit 1'
notify 0 id1 100
assert_file_contains "$STUB_LOG" "notify-send --app-name=ntfy --urgency=normal -- Disk sda is failing"
# A reconnect replays the cache; a message already shown isn't shown again
notify 0 id1 100
assert_file_not_contains "$STUB_LOG" "notify-send"
notify 0 id2 200 "" "" 5
assert_file_contains "$STUB_LOG" "notify-send --app-name=ntfy --urgency=critical -- alerts alerts"
notify 0 id3 150
assert_eq 200 "$(cat "$STATE/last-time")" "the newest message time, after an older message"
# What a message holds is shown, never run
notify 0 id4 300 '$(touch "$SANDBOX/ran-title")' '`touch "$SANDBOX/ran-message"`'
[ ! -e "$SANDBOX/ran-title" ] && [ ! -e "$SANDBOX/ran-message" ] || fail "a message's text was run"
assert_file_contains "$STUB_LOG" 'notify-send --app-name=ntfy --urgency=normal -- $(touch "$SANDBOX/ran-title")'
# A failed notification still counts as seen, so a replay doesn't retry it forever
touch "$SANDBOX/notify-fails"
notify 1 id5 400
notify 0 id5 400
assert_file_not_contains "$STUB_LOG" "notify-send"
rm "$SANDBOX/notify-fails"
# At most 1000 IDs, the newest last
seq 1 1005 | sed 's/^/old/' > "$STATE/seen"
notify 0 id6 500
assert_eq 1000 "$(wc -l < "$STATE/seen" | tr -d ' ')" "the seen list's length"
assert_eq id6 "$(tail -n 1 "$STATE/seen")" "the newest seen ID"
# No ID, no notification
assert_exit 0 env -u NTFY_ID "$BASH" "$NOTIFY"
assert_file_not_contains "$STUB_LOG" "notify-send"

# --- notify.sh on macOS: terminal-notifier, and a refusal recorded for status ---
stub_uname Darwin
stub terminal-notifier 'exit "$(cat "$SANDBOX/tn-exit" 2> /dev/null || echo 0)"'
notify 0 mac1 600 "Standup" "In 10 minutes" 4
assert_file_contains "$STUB_LOG" "terminal-notifier -title Standup -message In 10 minutes -group ntfy-mac1 -sound default"
notify 0 mac2 601
assert_file_not_contains "$STUB_LOG" "-sound"
echo 3 > "$SANDBOX/tn-exit"
notify 3 mac3 602
assert_file_contains "$STATE/notify-error" "macOS doesn't allow terminal-notifier's notifications"
echo 0 > "$SANDBOX/tn-exit"
notify 0 mac4 603
[ ! -e "$STATE/notify-error" ] || fail "a notification that showed left the error"

# --- subscribe.sh ---
stub ntfy
stub sleep
stub_uname Linux
rm -f "$STATE/last-time"
CONFIG="$HOME/.config/ntfy/client.yml"
# It waits for just ntfy-user's config rather than exit, which the unit would restart in a loop
stub sleep "mkdir -p '$(dirname "$CONFIG")' && touch '$CONFIG'"
assert_exit 0 "$BASH" "$SUBSCRIBE"
assert_file_contains "$STUB_LOG" "sleep 60"
assert_file_contains "$STUB_LOG" "ntfy subscribe --config $CONFIG --from-config --since 10m"
echo 1000 > "$STATE/last-time"
assert_exit 0 "$BASH" "$SUBSCRIBE"
assert_file_contains "$STUB_LOG" "ntfy subscribe --config $CONFIG --from-config --since 999"
assert_file_not_contains "$STUB_LOG" "sleep"
stub_uname Darwin
mkdir -p "$HOME/Library/Application Support/ntfy"
touch "$HOME/Library/Application Support/ntfy/client.yml"
assert_exit 0 "$BASH" "$SUBSCRIBE"
assert_file_contains "$STUB_LOG" "ntfy subscribe --config $HOME/Library/Application Support/ntfy/client.yml --from-config --since 999"
rm -rf "$HOME/Library"

# --- setup-device.sh ---
load_script ntfy/setup-device.sh
as_os macos
TOKEN=tk_0123456789abcdefghijklmnopqrs
CLIENT="$HOME/Library/Application Support/ntfy/client.yml"
echo '{"Peer": {"a": {"HostName": "desktop", "DNSName": "desktop.example.ts.net."}, "b": {"HostName": "laptop", "DNSName": "laptop.example.ts.net."}}}' \
    > "$SANDBOX/ts.json"
stub tailscale '[ "$*" != "status --json" ] || cat "$SANDBOX/ts.json"'
echo 200 > "$SANDBOX/http-status"
stub curl 'sed "s/^/curl config: /" >> "$STUB_LOG"; cat "$SANDBOX/http-status"'
stub launchctl '[ "$1" != print ] || [ -e "$SANDBOX/agent-loaded" ]'

assert_exit 1 main <<< "not-a-token"
assert_contains "$RUN_OUTPUT" "That isn't an ntfy token"
echo 401 > "$SANDBOX/http-status"
assert_exit 1 main <<< "$TOKEN"
assert_contains "$RUN_OUTPUT" "answered 401"
[ ! -e "$CLIENT" ] || fail "a token the server rejects was saved"
echo 200 > "$SANDBOX/http-status"
# Saved, so the agent reads it once the ntfy step loads it
assert_exit 1 main <<< "$TOKEN"
assert_contains "$RUN_OUTPUT" "The notifier isn't loaded yet. Run bash setup.sh ntfy."
assert_file_contains "$CLIENT" "default-token: $TOKEN"
# A new token, as after just ntfy-user --rotate macbook, restarts the loaded agent
touch "$SANDBOX/agent-loaded"
TOKEN=tk_zyxwvutsrqponmlkjihgfedcba987
assert_exit 0 main <<< "  $TOKEN "
assert_contains "$RUN_OUTPUT" "ntfy server: https://desktop.example.ts.net:8443"
assert_file_contains "$STUB_LOG" 'curl config: url = "https://desktop.example.ts.net:8443/v1/account"'
assert_file_contains "$STUB_LOG" "launchctl kickstart -k gui/$(id -u)/dotfiles.ntfy-subscribe"
assert_eq 600 "$(file_mode "$CLIENT")" "the client config's mode"
assert_file_contains "$CLIENT" "default-host: https://desktop.example.ts.net:8443"
assert_file_contains "$CLIENT" "default-token: $TOKEN"
assert_file_contains "$CLIENT" "  - topic: https://desktop.example.ts.net:8443/agenda"
if grep -v '^curl config: ' "$STUB_LOG" | grep -q "$TOKEN"; then
    fail "the token was an argument"
fi
assert_exit 0 main <<< "$TOKEN"
assert_contains "$RUN_OUTPUT" "Already saved"
assert_file_not_contains "$STUB_LOG" "kickstart"
# Two machines named desktop: it asks for the full name
echo '{"Peer": {"a": {"HostName": "desktop", "DNSName": "desktop.one.ts.net."}, "b": {"HostName": "Desktop", "DNSName": "desktop.two.ts.net."}}}' \
    > "$SANDBOX/ts.json"
assert_exit 1 main <<< "$TOKEN"
assert_contains "$RUN_OUTPUT" "just ntfy-device desktop.<tailnet>.ts.net"
assert_exit 0 main desktop.two.ts.net <<< "$TOKEN"
assert_file_contains "$CLIENT" "default-host: https://desktop.two.ts.net:8443"
as_os ubuntu
assert_exit 1 main <<< "$TOKEN"
assert_contains "$RUN_OUTPUT" "run just ntfy-user"

test_done
