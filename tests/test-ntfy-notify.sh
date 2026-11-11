#!/bin/bash
# shellcheck disable=SC2329 # the script calls the functions this test replaces

# The ntfy notifier: notify.sh showing each message once, whatever a reconnect replays, keeping the
# newest message time and at most 1000 IDs, quoting what it shows, replacing the notification of a
# message with the same sequence ID, opening a message's web links on a click and nothing else,
# offering only the actions ntfy/actions.sh lists, and recording macOS refusing it; clicks.sh doing
# only what notify.sh saved for a click on Ubuntu; run-action.sh running an action only after Enter, here or over ssh to the ntfy
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

# --- notify.sh on Linux: GNOME's org.gtk.Notifications through busctl ---
stub_uname Linux
stub busctl '[ ! -e "$SANDBOX/busctl-fails" ] || exit 1'
stub notify-send '[ ! -e "$SANDBOX/notify-fails" ] || exit 1'
ADD="busctl --user call org.gtk.Notifications /org/gtk/Notifications org.gtk.Notifications AddNotification ssa{sv} dotfiles.ntfy"
notify 0 id1 100
assert_file_contains "$STUB_LOG" "$ADD alerts-id1 4 title s Disk body s sda is failing priority s normal default-action s default"
assert_file_not_contains "$STUB_LOG" "notify-send"
# A reconnect replays the cache; a message already shown isn't shown again
notify 0 id1 100
assert_file_not_contains "$STUB_LOG" "busctl"
notify 0 id2 200 "" "" 5
assert_file_contains "$STUB_LOG" "$ADD alerts-id2 4 title s alerts body s alerts priority s urgent"
notify 0 id3 150
assert_eq 200 "$(cat "$STATE/last-time")" "the newest message time, after an older message"
# What a message holds is shown, never run
notify 0 id4 300 '$(touch "$SANDBOX/ran-title")' '`touch "$SANDBOX/ran-message"`'
[ ! -e "$SANDBOX/ran-title" ] && [ ! -e "$SANDBOX/ran-message" ] || fail "a message's text was run"
assert_file_contains "$STUB_LOG" 'title s $(touch "$SANDBOX/ran-title") body s `touch "$SANDBOX/ran-message"`'
# Without GNOME's API, notify-send shows it on its own
touch "$SANDBOX/busctl-fails"
notify 0 id5 400
assert_file_contains "$STUB_LOG" "notify-send --app-name=ntfy --urgency=normal -- Disk sda is failing"
notify 0 id6 401 "" "" 4
assert_file_contains "$STUB_LOG" "notify-send --app-name=ntfy --urgency=critical -- alerts alerts"
# A failed notification still counts as seen, so a replay doesn't retry it forever
touch "$SANDBOX/notify-fails"
notify 1 id7 402
notify 0 id7 402
assert_file_not_contains "$STUB_LOG" "notify-send"
rm "$SANDBOX/notify-fails" "$SANDBOX/busctl-fails"
# At most 1000 IDs, the newest last
seq 1 1005 | sed 's/^/old/' > "$STATE/seen"
notify 0 id8 500
assert_eq 1000 "$(wc -l < "$STATE/seen" | tr -d ' ')" "the seen list's length"
assert_eq id8 "$(tail -n 1 "$STATE/seen")" "the newest seen ID"
# No ID, no notification
assert_exit 0 env -u NTFY_ID "$BASH" "$NOTIFY"
assert_file_not_contains "$STUB_LOG" "busctl"

# A message with a sequence ID replaces the notification of the last one with it, in its topic. One
# with characters a file name or notification ID can't hold is made safe.
RAW='{"sequence_id":"ups-power"}'
notify 0 seq1 510
assert_file_contains "$STUB_LOG" "$ADD alerts-ups-power 4 "
RAW='{"sequence_id":"../a b"}'
notify 0 seq2 511
assert_file_contains "$STUB_LOG" "$ADD alerts-___a_b 4 "
RAW='{"sequence_id":""}'
notify 0 seq3 512
assert_file_contains "$STUB_LOG" "$ADD alerts-seq3 4 "
RAW=""

# A click opens the Click link. View actions with web URLs become buttons, numbered for clicks.sh;
# http actions, which only the Android app runs, and other schemes don't. What a click does goes
# in a file for clicks.sh.
TOPIC=agenda
RAW='{"click":"https://garvitpahal.com/x/agenda/standup","actions":[
    {"action":"view","label":"Notes","url":"https://notes.example.com/1"},
    {"action":"http","label":"Done","url":"https://garvitpahal.com/x/agenda/done"},
    {"action":"view","label":"Passwords","url":"file:///etc/passwd"},
    {"action":"view","label":"Call","url":"https://meet.example.com/2"}]}'
