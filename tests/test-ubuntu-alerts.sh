#!/bin/bash
set -euo pipefail

# The ntfy alerts: smartd's hook, just alerts (ubuntu/setup-alerts.sh), and the ubuntu step's hook
# installs, with the topic kept out of curl's arguments and logs. The hook runs as root and reads
# only installed paths, so a copy points them into the sandbox.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox
# DOTFILES_ASSUME_YES and DOTFILES_SSH_KEY_ONLY count only in a VM
stub systemd-detect-virt
URL_FILE="$SANDBOX/ntfy-url"
HOOK="$SANDBOX/smartd-notify.sh"
ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$HOOK"

stub_ntfy_curl
stub logger

run_hook() {
    : > "$STUB_LOG"
    assert_exit 0 env SMARTD_SUBJECT="SMART error (FailedHealthCheck) detected on host: box" \
        SMARTD_MESSAGE="Device: /dev/sda [SAT], FAILED SMART self-check. BACK UP DATA NOW!" \
        SMARTD_DEVICE=/dev/sda SMARTD_FAILTYPE=FailedHealthCheck "$BASH" "$HOOK"
}

run_hook
assert_file_not_contains "$STUB_LOG" "curl"
assert_file_not_contains "$STUB_LOG" "logger"

# The URL goes to curl on stdin, since any user can read a process's arguments
echo "https://ntfy.sh/secret-topic" > "$URL_FILE"
run_hook
# Root's curl speaks only https (--proto =https)
assert_file_contains "$STUB_LOG" "curl -q -fsS --proto =https --max-time 10 -H Title: SMART error (FailedHealthCheck) detected on host: box -H Priority: urgent -H Tags: warning --data-raw Device: /dev/sda [SAT], FAILED SMART self-check. BACK UP DATA NOW! -K -"
assert_file_contains "$STUB_LOG" 'curl config: url = "https://ntfy.sh/secret-topic"'
if grep '^curl -' "$STUB_LOG" | grep -q secret-topic; then
    fail "curl's arguments name the ntfy topic"
fi

touch "$SANDBOX/curl-fails"
run_hook
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: curl: (6) Could not resolve host: ntfy.sh"
if grep '^logger' "$STUB_LOG" | grep -q secret-topic; then
    fail "the log names the ntfy topic"
fi
rm "$SANDBOX/curl-fails"

printf '%s\n' 'https://ntfy.sh/a"b\c' > "$URL_FILE"
run_hook
assert_file_contains "$STUB_LOG" 'curl config: url = "https://ntfy.sh/a\"b\\c"'
echo "https://ntfy.sh/secret-topic" > "$URL_FILE"

# A message starting with @ must go as text, not a file for curl to read
: > "$STUB_LOG"
assert_exit 0 env SMARTD_MESSAGE=@/etc/passwd "$BASH" "$HOOK"
assert_file_contains "$STUB_LOG" "--data-raw @/etc/passwd -K -"

ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$SANDBOX/no-ntfy.sh" "$HOOK"
run_hook
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: $SANDBOX/no-ntfy.sh is missing"
assert_file_not_contains "$STUB_LOG" "curl"
ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$HOOK"

# --- setup-alerts.sh ---
load_script ubuntu/setup-alerts.sh
as_os ubuntu
NTFY_URL_FILE="$SANDBOX/etc-dotfiles/ntfy-url"
SMARTD_HOOK="$SANDBOX/run.d/50dotfiles-notify"
stub_sudo_exec
# No nut group in a test
replace_fn ntfy_url_group 'id -gn'
TOPIC=my-topic-0123456789abc
URL="https://ntfy.sh/$TOPIC"

# The topic comes on stdin, never as an argument, which any user could read
assert_exit 2 main "$URL"
assert_exit 2 main --test extra
assert_exit 2 main <<< "not a topic"
assert_contains "$RUN_OUTPUT" "Not a ntfy topic name or https topic URL."
assert_not_contains "$RUN_OUTPUT" "not a topic"
assert_exit 2 main <<< "https://ntfy.sh/"
# Empty, and generating one declined
assert_exit 2 main <<< ""
assert_exit 2 main <<< "$(printf 'x%.0s' $(seq 1 65))"
# Anyone who guesses a short topic reads the alerts
for short in my-topic https://ntfy.sh/my-topic "$(printf 'x%.0s' $(seq 1 19))"; do
    assert_exit 2 main <<< "$short"
    assert_contains "$RUN_OUTPUT" "A topic needs 20 to 64 characters, since anyone who knows it can read and send"
