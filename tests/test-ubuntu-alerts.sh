#!/bin/bash
set -euo pipefail
# os: ubuntu

# smartd's warning hook (ubuntu/smartd-notify.sh) pushes the warning to ntfy when a URL is set,
# through the installed ntfy code it sources, logging what fails and always exiting 0. It runs as
# root, so it reads only the installed paths, and a copy points them into the sandbox. ntfy_push
# sends the message as is, even one starting with @. And ubuntu/setup-alerts.sh, which reads a
# topic or URL without showing it, saves the URL, names the four alerts that go there, and runs the
# hook with a test warning and the UPS notifier, when installed, with a test event. curl, logger,
# sudo, and id are stubs.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
URL_FILE="$SANDBOX/ntfy-url"
HOOK="$SANDBOX/smartd-notify.sh"
ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$HOOK"

# curl logs the config it reads from stdin with -K -, one "curl config:" line each
stub curl 'case " $* " in *" -K - "*) sed "s/^/curl config: /" >> "$STUB_LOG" ;; esac
[ ! -e "'"$SANDBOX"'/curl-fails" ] || { echo "curl: (6) Could not resolve host: ntfy.sh" >&2; exit 6; }'
stub logger

run_hook() {
    : > "$STUB_LOG"
    assert_exit 0 env SMARTD_SUBJECT="SMART error (FailedHealthCheck) detected on host: box" \
        SMARTD_MESSAGE="Device: /dev/sda [SAT], FAILED SMART self-check. BACK UP DATA NOW!" \
        SMARTD_DEVICE=/dev/sda SMARTD_FAILTYPE=FailedHealthCheck "$BASH" "$HOOK"
}

# No URL: nothing to do, and nothing logged
run_hook
assert_file_not_contains "$STUB_LOG" "curl"
assert_file_not_contains "$STUB_LOG" "logger"

# A URL set: it pushes the warning, urgent. The URL goes to curl on stdin, since any user can read
# a process's arguments, and the topic is its secret.
echo "https://ntfy.sh/secret-topic" > "$URL_FILE"
run_hook
assert_file_contains "$STUB_LOG" "curl -fsS --max-time 10 -H Title: SMART error (FailedHealthCheck) detected on host: box -H Priority: urgent -H Tags: warning --data-raw Device: /dev/sda [SAT], FAILED SMART self-check. BACK UP DATA NOW! -K -"
assert_file_contains "$STUB_LOG" 'curl config: url = "https://ntfy.sh/secret-topic"'
if grep '^curl -' "$STUB_LOG" | grep -q secret-topic; then
    fail "curl's arguments name the ntfy topic"
fi

# curl failing: logged without the topic, and the hook still exits 0
touch "$SANDBOX/curl-fails"
run_hook
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: curl: (6) Could not resolve host: ntfy.sh"
if grep '^logger' "$STUB_LOG" | grep -q secret-topic; then
    fail "the log names the ntfy topic"
fi
rm "$SANDBOX/curl-fails"

# Quotes and backslashes in the URL are escaped for curl's config
printf '%s\n' 'https://ntfy.sh/a"b\c' > "$URL_FILE"
run_hook
assert_file_contains "$STUB_LOG" 'curl config: url = "https://ntfy.sh/a\"b\\c"'
echo "https://ntfy.sh/secret-topic" > "$URL_FILE"

# A message starting with @ goes as text, never as a file for curl to read
: > "$STUB_LOG"
assert_exit 0 env SMARTD_MESSAGE=@/etc/passwd "$BASH" "$HOOK"
assert_file_contains "$STUB_LOG" "--data-raw @/etc/passwd -K -"

# Without its ntfy code, it logs that and exits 0
ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$SANDBOX/no-ntfy.sh" "$HOOK"
run_hook
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: $SANDBOX/no-ntfy.sh is missing"
assert_file_not_contains "$STUB_LOG" "curl"
ntfy_hook_copy ubuntu/smartd-notify.sh "$URL_FILE" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$HOOK"

# --- setup-alerts.sh ---
load_script ubuntu/setup-alerts.sh
# shellcheck disable=SC2329 # main calls it
is_ubuntu() { true; }
NTFY_URL_FILE="$SANDBOX/etc-dotfiles/ntfy-url"
SMARTD_HOOK="$SANDBOX/run.d/50dotfiles-notify"
# sudo runs the command, and refuses any path under /etc
stub sudo 'for a in "$@"; do case "$a" in /etc/*) echo "refused: $a" >&2; exit 1 ;; esac; done
exec "$@"'
URL=https://ntfy.sh/my-topic

