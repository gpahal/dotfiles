#!/bin/bash

# The ubuntu step's ufw firewall: sudo-free checks, its rules, and SSH sessions that keep it off.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
ubuntu_step_set_up
unset DOTFILES_ASSUME_YES
restore_fn ufw_enabled
ufw_on() { echo ENABLED=yes > "$UFW_CONF"; }
ufw_off() { echo ENABLED=no > "$UFW_CONF"; }
ufw_defaults() { printf '%s\n' 'DEFAULT_INPUT_POLICY="DROP"' "IPV6=$1" > "$UFW_DEFAULTS"; }
ufw_defaults yes
# Linger stands in for the step's other changes
replace_fn lingering '[ -e "$SANDBOX/linger" ]'
touch "$SANDBOX/linger"

# --- SSH sessions, from ss and logind, not SSH_CONNECTION ---
# ip route get: a gateway for outside, tailscale0 for the tailnet, wg0 (a VPN) for link-local
stub ss 'port="${4##*:}"
[ ! -e "$SANDBOX/ss-fails" ] || exit 1
cat "$SANDBOX/ss-${port% )}" 2> /dev/null || true'
stub ip 'case "$1 $2" in
    "route get") case "$3" in
        203.* | 198.* | 2001:db8:9*) echo "$3 via 192.168.1.1 dev eth0 src 192.168.1.5" ;;
        100.64.* | fd7a:115c:a1e0:*) echo "$3 dev tailscale0 table 52 src 100.64.0.1" ;;
        fe80:*) echo "$3 dev wg0 proto kernel src fe80::1 metric 256 pref medium" ;;
        *) echo "$3 dev eth0 src 192.168.1.5" ;;
    esac ;;
esac'
# One logind session per address in $SANDBOX/logins
stub loginctl 'case "$1" in
    list-sessions)
        [ ! -e "$SANDBOX/logind-fails" ] || exit 1
        awk "{ print NR, 1000, \"me\", \"-\", 100 + NR, \"user\", \"pts/\" NR, \"no\", \"-\" }" "$SANDBOX/logins" 2> /dev/null || true ;;
    show-session) sed -n "$2p" "$SANDBOX/logins" ;;
    *) touch "$SANDBOX/linger" ;;
esac'
rules_present() {
    ufw_status_listing > "$SANDBOX/ufw-status"
}
rules_missing() {
    { ufw_header; echo "Anywhere on tailscale0     ALLOW       Anywhere"; } > "$SANDBOX/ufw-status"
}

# Nothing else pending, credentials not cached: no prompt, only a hint
rules_present
cache_sudo no
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_not_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "run sudo -v and re-run this step to check them"
assert_sudo_noninteractive "the step"
# Without openssh-server there are no SSH ports to check the rules against, so sudo can't help
stub dpkg-query '[ "${!#}" != openssh-server ] && echo "install ok installed"'
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "openssh-server isn't installed"
assert_not_contains "$RUN_OUTPUT" "sudo -v"
assert_sudo_noninteractive
stub dpkg-query 'echo "install ok installed"'

# Credentials cached: rules checked up front
cache_sudo yes
rules_present
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
assert_not_contains "$RUN_OUTPUT" "sudo -v"
assert_sudo_noninteractive "the step"

# Something else pending and approved, credentials not cached: rules checked after the confirm
cache_sudo no
export DOTFILES_ASSUME_YES=1
rm -f "$SANDBOX/linger"
rules_present
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "loginctl enable-linger"
assert_file_contains "$STUB_LOG" "sudo ufw status"
assert_file_not_contains "$STUB_LOG" "ufw --force enable"

rm -f "$SANDBOX/linger"
rules_missing
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo ufw allow from 10.0.0.0/8 to any port 22 proto tcp"

# Hand-added rules don't fail the check and aren't deleted
cache_sudo yes
rules_present
printf '%s\n' "80/tcp                     ALLOW       Anywhere" >> "$SANDBOX/ufw-status"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         ufw rules allowing SSH from the private ranges"
assert_contains "$RUN_OUTPUT" "ok         ufw filters IPv6"
# IPV6=no leaves sshd open over global IPv6: the step fails before changing ufw
ufw_defaults no
rules_missing
export DOTFILES_ASSUME_YES=1
for state in on off; do
    "ufw_$state"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    ufw filters IPv6"
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "ufw doesn't filter IPv6"
    if grep '^sudo ufw' "$STUB_LOG" | grep -qv '^sudo ufw status'; then
        fail "the step changed ufw with IPV6=no ($state):"
        _show "$(grep '^sudo ufw' "$STUB_LOG")"
    fi
    assert_file_contains "$UFW_DEFAULTS" IPV6=no
done
ufw_on
ufw_defaults yes

# Missing Docker bridge deny rules go on top, ahead of the allow rules, or containers reach sshd
{ ufw_header; ufw_range_rules; ufw_tailscale_rules; } > "$SANDBOX/ufw-status"
assert_exit 1 ufw_configured -n
assert_exit 0 ufw_missing_rules -n
assert_contains "$RUN_OUTPUT" "22/tcp on docker0 DENY Anywhere"
assert_contains "$RUN_OUTPUT" "22/tcp (v6) on br-+ DENY Anywhere (v6)"
assert_not_contains "$RUN_OUTPUT" "ALLOW"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo ufw prepend deny in on docker0 to any port 22 proto tcp"
assert_file_contains "$STUB_LOG" "sudo ufw prepend deny in on br-+ to any port 22 proto tcp"
assert_exit 0 ufw_configured -n
# `ufw status` lists IPv6 rules after all IPv4 ones
{ ufw_header; ufw_deny_rules | grep -v v6; ufw_range_rules | grep -v :; ufw_deny_rules | grep v6; ufw_range_rules | grep :; } > "$SANDBOX/ufw-status"
ufw_tailscale_rules >> "$SANDBOX/ufw-status"
assert_exit 0 ufw_configured -n
# Adding a missing allow rule leaves the deny rules where they are
rules_present
grep -v "41641/udp" "$SANDBOX/ufw-status" > "$SANDBOX/ufw-status.new"
mv "$SANDBOX/ufw-status.new" "$SANDBOX/ufw-status"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo ufw allow 41641/udp"
assert_eq "$(ufw_status_listing)" "$(cat "$SANDBOX/ufw-status")" "the rules after adding the missing one"
unset DOTFILES_ASSUME_YES
rules_present