done
# The topic is a secret, so never over http
assert_exit 2 main <<< "http://ntfy.sh/$TOPIC"
assert_not_contains "$RUN_OUTPUT" "$TOPIC"
[ ! -e "$NTFY_URL_FILE" ] || fail "an invalid value was saved"

: > "$STUB_LOG"
assert_exit 0 main <<< "$TOPIC"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "bash setup.sh ubuntu installs it"
[ ! -e "$NTFY_URL_FILE" ] || fail "the URL was saved without a yes"
assert_file_not_contains "$STUB_LOG" "curl"

# Only you, nut (the file's group), and root read the URL file
export DOTFILES_ASSUME_YES=1
assert_exit 0 main <<< "  $TOPIC "
assert_contains "$RUN_OUTPUT" "ntfy URL for the disk, UPS, health, and boot alerts ($NTFY_URL_FILE):"
assert_contains "$RUN_OUTPUT" "Sent a test push"
assert_not_contains "$RUN_OUTPUT" "$TOPIC"
assert_eq "$URL" "$(cat "$NTFY_URL_FILE")" "the saved URL"
assert_eq "$(id -un) $(id -gn) 640" "$(owner_group_mode "$NTFY_URL_FILE")" "the URL file's owner, group, and mode"
assert_file_contains "$STUB_LOG" "curl -q -fsS --proto =https --max-time 10"
assert_file_contains "$STUB_LOG" "curl config: url = \"$URL\""

: > "$STUB_LOG"
assert_exit 0 main <<< "$URL"
assert_contains "$RUN_OUTPUT" "Already set"
assert_not_contains "$RUN_OUTPUT" "$TOPIC"
assert_file_not_contains "$STUB_LOG" "curl"
# Saved again when only the mode is wrong
chmod 644 "$NTFY_URL_FILE"
assert_exit 0 main <<< "$URL"
assert_contains "$RUN_OUTPUT" "Saved."
assert_eq "$(id -un) $(id -gn) 640" "$(owner_group_mode "$NTFY_URL_FILE")" "the URL file after saving it again"

touch "$SANDBOX/curl-fails"
assert_exit 1 main <<< "other-$TOPIC"
assert_contains "$RUN_OUTPUT" "The test push failed. Check the topic, then run just alerts test."
assert_eq "https://ntfy.sh/other-$TOPIC" "$(cat "$NTFY_URL_FILE")" "the saved URL"
rm "$SANDBOX/curl-fails"

# Left empty: a random topic, shown as QR codes for the Android app and for iPhone or a browser
stub qrencode 'echo "[QR $3]"'
assert_exit 0 main <<< ""
generated="$(head -n 1 "$NTFY_URL_FILE")"
generated="${generated#https://ntfy.sh/}"
[[ "$generated" =~ ^[0-9a-f]{32}$ ]] || fail "the generated topic isn't 32 hex characters: $generated"

# Point at the sandbox first, so a notifier installed on this machine is never run
UPS_NOTIFY="$SANDBOX/libexec/dotfiles-ups-notify"
assert_exit 1 main --test
assert_contains "$RUN_OUTPUT" "isn't installed"
mkdir -p "$(dirname "$SMARTD_HOOK")"
cp "$HOOK" "$SMARTD_HOOK"
chmod 755 "$SMARTD_HOOK"
: > "$STUB_LOG"
assert_exit 0 main --test
assert_file_contains "$STUB_LOG" "sudo env SMARTD_SUBJECT=Test: SMART warning on"
assert_file_contains "$STUB_LOG" "curl -q -fsS"

stub id '[ "$*" != nut ] || [ -e "'"$SANDBOX"'/nut-user" ]'
assert_exit 0 main --test
assert_contains "$RUN_OUTPUT" "The UPS notifier isn't installed (no UPS set up yet); skipping its test."
mkdir -p "$(dirname "$UPS_NOTIFY")"
printf '%s\n' '#!/bin/bash' 'echo "ups-notify $NOTIFYTYPE $UPSNAME $1" >> "$STUB_LOG"' > "$UPS_NOTIFY"
chmod 755 "$UPS_NOTIFY"
assert_exit 0 main --test
assert_contains "$RUN_OUTPUT" "skipping its test"
touch "$SANDBOX/nut-user"
stub sudo '[ "$1 $2" == "-u nut" ] && shift 2; exec "$@"'
: > "$STUB_LOG"
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