# The topic or URL comes on stdin, never as an argument, which any user could read
assert_exit 2 main "$URL"
assert_exit 2 main --test extra
assert_exit 2 main <<< "not a topic"
assert_contains "$RUN_OUTPUT" "Not a ntfy topic name or https topic URL."
assert_not_contains "$RUN_OUTPUT" "not a topic"
assert_exit 2 main <<< "https://ntfy.sh/"
assert_exit 2 main <<< ""
assert_exit 2 main <<< "$(printf 'x%.0s' $(seq 1 65))"
# The topic is a secret, so it never goes out unencrypted
assert_exit 2 main <<< "http://ntfy.sh/my-topic"
assert_not_contains "$RUN_OUTPUT" "my-topic"
[ ! -e "$NTFY_URL_FILE" ] || fail "an invalid value was saved"
assert_exit 0 main --help
assert_contains "$RUN_OUTPUT" "Usage: bash ubuntu/setup-alerts.sh [--test] (or: just alerts [test])"
assert_contains "$RUN_OUTPUT" "the UPS's events, the daily health alert, and the boot notice"

# Declined: nothing saved, nothing sent
: > "$STUB_LOG"
assert_exit 0 main <<< my-topic
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "bash setup.sh ubuntu installs it"
[ ! -e "$NTFY_URL_FILE" ] || fail "the URL was saved without a yes"
assert_file_not_contains "$STUB_LOG" "curl"

# Approved: a bare topic, with surrounding spaces, saved as ntfy.sh's URL, readable by every user
# so the health alerts can read it, and a test push sent. The output never shows the topic.
export DOTFILES_ASSUME_YES=1
assert_exit 0 main <<< "  my-topic "
assert_contains "$RUN_OUTPUT" "ntfy URL for the disk, UPS, health, and boot alerts ($NTFY_URL_FILE):"
assert_contains "$RUN_OUTPUT" "Sent a test push"
assert_not_contains "$RUN_OUTPUT" "my-topic"
assert_file_contains "$STUB_LOG" "-H Title: Alerts from $(hostname) -H Tags: white_check_mark --data-raw Disk warnings, UPS events, the daily health alert, and the boot notice from $(hostname) will arrive here."
assert_eq "$URL" "$(cat "$NTFY_URL_FILE")" "the saved URL"
assert_eq 644 "$(file_mode "$NTFY_URL_FILE")" "the URL file's mode"
assert_file_contains "$STUB_LOG" "curl -fsS --max-time 10"
assert_file_contains "$STUB_LOG" "curl config: url = \"$URL\""
if grep '^curl -' "$STUB_LOG" | grep -q my-topic; then
    fail "the test push's curl arguments name the ntfy topic"
fi

# Again, as the full URL: already set, so nothing is written or sent
: > "$STUB_LOG"
assert_exit 0 main <<< "$URL"
assert_contains "$RUN_OUTPUT" "Already set"
assert_not_contains "$RUN_OUTPUT" "my-topic"
assert_file_not_contains "$STUB_LOG" "curl"

# A failed test push fails the script, with the URL saved
touch "$SANDBOX/curl-fails"
assert_exit 1 main <<< other-topic
assert_contains "$RUN_OUTPUT" "The test push failed. Check the topic, then run just alerts test."
assert_eq https://ntfy.sh/other-topic "$(cat "$NTFY_URL_FILE")" "the saved URL"
rm "$SANDBOX/curl-fails"

# --test needs the hook installed, then runs it through sudo with a test warning
assert_exit 1 main --test
assert_contains "$RUN_OUTPUT" "isn't installed"
mkdir -p "$(dirname "$SMARTD_HOOK")"
cp "$HOOK" "$SMARTD_HOOK"
chmod 755 "$SMARTD_HOOK"
: > "$STUB_LOG"
assert_exit 0 main --test
assert_file_contains "$STUB_LOG" "sudo env SMARTD_SUBJECT=Test: SMART warning on"
assert_file_contains "$STUB_LOG" "curl -fsS"

# The UPS notifier: skipped without it or the nut user, else run as nut with a test event.
# id nut succeeds once $SANDBOX/nut-user exists. The notifier logs its environment and argument.
UPS_NOTIFY="$SANDBOX/libexec/dotfiles-ups-notify"
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
assert_contains "$RUN_OUTPUT" "Done. The UPS test shows on your phone if a ntfy URL is set."
assert_contains "$RUN_OUTPUT" "When one doesn't arrive, journalctl -t dotfiles-ups says why."

# Not Ubuntu: nothing to do
# shellcheck disable=SC2329 # main calls it
is_ubuntu() { false; }
assert_exit 0 main <<< "$URL"
assert_contains "$RUN_OUTPUT" "The alerts are Ubuntu only"
test_done
