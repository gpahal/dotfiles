#!/bin/bash

# The ntfy alerts: smartd's hook, just alerts (ubuntu/setup-alerts.sh), and the ubuntu step's hook
# installs, with the URL and the token kept out of curl's arguments and logs, and the token sent
# only to the local server. The hook runs as root and reads only installed paths, so a copy points
# them into the sandbox.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

URL_FILE="$SANDBOX/ntfy-url"
HOOK="$SANDBOX/smartd-notify.sh"
ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$HOOK"

stub_ntfy_curl
stub logger

run_hook() {
    assert_exit 0 env SMARTD_SUBJECT="SMART error (FailedHealthCheck) detected on host: box" \
        SMARTD_MESSAGE="Device: /dev/sda [SAT], FAILED SMART self-check. BACK UP DATA NOW!" \
        SMARTD_DEVICE=/dev/sda SMARTD_FAILTYPE=FailedHealthCheck "$BASH" "$HOOK"
}

# Not set up: no push, and the journal says why
run_hook
assert_file_not_contains "$STUB_LOG" "curl"
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: the alerts aren't set up; run just ntfy-user"

# This machine's server: plain http over loopback, with the URL and token on stdin, since any user
# can read a process's arguments
TOKEN_FILE="$SANDBOX/ntfy-token"
TOKEN=tk_0123456789abcdefghijklmnopqrs
echo "$TOKEN" > "$TOKEN_FILE"
echo "http://127.0.0.1:2586/alerts" > "$URL_FILE"
run_hook
assert_file_contains "$STUB_LOG" "curl -q -fsS --proto =http --max-time 10 -H Title: SMART error (FailedHealthCheck) detected on host: box -H Priority: urgent -H Tags: warning --data-raw Device: /dev/sda [SAT], FAILED SMART self-check. BACK UP DATA NOW! -K -"
assert_file_contains "$STUB_LOG" 'curl config: url = "http://127.0.0.1:2586/alerts"'
assert_file_contains "$STUB_LOG" "curl config: header = \"Authorization: Bearer $TOKEN\""
assert_file_not_contains "$STUB_LOG" "logger"
if grep '^curl -' "$STUB_LOG" | grep -q "$TOKEN"; then
    fail "curl's arguments hold the token"
fi
# The paths.sh copy the step's other scripts read names the same server
assert_eq "$(sed -n 's/^NTFY_LOCAL_URL=//p' "$REPO_DIR/ubuntu/lib/paths.sh")" \
    "$(sed -n 's/^NTFY_PUSH_SERVER=//p' "$REPO_DIR/ubuntu/lib/ntfy.sh")" "the server in paths.sh and lib/ntfy.sh"

touch "$SANDBOX/curl-fails"
run_hook
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: curl: (7) Failed to connect to 127.0.0.1 port 2586"
rm "$SANDBOX/curl-fails"

printf '%s\n' 'http://127.0.0.1:2586/a"b\c' > "$URL_FILE"
run_hook
assert_file_contains "$STUB_LOG" 'curl config: url = "http://127.0.0.1:2586/a\"b\\c"'
echo "http://127.0.0.1:2586/alerts" > "$URL_FILE"

# A message starting with @ must go as text, not a file for curl to read
assert_exit 0 env SMARTD_MESSAGE=@/etc/passwd "$BASH" "$HOOK"
assert_file_contains "$STUB_LOG" "--data-raw @/etc/passwd -K -"

# Anything else, such as an older ntfy.sh topic, is refused without a request, and the journal
# names only the host, since such a topic was its secret
echo "https://ntfy.sh/secret-topic" > "$URL_FILE"
run_hook
assert_file_not_contains "$STUB_LOG" "curl"
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: won't push to ntfy.sh: the alerts only go to this machine's ntfy server; run just alerts"
if grep '^logger' "$STUB_LOG" | grep -q secret-topic; then
    fail "the log names the ntfy topic"
fi
for url in http://127.0.0.1:2586.example.com/alerts http://127.0.0.1:2586@example.com/alerts http://127.0.0.1:80/alerts; do
    echo "$url" > "$URL_FILE"
    run_hook
    assert_file_not_contains "$STUB_LOG" "curl"
