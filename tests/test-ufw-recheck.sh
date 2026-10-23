#!/bin/bash

# The ubuntu step's ufw firewall: sudo-free checks and its rules. test-ufw-sessions.sh covers the
# SSH sessions that keep it off.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
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
# enable-linger turns linger on
stub loginctl 'touch "$SANDBOX/linger"'
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
stub_apt_packages '*' '!openssh-server'
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "openssh-server isn't installed"
assert_not_contains "$RUN_OUTPUT" "sudo -v"
assert_sudo_noninteractive
stub_apt_packages '*'

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
test_done
