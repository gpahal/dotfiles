#!/bin/bash

# The macos step's SSH and sleep items: the sshd drop-in that lets in only your key from the
# tailnet, Remote Login, which stays off until the drop-in is in place, and no idle sleep on the
# power adapter. test-macos-security.sh covers the step's other items.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

STATE="$SANDBOX/state"
mkdir -p "$STATE" "$HOME/Screenshots"

# launchctl keeps Remote Login's state as files: enabled, then loaded once bootstrapped.
# print-disabled lists many services after it, as on a Mac, so a reader that stops at the match
# breaks the pipe.
stub launchctl 'state="'"$STATE"'"
case "$1" in
    print-disabled)
        echo "disabled services = {"
        if [ -e "$state/rl-enabled" ]; then
            printf "\t\"com.openssh.sshd\" => enabled\n"
        else
            printf "\t\"com.openssh.sshd\" => disabled\n"
        fi
        for i in $(seq 1 500); do printf "\t\"com.example.service%s\" => disabled\n" "$i"; done
        echo "}"
        ;;
    print) [ "$2" == system/com.openssh.sshd ] && [ -e "$state/rl-loaded" ] ;;
    enable) [ ! -e "$state/rl-enable-fails" ] && touch "$state/rl-enabled" ;;
    bootstrap) [ -e "$state/rl-enabled" ] && touch "$state/rl-loaded" ;;
    *) exit 1 ;;
esac'
# pmset keeps the AC sleep timer in $STATE/ac-sleep, 1 minute until set
stub pmset 'state="'"$STATE"'"
case "$*" in
    "-g custom")
        printf "Battery Power:\n sleep                0\n displaysleep         2\nAC Power:\n sleep                %s\n displaysleep         10\n" \
            "$(cat "$state/ac-sleep" 2> /dev/null || echo 1)"
        ;;
    "-c sleep 0") echo 0 > "$state/ac-sleep" ;;
    *) exit 1 ;;
esac'
stub scutil 'echo Garvits-Mac'
stub_sudo_cacheable

load_script macos/install.sh
as_os macos
sandbox_paths REMOTE_LOGIN_PLIST="$SANDBOX/ssh.plist" macos/install.sh
DROP_IN="$MAC_SSHD_DROP_IN"

# sshd -t fails with $STATE/sshd-error's text, and needs the throwaway host key. sshd -T prints
# $STATE/sshd-T, or else the drop-in's settings as sshd -T does: lower case, and each AllowUsers
# entry on its own line.
stub_at "$MAC_SSHD_BIN" 'state="'"$STATE"'" drop_in="'"$DROP_IN"'"
[ "$2" == -h ] && [ -f "$3" ] || { echo "sshd: no hostkeys available -- exiting."; exit 1; }
case "$1" in
    -t)
        [ ! -e "$state/sshd-error" ] || { cat "$state/sshd-error"; exit 255; }
        ;;
    -T)
        if [ -e "$state/sshd-T" ]; then
            cat "$state/sshd-T"
        else
            awk '"'"'$1 !~ /^#/ { key = tolower($1); if (key == "allowusers") { for (i = 2; i <= NF; i++) print key, $i } else { $1 = key; print } }'"'"' "$drop_in"
        fi
        ;;
esac'

# Only these items: the rest of the step is set
replace_fn each_default
replace_fn hotkey_off 'return 0'
replace_fn status_filevault
for check in hostname_valid firewall_on stealth_mode_on app_store_auto_updates; do
    replace_fn "$check" 'return 0'
done

assert_read_only 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $DROP_IN lets only your key in, only from the tailnet"
assert_contains "$RUN_OUTPUT" "missing    Remote Login on"
assert_contains "$RUN_OUTPUT" "missing    No idle sleep on the power adapter"

# A no changes nothing
answer no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged."
[ ! -e "$DROP_IN" ] || fail "a declined confirm wrote $DROP_IN"
assert_file_not_contains "$STUB_LOG" "launchctl enable"
assert_file_not_contains "$STUB_LOG" "pmset -c"

# One yes writes the drop-in, then turns on Remote Login, and stops idle sleep on power
answer yes
assert_idempotent main
assert_contains "$FIRST_OUTPUT" "Wrote $DROP_IN"
assert_contains "$FIRST_OUTPUT" "Turned on Remote Login"
assert_contains "$FIRST_OUTPUT" "Turned off idle sleep on the power adapter"
assert_contains "$FIRST_LOG" "launchctl bootstrap system $SANDBOX/ssh.plist"
assert_file_contains "$DROP_IN" "PasswordAuthentication no"
assert_file_contains "$DROP_IN" "KbdInteractiveAuthentication no"
assert_file_contains "$DROP_IN" "AuthenticationMethods publickey"
assert_file_contains "$DROP_IN" "AllowUsers $CURRENT_USER@100.64.0.0/10 $CURRENT_USER@fd7a:115c:a1e0::/48"
assert_eq 644 "$(file_mode "$DROP_IN")" "the drop-in's mode"
assert_eq 0 "$(cat "$STATE/ac-sleep")" "the AC sleep timer"

