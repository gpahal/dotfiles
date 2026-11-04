#!/bin/bash
# shellcheck disable=SC2329 # the script calls the functions this test replaces

# The ntfy notifier: notify.sh showing each message once, whatever a reconnect replays, keeping the
# newest message time and at most 1000 IDs, quoting what it shows, opening a message's web links
# on a click and nothing else, offering only the actions ntfy/actions.sh lists, and recording macOS
# refusing it; run-action.sh running an action only after Enter, here or over ssh to the ntfy
# server's host; subscribe.sh resuming from the newest time; and just ntfy-device (ntfy/setup-device.sh) saving
# the Mac's token at mode 600 only once the server accepts it, read from stdin, never an argument.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &>/dev/null || skip "jq isn't installed"

# Copied with open-in beside it, as the ntfy step installs them
NOTIFIER="$SANDBOX/notifier"
mkdir -p "$NOTIFIER"
cp "$REPO_DIR/ntfy/notify.sh" "$REPO_DIR/ntfy/actions.sh" "$REPO_DIR/ntfy/run-action.sh" "$NOTIFIER/"
stub_at "$NOTIFIER/open-in"
NOTIFY="$NOTIFIER/notify.sh"
RUN_ACTION="$NOTIFIER/run-action.sh"
SUBSCRIBE="$REPO_DIR/ntfy/subscribe.sh"
STATE="$HOME/.local/state/dotfiles/ntfy"

# TOPIC, TAGS, and RAW, the message's JSON, default to an alert without links or actions
TOPIC=alerts
TAGS=""
RAW=""
notify() {
    assert_exit "$1" env NTFY_ID="$2" NTFY_TIME="${3:-100}" NTFY_TOPIC="$TOPIC" NTFY_TITLE="${4-Disk}" \
        NTFY_MESSAGE="${5-sda is failing}" NTFY_PRIORITY="${6:-3}" NTFY_TAGS="$TAGS" NTFY_RAW="$RAW" \
        "$BASH" "$NOTIFY"
}

opened() {
    grep -qxF "xdg-open $1" "$STUB_LOG"
}

# The tab open-in opens runs run-action.sh with the action's name, and nothing from the message
ran_action() {
    grep -qxF "open-in run /bin/bash '$NOTIFIER/run-action.sh' $1" "$STUB_LOG"
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

# A click opens the Click link. View actions with web URLs become buttons, numbered as notify-send
# prints the one clicked; http actions, which only the Android app runs, and other schemes don't.
stub notify-send 'cat "$SANDBOX/clicked"'
stub xdg-open
TOPIC=agenda
RAW='{"click":"https://garvitpahal.com/x/agenda/standup","actions":[
    {"action":"view","label":"Notes","url":"https://notes.example.com/1"},
    {"action":"http","label":"Done","url":"https://garvitpahal.com/x/agenda/done"},
    {"action":"view","label":"Passwords","url":"file:///etc/passwd"},
    {"action":"view","label":"Call","url":"https://meet.example.com/2"}]}'
echo default > "$SANDBOX/clicked"
notify 0 link1 700 Standup "In 10 minutes"
wait_for opened https://garvitpahal.com/x/agenda/standup || fail "a click didn't open the Click link"
assert_file_contains "$STUB_LOG" "notify-send --app-name=ntfy --urgency=normal --wait --action=default=Open --action=0=Notes --action=1=Call -- Standup In 10 minutes"
echo 1 > "$SANDBOX/clicked"
notify 0 link2 701 Standup "In 10 minutes"
wait_for opened https://meet.example.com/2 || fail "a button didn't open its view action's URL"
# Without a Click link, a click opens the first view action's URL
RAW='{"actions":[{"action":"view","label":"Notes","url":"https://notes.example.com/1"}]}'
echo default > "$SANDBOX/clicked"
notify 0 link3 702
wait_for opened https://notes.example.com/1 || fail "a click didn't open the first view action's URL"
# An agenda message without links opens the agenda; a Click link that isn't on the web is ignored
RAW='{"click":"file:///etc/passwd"}'
notify 0 link4 703
wait_for opened https://garvitpahal.com/x/agenda || fail "a click on an agenda message didn't open the agenda"
# An alert without a web link shows, as before, without waiting for a click
TOPIC=alerts
notify 0 link5 704
assert_file_contains "$STUB_LOG" "notify-send --app-name=ntfy --urgency=normal -- Disk sda is failing"
RAW=""