notify 0 link1 700 Standup "In 10 minutes"
assert_file_contains "$STUB_LOG" "$ADD agenda-link1 5 title s Standup body s In 10 minutes priority s normal default-action s default buttons aa{sv} 2 2 label s Notes action s view0 2 label s Call action s view1"
assert_eq "link https://garvitpahal.com/x/agenda/standup
view https://notes.example.com/1
view https://meet.example.com/2" "$(cat "$STATE/clicks/agenda-link1")" "what a click does"
# Without a Click link, a click opens the first view action's URL
RAW='{"actions":[{"action":"view","label":"Notes","url":"https://notes.example.com/1"}]}'
notify 0 link2 701
assert_eq "link https://notes.example.com/1
view https://notes.example.com/1" "$(cat "$STATE/clicks/agenda-link2")" "what a click without a Click link does"
# An agenda message without links opens the agenda; a Click link that isn't on the web is ignored
RAW='{"click":"file:///etc/passwd"}'
notify 0 link3 702
assert_eq "link https://garvitpahal.com/x/agenda" "$(cat "$STATE/clicks/agenda-link3")" "what a click on an agenda message does"
# An alert without a web link or action has nothing to click, and replacing one that had clears it
TOPIC=alerts
RAW='{"click":"https://example.com/disk","sequence_id":"disk"}'
notify 0 link4 703
[ -f "$STATE/clicks/alerts-disk" ] || fail "no click file for a message with a link"
RAW='{"sequence_id":"disk"}'
notify 0 link5 704
[ ! -e "$STATE/clicks/alerts-disk" ] || fail "a replacing message without links left the old one's click"
assert_file_not_contains "$STUB_LOG" "buttons"
# Old click files go, as GNOME no longer shows their notifications
touch -t 202001010000 "$STATE/clicks/agenda-link1"
notify 0 link6 705
[ ! -e "$STATE/clicks/agenda-link1" ] || fail "an old click file stayed"
[ -e "$STATE/clicks/agenda-link2" ] || fail "a recent click file went"
RAW=""

# An action tag gets a button with the action's label, and a click without a link runs it
TAGS="warning,action:linux-disk"
notify 0 act1 800
assert_file_contains "$STUB_LOG" "$ADD alerts-act1 5 title s Disk body s sda is failing priority s normal default-action s default buttons aa{sv} 1 2 label s Show disk health action s action"
assert_eq "action linux-disk" "$(cat "$STATE/clicks/alerts-act1")" "what a click on an alert does"
RAW='{"click":"https://example.com/disk"}'
notify 0 act2 801
assert_eq "link https://example.com/disk
action linux-disk" "$(cat "$STATE/clicks/alerts-act2")" "what a click on an alert with a link does"
RAW=""
# A bare name runs here, so Ubuntu's own disk action is offered bare too; mac- names need a Mac,
# which Ubuntu doesn't know
TAGS="action:status"
notify 0 act3 802
assert_eq "action status" "$(cat "$STATE/clicks/alerts-act3")" "a bare action"
# Names the list doesn't have, or that aren't only letters, digits, and dashes, aren't offered
for tag in 'action:mac-status' 'action:linux-rm' 'action:linux-disk;touch x' 'action:linux--disk' 'action:-x' 'action:'; do
    TAGS="warning,$tag"
    notify 0 "bad-${#tag}" 805
    assert_file_contains "$STUB_LOG" "$ADD alerts-bad-${#tag} 4 "
    [ ! -e "$STATE/clicks/alerts-bad-${#tag}" ] || fail "$tag was offered"
done
TAGS=""