done

# No token, no push
echo "http://127.0.0.1:2586/alerts" > "$URL_FILE"
rm "$TOKEN_FILE"
run_hook
assert_file_not_contains "$STUB_LOG" "curl"
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: no token in $TOKEN_FILE, or it can't be read; run just alerts"
echo "$TOKEN" > "$TOKEN_FILE"

ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$SANDBOX/no-ntfy.sh" "$HOOK"
run_hook
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: $SANDBOX/no-ntfy.sh is missing"
assert_file_not_contains "$STUB_LOG" "curl"
ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$HOOK"

# --- setup-alerts.sh ---
load_script ubuntu/setup-alerts.sh
# Before anything runs, so a notifier installed on this machine never is
sandbox_paths ubuntu/setup-alerts.sh 'ubuntu/lib/*.sh' 'ntfy/lib/*.sh'
as_os ubuntu
stub_sudo_exec
stub_ntfy_curl
# No nut group in a test
replace_fn ntfy_url_group 'id -gn'
replace_fn ntfy_public_url 'echo https://box.example.ts.net:8443'
CLIENT="$HOME/.config/ntfy/client.yml"
saved_files() {
    [ -e "$NTFY_URL_FILE" ] || [ -e "$NTFY_TOKEN_FILE" ]
}

assert_exit 2 main extra
assert_exit 2 main --test extra
assert_exit 1 main --test
assert_contains "$RUN_OUTPUT" "The alerts aren't set up, so a test would only fail. Run just ntfy-user first."
assert_file_not_contains "$STUB_LOG" "sudo"

# The server and just ntfy-user's token come first, and nothing changes without them
touch "$SANDBOX/ntfy-down"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run bash setup.sh ntfy first."
rm "$SANDBOX/ntfy-down"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run just ntfy-user first"
assert_file_not_contains "$STUB_LOG" "sudo"
! saved_files || fail "files were saved without a token"
mkdir -p "$(dirname "$CLIENT")"
printf '%s\n' "default-host: http://127.0.0.1:2586" "default-token: $TOKEN" > "$CLIENT"

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "bash setup.sh ubuntu installs it"
! saved_files || fail "the files were saved without a yes"
assert_file_not_contains "$STUB_LOG" "Authorization"

# Only you, nut (the files' group), and root read them. The Android steps give the public URL, port
# included, for the user first and then each topic.
answer yes
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Saved."
assert_contains "$RUN_OUTPUT" "1. In Settings → Manage users, add your user and password for https://box.example.ts.net:8443"
assert_contains "$RUN_OUTPUT" "2. Tap +, enter alerts, tick \"Use another server\", enter https://box.example.ts.net:8443, and tap Subscribe"
assert_contains "$RUN_OUTPUT" "3. Tap +, enter agenda, tick \"Use another server\", enter https://box.example.ts.net:8443, and tap Subscribe"
assert_contains "$RUN_OUTPUT" "Sent a test push"
assert_not_contains "$RUN_OUTPUT" "$TOKEN"
assert_eq "http://127.0.0.1:2586/alerts" "$(cat "$NTFY_URL_FILE")" "the saved URL"
assert_eq "$TOKEN" "$(cat "$NTFY_TOKEN_FILE")" "the saved token"
assert_eq "$(id -un) $(id -gn) 640" "$(owner_group_mode "$NTFY_URL_FILE")" "the URL file's owner, group, and mode"
assert_eq "$(id -un) $(id -gn) 640" "$(owner_group_mode "$NTFY_TOKEN_FILE")" "the token file's owner, group, and mode"
assert_file_contains "$STUB_LOG" "curl -q -fsS --proto =http --max-time 10 -H Title: Alerts from"
assert_file_contains "$STUB_LOG" "curl config: header = \"Authorization: Bearer $TOKEN\""
if grep -vE '^curl config: ' "$STUB_LOG" | grep -q "$TOKEN"; then
    fail "the token was an argument"
