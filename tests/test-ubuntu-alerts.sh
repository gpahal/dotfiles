#!/bin/bash
set -euo pipefail

# smartd's warning hook (ubuntu/smartd-notify.sh) pushes the warning to ntfy when a URL is set,
# through the installed ntfy code it sources, logging what fails and always exiting 0. And ubuntu/setup-alerts.sh, which saves the URL, names
# the four alerts that go there, and runs the hook with a test warning and the UPS notifier, when
# installed, with a test event. curl, logger, sudo, and id are stubs.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
HOOK="$REPO_DIR/ubuntu/smartd-notify.sh"
export DOTFILES_NTFY_URL_FILE="$SANDBOX/ntfy-url" DOTFILES_NTFY_LIB="$REPO_DIR/ubuntu/lib/ntfy.sh"

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
echo "https://ntfy.sh/secret-topic" > "$DOTFILES_NTFY_URL_FILE"
run_hook
assert_file_contains "$STUB_LOG" "curl -fsS --max-time 10 -H Title: SMART error (FailedHealthCheck) detected on host: box -H Priority: urgent -H Tags: warning --data-binary Device: /dev/sda [SAT], FAILED SMART self-check. BACK UP DATA NOW! -K -"
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
printf '%s\n' 'https://ntfy.sh/a"b\c' > "$DOTFILES_NTFY_URL_FILE"
run_hook
assert_file_contains "$STUB_LOG" 'curl config: url = "https://ntfy.sh/a\"b\\c"'

# Without its ntfy code, it logs that and exits 0
DOTFILES_NTFY_LIB="$SANDBOX/no-ntfy.sh" run_hook
assert_file_contains "$STUB_LOG" "logger -t dotfiles-smartd -- couldn't push the warning to ntfy: $SANDBOX/no-ntfy.sh is missing"
assert_file_not_contains "$STUB_LOG" "curl"

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

assert_exit 2 main
assert_exit 2 main not-a-url
assert_contains "$RUN_OUTPUT" "Not an https ntfy topic URL"
assert_exit 2 main https://ntfy.sh/
# The topic is a secret, so it never goes out unencrypted
assert_exit 2 main http://ntfy.sh/my-topic
assert_exit 0 main --help
assert_contains "$RUN_OUTPUT" "Usage: bash ubuntu/setup-alerts.sh <ntfy-url> | --test (or: just alerts <ntfy-url> | test)"
assert_contains "$RUN_OUTPUT" "smartd's disk warnings, the UPS's events, the daily health alert, and the boot notice"

# Declined: nothing saved, nothing sent
: > "$STUB_LOG"
assert_exit 0 main "$URL"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "bash setup.sh ubuntu installs it"
[ ! -e "$NTFY_URL_FILE" ] || fail "the URL was saved without a yes"
assert_file_not_contains "$STUB_LOG" "curl"

# Approved: saved, readable by every user so the health alerts can read it, and a test push sent
export DOTFILES_ASSUME_YES=1
assert_exit 0 main "$URL"
assert_contains "$RUN_OUTPUT" "ntfy URL for the disk, UPS, health, and boot alerts ($NTFY_URL_FILE):"
assert_contains "$RUN_OUTPUT" "Sent a test push"
assert_file_contains "$STUB_LOG" "-H Title: Alerts from $(hostname) -H Tags: white_check_mark --data-binary Disk warnings, UPS events, the daily health alert, and the boot notice from $(hostname) will arrive here."
assert_eq "$URL" "$(cat "$NTFY_URL_FILE")" "the saved URL"
assert_eq 644 "$(file_mode "$NTFY_URL_FILE")" "the URL file's mode"
assert_file_contains "$STUB_LOG" "curl -fsS --max-time 10"
assert_file_contains "$STUB_LOG" "curl config: url = \"$URL\""
if grep '^curl -' "$STUB_LOG" | grep -q my-topic; then
    fail "the test push's curl arguments name the ntfy topic"
fi

# Again: already set, so nothing is written or sent
: > "$STUB_LOG"
assert_exit 0 main "$URL"
assert_contains "$RUN_OUTPUT" "Already set"
assert_file_not_contains "$STUB_LOG" "curl"

# A failed test push fails the script, with the URL saved
touch "$SANDBOX/curl-fails"
assert_exit 1 main https://ntfy.sh/other-topic
assert_contains "$RUN_OUTPUT" "The test push failed. Check the URL, then run just alerts test."
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
assert_exit 0 main "$URL"
assert_contains "$RUN_OUTPUT" "The alerts are Ubuntu only"
test_done