# The effective settings need sudo -n
assert_read_only 0 main --status
assert_contains "$RUN_OUTPUT" "ok         $DROP_IN lets only your key in"
assert_contains "$RUN_OUTPUT" "unverified sshd's effective settings match $DROP_IN"
assert_contains "$RUN_OUTPUT" "ok         Remote Login on"
assert_contains "$RUN_OUTPUT" "ok         No idle sleep on the power adapter"
cache_sudo yes
assert_read_only 0 main --status
assert_contains "$RUN_OUTPUT" "ok         sshd's effective settings match $DROP_IN"

# Another file that sets a setting first is reported
awk '$1 !~ /^#/ { key = tolower($1); if (key == "allowusers") { for (i = 2; i <= NF; i++) print key, $i } else { $1 = key; print } }' "$DROP_IN" |
    sed 's/^passwordauthentication no$/passwordauthentication yes/' > "$STATE/sshd-T"
assert_read_only 3 main --status
assert_contains "$RUN_OUTPUT" "missing    sshd's effective settings match $DROP_IN (PasswordAuthentication is yes;"
rm "$STATE/sshd-T"
cache_sudo no

# Only AC sleep counts, not battery's
echo 1 > "$STATE/ac-sleep"
ac_sleep_off && fail "AC sleep read as off from the battery's timer"
echo 0 > "$STATE/ac-sleep"

# Remote Login turned off again is turned back on, and the drop-in left alone
rm "$STATE/rl-enabled" "$STATE/rl-loaded"
snapshot "$DROP_IN"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turned on Remote Login"
assert_unchanged "$DROP_IN" "when only Remote Login was off"

# A changed drop-in is rewritten
echo "PasswordAuthentication yes" > "$DROP_IN"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $DROP_IN lets only your key in"
assert_exit 0 main
assert_file_contains "$DROP_IN" "PasswordAuthentication no"
assert_file_not_contains "$DROP_IN" "PasswordAuthentication yes"

# A broken config elsewhere leaves the drop-in and Remote Login alone, and fails the step after it
# turns off sleep on power
reset_machine() {
    rm -f "$DROP_IN" "$STATE"/rl-* "$STATE/ac-sleep" "$STATE/sshd-error"
}
reset_machine
echo "/etc/ssh/sshd_config line 3: Bad configuration option: Nope" > "$STATE/sshd-error"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sshd's config already fails sshd -t, in /etc/ssh/sshd_config"
assert_contains "$RUN_OUTPUT" "Remote Login stays off until $DROP_IN is in place"
[ ! -e "$DROP_IN" ] || fail "a broken sshd_config still got $DROP_IN"
assert_file_not_contains "$STUB_LOG" "launchctl enable"
assert_eq 0 "$(cat "$STATE/ac-sleep")" "the AC sleep timer after an sshd failure"

# A drop-in sshd rejects is removed again, and Remote Login stays off
reset_machine
wrap_fn write_root_file 'real_write_root_file "$@" &&
echo "$MAC_SSHD_DROP_IN line 2: Bad configuration option: Nope" > "$STATE/sshd-error"'
assert_exit 1 main
restore_fn write_root_file
assert_contains "$RUN_OUTPUT" "sshd -t failed with the new $DROP_IN, so the old state is back."
[ ! -e "$DROP_IN" ] || fail "the drop-in sshd rejected is still in place"
assert_file_not_contains "$STUB_LOG" "launchctl enable"

# A missing sshd fails before any sshd change
reset_machine
rm "$MAC_SSHD_BIN"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$MAC_SSHD_BIN is missing, so $DROP_IN was left as it is."
[ ! -e "$DROP_IN" ] || fail "a missing sshd still got $DROP_IN"
assert_file_not_contains "$STUB_LOG" "launchctl enable"

# launchctl failing points to System Settings
reset_machine
stub_at "$MAC_SSHD_BIN" '[ "$2" == -h ] && [ -f "$3" ]'
touch "$STATE/rl-enable-fails"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't enable Remote Login's launchd job. Turn it on in System Settings"
test_done