# An action tag gets a button with the action's label, and a click without a link runs it
TAGS="warning,action:linux-disk"
echo default > "$SANDBOX/clicked"
notify 0 act1 800
wait_for ran_action linux-disk || fail "a click didn't run the action"
assert_file_contains "$STUB_LOG" "notify-send --app-name=ntfy --urgency=normal --wait --action=default=Open --action=action=Show disk health -- Disk sda is failing"
# With a link too, a click opens the link and the button runs the action
RAW='{"click":"https://example.com/disk"}'
notify 0 act2 801
wait_for opened https://example.com/disk || fail "a click didn't open the link"
echo action > "$SANDBOX/clicked"
notify 0 act3 802
wait_for ran_action linux-disk || fail "the button didn't run the action"
RAW=""
# A bare name runs here, so Ubuntu's own disk action is offered bare too; mac- names need a Mac,
# which Ubuntu doesn't know
TAGS="action:status"
notify 0 act4 803
wait_for ran_action status || fail "the button didn't run a bare action"
TAGS="action:disk"
notify 0 act5 804
wait_for ran_action disk || fail "the button didn't run Ubuntu's bare disk action"
# Names the list doesn't have, or that aren't only letters, digits, and dashes, aren't offered
for tag in 'action:mac-status' 'action:linux-rm' 'action:linux-disk;touch x' 'action:linux--disk' 'action:-x' 'action:'; do
    TAGS="warning,$tag"
    notify 0 "bad-$tag" 805
    assert_file_contains "$STUB_LOG" "notify-send --app-name=ntfy --urgency=normal -- Disk sda is failing"
done
TAGS=""

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
# A click opens the message's link; terminal-notifier has no buttons for the rest
RAW='{"click":"https://garvitpahal.com/x/agenda/standup","actions":[{"action":"view","label":"Notes","url":"https://notes.example.com/1"}]}'
notify 0 mac5 604 Standup "In 10 minutes"
assert_file_contains "$STUB_LOG" "terminal-notifier -title Standup -message In 10 minutes -group ntfy-mac5 -open https://garvitpahal.com/x/agenda/standup"
TOPIC=agenda RAW=""
notify 0 mac6 605 Standup "In 10 minutes"
assert_file_contains "$STUB_LOG" "-group ntfy-mac6 -open https://garvitpahal.com/x/agenda"
TOPIC=alerts
# A click runs the action through sh: a linux- one only once the client config names the desktop
TAGS="warning,action:linux-status"
notify 0 mac7 606
assert_file_not_contains "$STUB_LOG" "-execute"
MAC_CLIENT="$HOME/Library/Application Support/ntfy/client.yml"
mkdir -p "$(dirname "$MAC_CLIENT")"
printf '%s\n' "default-host: https://desktop.example.ts.net:8443" > "$MAC_CLIENT"
notify 0 mac8 607
assert_file_contains "$STUB_LOG" "-group ntfy-mac8 -execute OPEN_IN_CALLER=ntfy OPEN_IN_LOG='$STATE/action.log' /bin/bash '$NOTIFIER/open-in' run '/bin/bash '\\''$NOTIFIER/run-action.sh'\\'' linux-status' > '$STATE/action.log' 2>&1"
stub terminal-notifier 'for arg; do [ "$prev" != -execute ] || sh -c "$arg"; prev="$arg"; done'
notify 0 mac9 608
ran_action linux-status || fail "the -execute command didn't run the action"
RAW='{"click":"https://example.com/status"}'
notify 0 mac10 609
assert_file_contains "$STUB_LOG" "-open https://example.com/status"
assert_file_not_contains "$STUB_LOG" "-execute"
RAW="" TAGS=""

# --- run-action.sh: shows the command, and runs it only after Enter ---
stub fakesh
export SHELL="$STUB_DIR/fakesh"
assert_exit 1 "$BASH" "$RUN_ACTION" linux-disk < /dev/null
assert_file_not_contains "$STUB_LOG" "fakesh"
assert_exit 0 "$BASH" "$RUN_ACTION" linux-status <<< ""
assert_contains "$RUN_OUTPUT" "Show status, on desktop.example.ts.net:"
assert_file_contains "$STUB_LOG" "fakesh -c ssh -t desktop.example.ts.net 'cd \"\$(cat ~/.local/state/dotfiles/checkout)\" && sudo -v && just status'"
assert_exit 0 "$BASH" "$RUN_ACTION" status <<< ""
assert_contains "$RUN_OUTPUT" "Show status, on this computer:"
assert_file_contains "$STUB_LOG" "fakesh -c cd \"\$(cat ~/.local/state/dotfiles/checkout)\" && sudo -v && just status"
# A disk action is Ubuntu's alone, so the Mac has no bare one
assert_exit 1 "$BASH" "$RUN_ACTION" disk <<< ""
assert_contains "$RUN_OUTPUT" "disk isn't an action this computer can run"
rm -rf "$HOME/Library"
assert_exit 1 "$BASH" "$RUN_ACTION" linux-status <<< ""
stub_uname Linux
assert_exit 0 "$BASH" "$RUN_ACTION" linux-disk <<< ""
assert_contains "$RUN_OUTPUT" "Show disk health, on this computer:"
assert_file_contains "$STUB_LOG" "fakesh -c journalctl -t smartd -n 30 --no-pager;"
for action in mac-status 'linux-disk; touch x' nope ''; do
    assert_exit 1 "$BASH" "$RUN_ACTION" "$action" <<< ""
    assert_file_not_contains "$STUB_LOG" "fakesh"
done
unset SHELL

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