sessions() {
    local port="$1"
    shift
    printf '0 0 %s %s\n' "$@" > "$SANDBOX/ss-$port"
}
logins() { printf '%s\n' "$@" > "$SANDBOX/logins"; }
no_sessions() { rm -f "$SANDBOX"/ss-[0-9]* "$SANDBOX/logins"; }
# configure_ufw alone, since main's other changes don't depend on it
firewall_run() {
    ufw_off
    run configure_ufw
}
firewall_unchanged() {
    assert_file_not_contains "$STUB_LOG" "ufw --force enable"
    assert_file_not_contains "$STUB_LOG" "ufw default deny"
    assert_file_not_contains "$STUB_LOG" "ufw allow"
}
export DOTFILES_ASSUME_YES=1
cache_sudo yes
rules_present

# Console run: ufw goes on, and ss runs without sudo
no_sessions
firewall_run
assert_eq 0 "$RUN_STATUS" "the step from the console"
assert_file_contains "$STUB_LOG" "ss -Htn state established ( sport = :22 )"
assert_file_not_contains "$STUB_LOG" "sudo ss "
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# ufw.service stopped or disabled, or ufw stopped by ufw-init stop while files and unit say on
for broken in units/ufw.service.inactive units/ufw.service.disabled ufw-stopped; do
    touch "$SANDBOX/$broken"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    ufw on, denying incoming connections"
    assert_exit 0 main
    [ ! -e "$SANDBOX/$broken" ] || fail "the step left $broken"
    assert_exit 0 main --status
done

# An outside session leaves the firewall unchanged, a stale tmux SSH_CONNECTION doesn't count, and
# an outside connection without a logind login (a scanner) doesn't count. test-ufw-helpers.sh
# covers which addresses count as outside.
sessions 22 192.168.1.5:22 192.168.1.20:51000 192.168.1.5:22 203.0.113.9:51000 192.168.1.5:22 198.51.100.8:51001
logins 192.168.1.20 203.0.113.9
rm -f "$SANDBOX/linger"
export TMUX=/tmp/tmux-1000/default,1,0 SSH_CONNECTION="192.168.1.20 51000 192.168.1.5 22"
firewall_run
unset TMUX SSH_CONNECTION
assert_eq 1 "$RUN_STATUS" "the step with a session from outside"
assert_contains "$RUN_OUTPUT" "203.0.113.9"
assert_not_contains "$RUN_OUTPUT" "198.51.100.8"
firewall_unchanged

# A session on ssh.socket's second port counts too
printf '%s\n' 22 2222 > "$SANDBOX/socket-ports"
sessions 22 192.168.1.5:22 192.168.1.20:51000
sessions 2222 '[::ffff:192.168.1.5]:2222' '[::ffff:198.51.100.7]:50000'
logins 198.51.100.7
firewall_run
assert_eq 1 "$RUN_STATUS" "the step with a session from outside on port 2222"
assert_file_contains "$STUB_LOG" "ss -Htn state established ( sport = :2222 )"
assert_contains "$RUN_OUTPUT" "198.51.100.7"
firewall_unchanged
rm "$SANDBOX/socket-ports" "$SANDBOX/ss-2222"

# logind failing or naming a host (UseDNS yes): every outside connection counts
sessions 22 192.168.1.5:22 203.0.113.9:51000
for case in logind-fails client.example.net; do
    logins "${case/logind-fails/192.168.1.20}"
    [ "$case" != logind-fails ] || touch "$SANDBOX/logind-fails"
    firewall_run
    rm -f "$SANDBOX/logind-fails"
    assert_eq 1 "$RUN_STATUS" "the step with logind's sessions: $case"
    assert_contains "$RUN_OUTPUT" "203.0.113.9"
    firewall_unchanged
done

# With ufw on, an outside session doesn't block adding allow rules, which can't cut anyone off
ufw_on
sessions 22 192.168.1.5:22 203.0.113.9:51000
logins 203.0.113.9
rules_missing
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo ufw allow from 10.0.0.0/8 to any port 22 proto tcp"
assert_file_contains "$STUB_LOG" "sudo ufw allow 41641/udp"
assert_file_not_contains "$STUB_LOG" "ufw default deny"
assert_file_not_contains "$STUB_LOG" "ufw --force enable"
assert_not_contains "$RUN_OUTPUT" "203.0.113.9"
assert_exit 0 ufw_configured -n
no_sessions

# ss failing: ufw unchanged, and main still makes its other changes
touch "$SANDBOX/ss-fails"
rm -f "$SANDBOX/linger"
ufw_off
run main
assert_eq 1 "$RUN_STATUS" "the step without the connections"
assert_contains "$RUN_OUTPUT" "Couldn't list the established SSH connections"
firewall_unchanged
assert_file_contains "$STUB_LOG" "loginctl enable-linger"
assert_not_contains "$RUN_OUTPUT" "  Applied."
rm "$SANDBOX/ss-fails"

firewall_run
assert_eq 0 "$RUN_STATUS" "the step once the connections can be listed"
assert_exit 0 main --status
unset DOTFILES_ASSUME_YES
test_done