# --- clicks.sh: acts on GNOME's ActionInvoked for notify.sh's notifications ---
cp "$REPO_DIR/ntfy/clicks.sh" "$NOTIFIER/"
CLICKS="$NOTIFIER/clicks.sh"
stub gdbus 'cat "$SANDBOX/signals"'
stub xdg-open
signal() {
    printf "/org/gtk/Notifications: org.gtk.Notifications.ActionInvoked ('%s', '%s', '%s', @av [], {'activation-token': <'x'>})\n" \
        "${3:-dotfiles.ntfy}" "$1" "$2" > "$SANDBOX/signals"
    # It exits when gdbus monitor does, for the unit to restart it
    assert_exit 1 "$BASH" "$CLICKS"
}
signal agenda-link2 default
assert_file_contains "$STUB_LOG" "gdbus monitor --session --dest org.gtk.Notifications"
wait_for opened https://notes.example.com/1 || fail "a click didn't open the link"
signal agenda-link3 default
wait_for opened https://garvitpahal.com/x/agenda || fail "a click on an agenda message didn't open it"
# A button opens its view action's URL
printf '%s\n' "link https://garvitpahal.com/x/agenda/standup" "view https://notes.example.com/1" \
    "view https://meet.example.com/2" > "$STATE/clicks/agenda-link1"
signal agenda-link1 view1
wait_for opened https://meet.example.com/2 || fail "a button didn't open its view action's URL"
# A click without a link runs the action, and with a link, its button does
signal alerts-act1 default
wait_for ran_action linux-disk || fail "a click didn't run the action"
signal alerts-act2 default
wait_for opened https://example.com/disk || fail "a click didn't open the alert's link"
signal alerts-act2 action
wait_for ran_action linux-disk || fail "the button didn't run the action"
signal alerts-act3 action
wait_for ran_action status || fail "the button didn't run a bare action"
# Nothing else runs: another app's notification, an ID that isn't one notify.sh makes, a button past
# the last, an action the list doesn't have, or a notification without a file
echo "action linux-rm" > "$STATE/clicks/alerts-bad"
for click in "alerts-act1 default org.example.Other" "../alerts-act1 default" "agenda-link1 view5" \
    "alerts-bad action" "alerts-none default"; do
    # shellcheck disable=SC2086 # the ID, the choice, and the app
    signal $click
    sleep 0.3
    if grep -qE '^(xdg-open|open-in)' "$STUB_LOG"; then
        fail "a click on $click opened something"
    fi
done

# --- notify.sh on macOS: terminal-notifier, and a refusal recorded for status ---
stub_uname Darwin
stub terminal-notifier 'exit "$(cat "$SANDBOX/tn-exit" 2> /dev/null || echo 0)"'
notify 0 mac1 600 "Standup" "In 10 minutes" 4
assert_file_contains "$STUB_LOG" "terminal-notifier -title Standup -message In 10 minutes -group ntfy-alerts-mac1 -sound default"
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
assert_file_contains "$STUB_LOG" "terminal-notifier -title Standup -message In 10 minutes -group ntfy-alerts-mac5 -open https://garvitpahal.com/x/agenda/standup"
TOPIC=agenda RAW=""
notify 0 mac6 605 Standup "In 10 minutes"
assert_file_contains "$STUB_LOG" "-group ntfy-agenda-mac6 -open https://garvitpahal.com/x/agenda"
TOPIC=alerts
# A click runs the action through sh: a linux- one only once the client config names the desktop
TAGS="warning,action:linux-status"
notify 0 mac7 606
assert_file_not_contains "$STUB_LOG" "-execute"
MAC_CLIENT="$HOME/Library/Application Support/ntfy/client.yml"
mkdir -p "$(dirname "$MAC_CLIENT")"
printf '%s\n' "default-host: https://desktop.example.ts.net:8443" > "$MAC_CLIENT"
notify 0 mac8 607
assert_file_contains "$STUB_LOG" "-group ntfy-alerts-mac8 -execute OPEN_IN_CALLER=ntfy OPEN_IN_LOG='$STATE/action.log' /bin/bash '$NOTIFIER/open-in' run '/bin/bash '\\''$NOTIFIER/run-action.sh'\\'' linux-status' > '$STATE/action.log' 2>&1"
stub terminal-notifier 'for arg; do [ "$prev" != -execute ] || sh -c "$arg"; prev="$arg"; done'
notify 0 mac9 608
ran_action linux-status || fail "the -execute command didn't run the action"
RAW='{"click":"https://example.com/status"}'
notify 0 mac10 609
assert_file_contains "$STUB_LOG" "-open https://example.com/status"
assert_file_not_contains "$STUB_LOG" "-execute"
RAW="" TAGS=""
# A message with a sequence ID replaces the notification in its group
RAW='{"sequence_id":"ups-power"}'
notify 0 mac11 610
assert_file_contains "$STUB_LOG" "-group ntfy-alerts-ups-power"
RAW=""

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