fi

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Already sent to http://127.0.0.1:2586/alerts"
assert_file_not_contains "$STUB_LOG" "sudo"
assert_file_not_contains "$STUB_LOG" "Authorization"
# Saved again when only a mode is wrong
chmod 644 "$NTFY_TOKEN_FILE"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Saved."
assert_eq "$(id -un) $(id -gn) 640" "$(owner_group_mode "$NTFY_TOKEN_FILE")" "the token file after saving it again"

# A new token from just ntfy-user --rotate desktop replaces the saved one
TOKEN2=tk_zyxwvutsrqponmlkjihgfedcba987
printf '%s\n' "default-host: http://127.0.0.1:2586" "default-token: $TOKEN2" > "$CLIENT"
touch "$SANDBOX/push-fails"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "The test push failed."
assert_eq "$TOKEN2" "$(cat "$NTFY_TOKEN_FILE")" "the saved token after a rotation"
rm "$SANDBOX/push-fails"

assert_exit 1 main --test
assert_contains "$RUN_OUTPUT" "isn't installed"
mkdir -p "$(dirname "$SMARTD_HOOK")"
cp "$HOOK" "$SMARTD_HOOK"
chmod 755 "$SMARTD_HOOK"
assert_exit 0 main --test
assert_file_contains "$STUB_LOG" "sudo env SMARTD_SUBJECT=Test: SMART warning on"
assert_file_contains "$STUB_LOG" "curl -q -fsS"

stub id '[ "$*" != nut ] || [ -e "$SANDBOX/nut-user" ]'
assert_exit 0 main --test
assert_contains "$RUN_OUTPUT" "The UPS notifier isn't installed (no UPS set up yet); skipping its test."
stub_at "$UPS_NOTIFY" 'echo "ups-notify $NOTIFYTYPE $UPSNAME $1" >> "$STUB_LOG"'
assert_exit 0 main --test
assert_contains "$RUN_OUTPUT" "skipping its test"
touch "$SANDBOX/nut-user"
stub sudo '[ "$1 $2" == "-u nut" ] && shift 2; exec "$@"'
assert_exit 0 main --test
assert_file_contains "$STUB_LOG" "sudo -u nut env NOTIFYTYPE=TEST UPSNAME=test $UPS_NOTIFY Test: a UPS event from $(hostname). The UPS is fine."
assert_file_contains "$STUB_LOG" "ups-notify TEST test Test: a UPS event from $(hostname). The UPS is fine."


# --- the ubuntu step's installs of the hooks ---
# run-parts skips a hook that isn't executable, so modes don't follow the checkout's
load_script ubuntu/install.sh
ubuntu_sandbox_paths
stub_sudo_exec
checkout="$SANDBOX/checkout"
mkdir -p "$checkout"
cp "$REPO_DIR/ubuntu/smartd-notify.sh" "$REPO_DIR/ubuntu/ups-notify.sh" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$checkout"
chmod 644 "$checkout"/*
# shellcheck disable=SC2034 # the step's install functions read them
{
    SMARTD_HOOK_SRC="$checkout/smartd-notify.sh"
    UPS_NOTIFY_SRC="$checkout/ups-notify.sh"
    NTFY_LIB_SRC="$checkout/ntfy.sh"
}
assert_exit 1 smartd_hook_installed
# Each hook goes in only after the ntfy code it sources
rm -f "$SMARTD_HOOK" "$UPS_NOTIFY" "$NTFY_LIB"
mkdir -p "$NTFY_LIB"
assert_exit 1 install_smartd_hook
assert_exit 1 install_ups_notifier
[ ! -e "$SMARTD_HOOK" ] && [ ! -e "$UPS_NOTIFY" ] || fail "a hook went in without the ntfy code"
rmdir "$NTFY_LIB"
assert_exit 0 install_smartd_hook
assert_exit 0 install_ups_notifier
assert_eq 755 "$(file_mode "$SMARTD_HOOK")" "smartd's hook's mode"
assert_eq 755 "$(file_mode "$UPS_NOTIFY")" "the UPS notifier's mode"
assert_eq 644 "$(file_mode "$NTFY_LIB")" "the ntfy code's mode"
assert_exit 0 smartd_hook_installed
assert_exit 0 ups_notifier_installed
chmod 644 "$SMARTD_HOOK"
assert_exit 1 smartd_hook_installed
test_done
