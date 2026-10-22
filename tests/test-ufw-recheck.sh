#!/bin/bash
set -euo pipefail

# The ubuntu step's ufw firewall: sudo-free checks, its rules, and SSH sessions that keep it off.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox
load_script ubuntu/install.sh
ubuntu_sandbox_paths
as_os ubuntu
# Other tests cover these
replace_fn status_smart :
replace_fn status_firmware :
mkdir -p "$(dirname "$UFW_CONF")"
ufw_on() { echo ENABLED=yes > "$UFW_CONF"; }
ufw_off() { echo ENABLED=no > "$UFW_CONF"; }
ufw_defaults() { printf '%s\n' 'DEFAULT_INPUT_POLICY="DROP"' "IPV6=$1" > "$UFW_DEFAULTS"; }
ufw_on
ufw_defaults yes
# Linger state lives under /var
replace_fn lingering '[ -e "$SANDBOX/linger" ]'
replace_fn smartd_enabled true
replace_fn smartd_hook_installed true
echo "DEVICESCAN -M exec /usr/share/smartmontools/smartd-runner" > "$SMARTD_CONF"
replace_fn keep_conffiles_written true
replace_fn status_held_back :
replace_fn in_git_worktree false
replace_fn health_units_loaded true
replace_fn ups_todo :
replace_fn status_ups :
replace_fn warn_no_ups :
replace_fn sysctl_in_effect true
replace_fn locale_installed true
replace_fn unattended_upgrades_running true
replace_fn apt_timers_enabled true
replace_fn sshd_enabled true
replace_fn cloud_init_off true
replace_fn cups_browsed_off true
replace_fn wifi_powersave_off true
touch "$SANDBOX/linger"

# sudo -n succeeds only while $SANDBOX/cached exists; sudo install makes $SSHD_RUN_DIR, not /run.
stub_sudo_exec 'if [ "${1:-}" == -n ]; then
    [ -e "'"$SANDBOX"'/cached" ] || exit 1
    shift
fi
[ "${1:-}" != install ] || { mkdir -p "'"$SANDBOX"'/run-sshd"; exit 0; }'
cached() { touch "$SANDBOX/cached"; }
not_cached() { rm -f "$SANDBOX/cached"; }

stub systemctl 'case "$1" in
    is-enabled) if [ "$*" == "is-enabled -q ufw.service" ]; then [ ! -e "'"$SANDBOX"'/ufw-unit-disabled" ]; else echo masked; fi ;;
    is-active) [ "$*" != "is-active -q ufw.service" ] || [ ! -e "'"$SANDBOX"'/ufw-unit-inactive" ] ;;
    enable) [ "${!#}" != ufw.service ] || rm -f "'"$SANDBOX"'/ufw-unit-inactive" "'"$SANDBOX"'/ufw-unit-disabled" ;;
    show) [ "$2" != ssh.socket ] || sed "s/.*/[::]:& (Stream)/" "'"$SANDBOX"'/socket-ports" ;;
esac'
echo 22 > "$SANDBOX/socket-ports"
stub dpkg-query 'echo "install ok installed"'
tailscale_list_line > "$TAILSCALE_LIST"
stub tailscale 'case "$1" in
    debug) echo "{\"AutoUpdate\": {\"Apply\": true}, \"OperatorUser\": \"$(id -un)\", \"RunSSH\": false}" ;;
    funnel) echo "{}" ;;
    status) echo "{\"BackendState\": \"Running\"}" ;;
esac'
stub sshd '[ "$1" != -T ] || { echo "port 22"; awk "{ print tolower(\$1), \$2 }" "'"$SANDBOX"'/10-dotfiles.conf"; }'
stub ss
stub loginctl 'touch "'"$SANDBOX"'/linger"'
stub nmcli
stub lsblk
stub systemd-detect-virt 'exit 1'
SSHD_DROP_IN="$SANDBOX/10-dotfiles.conf"
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in > "$SSHD_DROP_IN"
mkdir -p "$SSHD_RUN_DIR" "$(dirname "$SLEEP_CONF")" "$(dirname "$SYSCTL_CONF")"
printf '%s\n' "$SLEEP_CONF_CONTENT" > "$SLEEP_CONF"
printf '%s\n' "$SYSCTL_CONTENT" > "$SYSCTL_CONF"

# Fake ufw over $SANDBOX/ufw-rules, in `ufw status` format; as in ufw, IPv6 rules fail with IPV6=no
stub ufw 'rules="'"$SANDBOX"'/ufw-rules"
case "$1" in
    status) if grep -qx ENABLED=no "'"$UFW_CONF"'" || [ -e "'"$SANDBOX"'/ufw-stopped" ]; then
            echo "Status: inactive"
        else
            cat "$rules"
        fi ;;
    allow) case "$*" in
            "allow from "*:*) if grep -qx IPV6=no "'"$UFW_DEFAULTS"'"; then
                    echo "ERROR: IPv6 support not enabled" >&2
                    exit 1
                fi
                rule="$(printf "%-26s ALLOW       %s" "$7/tcp" "$3")" ;;
            "allow from "*) rule="$(printf "%-26s ALLOW       %s" "$7/tcp" "$3")" ;;
            "allow in on tailscale0") rule="Anywhere on tailscale0     ALLOW       Anywhere" ;;
            *) rule="$(printf "%-26s ALLOW       Anywhere" "$2")" ;;
        esac
        grep -qxF "$rule" "$rules" || echo "$rule" >> "$rules" ;;
    prepend | delete)
        v4="$(printf "%-26s DENY        Anywhere" "$9/tcp on $5")"
        v6="$(printf "%-26s DENY        Anywhere (v6)" "$9/tcp (v6) on $5")"
        if [ "$1" == delete ]; then
            grep -vxF -e "$v4" -e "$v6" "$rules" > "$rules.new" || true
        elif grep -qxF "$v4" "$rules"; then
            exit 0
        else
            awk -v a="$v4" -v b="$v6" "{ print } /^--/ { print a; print b }" "$rules" > "$rules.new"
        fi
        mv "$rules.new" "$rules" ;;
    --force) echo ENABLED=yes > "'"$UFW_CONF"'"; rm -f "'"$SANDBOX"'/ufw-stopped" ;;
esac'
rules_present() {
    ufw_status_listing > "$SANDBOX/ufw-rules"
}
rules_missing() {
    { ufw_header; echo "Anywhere on tailscale0     ALLOW       Anywhere"; } > "$SANDBOX/ufw-rules"
}

no_prompting_sudo() {
    if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
        fail "the step ran sudo without -n:"
        _show "$(grep '^sudo' "$STUB_LOG")"
    fi
}

# Nothing else pending, credentials not cached: no prompt, only a hint
rules_present
not_cached
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_not_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "run sudo -v and re-run this step to check them"
no_prompting_sudo

# Credentials cached: rules checked up front
cached
rules_present
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
assert_not_contains "$RUN_OUTPUT" "sudo -v"
no_prompting_sudo
rules_missing
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Firewall: add the missing ufw rules, so ufw denies incoming connections but SSH from 10.0.0.0/8 192.168.0.0/16 fd00::/8 fe80::/10, anything on tailscale0, and Tailscale's 41641/udp, and denies SSH on Docker's bridges"
assert_not_contains "$RUN_OUTPUT" "install and turn on ufw"
assert_contains "$RUN_OUTPUT" "Left unchanged"
ufw_off
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Firewall: install and turn on ufw, so ufw denies incoming connections"
ufw_on

# Something else pending and approved, credentials not cached: rules checked after the confirm
not_cached
export DOTFILES_ASSUME_YES=1
rm -f "$SANDBOX/linger"
rules_present
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "loginctl enable-linger"
assert_file_contains "$STUB_LOG" "sudo ufw status"
assert_file_not_contains "$STUB_LOG" "ufw --force enable"

rm -f "$SANDBOX/linger"
rules_missing
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo ufw allow from 10.0.0.0/8 to any port 22 proto tcp"

# Without $SSHD_RUN_DIR the rules can't be read even with cached credentials
unset DOTFILES_ASSUME_YES
cached
rmdir "$SSHD_RUN_DIR"
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_contains "$RUN_OUTPUT" "first SSH connection"
[ ! -e "$SSHD_RUN_DIR" ] || fail "main created $SSHD_RUN_DIR without asking"
no_prompting_sudo

# Hand-added rules don't fail the check and aren't deleted
mkdir -p "$SSHD_RUN_DIR"
cached
rules_present
printf '%s\n' "80/tcp                     ALLOW       Anywhere" >> "$SANDBOX/ufw-rules"
: > "$STUB_LOG"
assert_exit 0 status
assert_eq 1 "$(grep -c '^sudo -n ufw status$' "$STUB_LOG")" "sudo ufw status runs in one status"
assert_eq 1 "$(grep -c '^sudo -n .*sshd -T$' "$STUB_LOG")" "sudo sshd -T runs in one status"
assert_contains "$RUN_OUTPUT" "ok         ufw rules allowing SSH from the private ranges"
assert_not_contains "$RUN_OUTPUT" "lets SSH in"
assert_contains "$RUN_OUTPUT" "ok         ufw filters IPv6"
# IPV6=no leaves sshd open over global IPv6: the step fails before changing ufw
ufw_defaults no
rules_missing
export DOTFILES_ASSUME_YES=1
for state in on off; do
    "ufw_$state"
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    ufw filters IPv6: $UFW_DEFAULTS lacks IPV6=yes, so sshd answers on the global IPv6 address; set it, run sudo ufw reload if ufw is on, then re-run the ubuntu step"
    : > "$STUB_LOG"
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "ufw doesn't filter IPv6, so the firewall is left unchanged: set IPV6=yes in $UFW_DEFAULTS,"
    if grep '^sudo ufw' "$STUB_LOG" | grep -qv '^sudo ufw status'; then
        fail "the step changed ufw with IPV6=no ($state):"
        _show "$(grep '^sudo ufw' "$STUB_LOG")"
    fi
    assert_file_contains "$UFW_DEFAULTS" IPV6=no
done
ufw_on
ufw_defaults yes

# Docker bridge deny rules must precede the allow rules, or containers reach sshd
for misplaced in false true; do
    { ufw_header; ufw_range_rules; ! "$misplaced" || ufw_deny_rules; } > "$SANDBOX/ufw-rules"
    ufw_tailscale_rules >> "$SANDBOX/ufw-rules"
    assert_exit 1 ufw_configured -n
    assert_exit 0 ufw_missing_rules -n
    assert_contains "$RUN_OUTPUT" "22/tcp on docker0 DENY Anywhere"
    assert_contains "$RUN_OUTPUT" "22/tcp (v6) on br-+ DENY Anywhere (v6)"
    assert_not_contains "$RUN_OUTPUT" "ALLOW"
    : > "$STUB_LOG"
    assert_exit 0 main
    if "$misplaced"; then
        assert_file_contains "$STUB_LOG" "sudo ufw delete deny in on docker0 to any port 22 proto tcp"
    else
        assert_file_not_contains "$STUB_LOG" "ufw delete"
    fi
    assert_file_contains "$STUB_LOG" "sudo ufw prepend deny in on docker0 to any port 22 proto tcp"
    assert_file_contains "$STUB_LOG" "sudo ufw prepend deny in on br-+ to any port 22 proto tcp"
    assert_exit 0 ufw_configured -n
done
# `ufw status` lists IPv6 rules after all IPv4 ones
{ ufw_header; ufw_deny_rules | grep -v v6; ufw_range_rules | grep -v :; ufw_deny_rules | grep v6; ufw_range_rules | grep :; } > "$SANDBOX/ufw-rules"
ufw_tailscale_rules >> "$SANDBOX/ufw-rules"
assert_exit 0 ufw_configured -n
# Adding a missing allow rule leaves the deny rules alone
rules_present
grep -v "41641/udp" "$SANDBOX/ufw-rules" > "$SANDBOX/ufw-rules.new"
mv "$SANDBOX/ufw-rules.new" "$SANDBOX/ufw-rules"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo ufw allow 41641/udp"
assert_file_not_contains "$STUB_LOG" "ufw delete"
assert_file_not_contains "$STUB_LOG" "ufw prepend"
assert_exit 0 ufw_configured -n
# Any form of rule above the deny rules that lets the SSH port in counts against them
for rule in "22 ALLOW 192.168.0.0/16" "20:30/tcp ALLOW 10.0.0.0/8" "80,22/tcp ALLOW 10.0.0.0/8" \
    "OpenSSH ALLOW 10.0.0.0/8" "192.168.1.5 ALLOW 10.0.0.0/8" "22/tcp ALLOW fd00::/8 # lan" \
    "Anywhere on br-1a2b3c ALLOW 10.0.0.0/8"; do
    { ufw_header; echo "$rule"; ufw_deny_rules; ufw_range_rules; } > "$SANDBOX/ufw-rules"
    ufw_tailscale_rules >> "$SANDBOX/ufw-rules"
    assert_exit 1 ufw_configured -n
done
{ ufw_header; echo "Anywhere on tailscale0 ALLOW Anywhere"; echo "22/udp ALLOW 10.0.0.0/8"; ufw_deny_rules; ufw_range_rules; } > "$SANDBOX/ufw-rules"
echo "41641/udp                  ALLOW       Anywhere" >> "$SANDBOX/ufw-rules"
assert_exit 0 ufw_configured -n
unset DOTFILES_ASSUME_YES
rules_present
printf '%s\n' "22/tcp                     ALLOW       Anywhere" \
    "OpenSSH                    ALLOW       Anywhere" \
    "22/tcp                     ALLOW       203.0.113.0/24" >> "$SANDBOX/ufw-rules"
assert_exit 0 ufw_configured -n
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "ok         ufw rules allowing SSH from the private ranges"
assert_contains "$RUN_OUTPUT" "missing    ufw rule lets SSH in from anywhere: 22/tcp ALLOW Anywhere; remove it with sudo ufw delete <number> (sudo ufw status numbered lists the numbers)"
assert_contains "$RUN_OUTPUT" "missing    ufw rule lets SSH in from anywhere: OpenSSH ALLOW Anywhere;"
assert_contains "$RUN_OUTPUT" "missing    ufw rule lets SSH in from 203.0.113.0/24, outside the private ranges: 22/tcp ALLOW 203.0.113.0/24;"
printf '%s\n' "22/tcp                     ALLOW       172.16.0.0/12" >> "$SANDBOX/ufw-rules"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw rule lets SSH in from 172.16.0.0/12, outside the private ranges: 22/tcp ALLOW 172.16.0.0/12;"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
assert_not_contains "$RUN_OUTPUT" "ufw delete"
assert_file_not_contains "$STUB_LOG" "ufw delete"
rules_present

# --- SSH sessions, from ss and logind, not SSH_CONNECTION ---
# ip route get: a gateway for outside, tailscale0 for the tailnet, wg0 (a VPN) for link-local
stub ss 'port="${4##*:}"
[ ! -e "'"$SANDBOX"'/ss-fails" ] || exit 1
cat "'"$SANDBOX"'/ss-${port% )}" 2> /dev/null || true'
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
        [ ! -e "'"$SANDBOX"'/logind-fails" ] || exit 1
        awk "{ print NR, 1000, \"me\", \"-\", 100 + NR, \"user\", \"pts/\" NR, \"no\", \"-\" }" "'"$SANDBOX"'/logins" 2> /dev/null || true ;;
    show-session) sed -n "$2p" "'"$SANDBOX"'/logins" ;;
    *) touch "'"$SANDBOX"'/linger" ;;
esac'
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
    : > "$STUB_LOG"
    run configure_ufw
}
firewall_unchanged() {
    assert_file_not_contains "$STUB_LOG" "ufw --force enable"
    assert_file_not_contains "$STUB_LOG" "ufw default deny"
    assert_file_not_contains "$STUB_LOG" "ufw allow"
}
export DOTFILES_ASSUME_YES=1
cached
rules_present

# Console run: ufw goes on, and ss runs without sudo
no_sessions
firewall_run
assert_eq 0 "$RUN_STATUS" "the step from the console"
assert_file_contains "$STUB_LOG" "ss -Htn state established ( sport = :22 )"
assert_file_not_contains "$STUB_LOG" "sudo ss "
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# Config says on but ufw.service is stopped
touch "$SANDBOX/ufw-unit-inactive"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw on, denying incoming connections"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now -q ufw.service"
[ ! -e "$SANDBOX/ufw-unit-inactive" ] || fail "the step left ufw.service stopped"
assert_exit 0 status
# ufw.service running but disabled
touch "$SANDBOX/ufw-unit-disabled"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw on, denying incoming connections"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now -q ufw.service"
[ ! -e "$SANDBOX/ufw-unit-disabled" ] || fail "the step left ufw.service disabled"
assert_exit 0 status
# Stopped by ufw-init stop: files and unit say on, `ufw status` says inactive
touch "$SANDBOX/ufw-stopped"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw on, denying incoming connections: ufw status says it's inactive"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Firewall: install and turn on ufw"
assert_file_contains "$STUB_LOG" "sudo ufw default deny incoming"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"
[ ! -e "$SANDBOX/ufw-stopped" ] || fail "the step left ufw stopped"
assert_exit 0 status
touch "$SANDBOX/ufw-stopped"
not_cached
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified ufw rules allowing SSH"
cached
rm "$SANDBOX/ufw-stopped"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "ufw --force enable"
assert_file_not_contains "$STUB_LOG" "ufw default deny"

# Private-range, tailnet, and link-local (any interface) sessions survive, so ufw goes on
sessions 22 192.168.1.5:22 192.168.1.20:51000 100.64.0.1:22 100.64.0.2:51000 \
    '[::ffff:192.168.1.5]:22' '[::ffff:192.168.1.21]:51001' \
    '[fe80::5%eth0]:22' '[fe80::20%eth0]:51002' \
    '[fd7a:115c:a1e0::1]:22' '[fd7a:115c:a1e0::2]:51003' '[fe80::5%wg0]:22' '[fe80::30%wg0]:51004'
logins 192.168.1.20 100.64.0.2 fe80::30
firewall_run
assert_eq 0 "$RUN_STATUS" "the step over the LAN and the tailnet"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# An outside connection without a logind login (a scanner) doesn't count
sessions 22 192.168.1.5:22 192.168.1.20:51000 203.0.113.9:51000
logins 192.168.1.20
firewall_run
assert_eq 0 "$RUN_STATUS" "the step with a connection from outside that hasn't logged in"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# An outside session leaves the firewall unchanged; a stale tmux SSH_CONNECTION doesn't count
logins 192.168.1.20 203.0.113.9
rm -f "$SANDBOX/linger"
export TMUX=/tmp/tmux-1000/default,1,0 SSH_CONNECTION="192.168.1.20 51000 192.168.1.5 22"
firewall_run
unset TMUX SSH_CONNECTION
assert_eq 1 "$RUN_STATUS" "the step with a session from outside"
assert_contains "$RUN_OUTPUT" "203.0.113.9"
assert_contains "$RUN_OUTPUT" "the machine, over SSH from 10.0.0.0/8 192.168.0.0/16 fd00::/8 fe80::/10, or over Tailscale."
assert_contains "$RUN_OUTPUT" "If the Mac connects over IPv6 (e.g. to $(hostname).local), connect to the machine's IPv4"
assert_contains "$RUN_OUTPUT" "address (ip -4 addr) or, once Tailscale is up, its tailnet name, and re-run."
firewall_unchanged

# ssh.socket also on 2222, which sshd -T doesn't report
printf '%s\n' 22 2222 > "$SANDBOX/socket-ports"
no_sessions
rules_missing
firewall_run
assert_eq 0 "$RUN_STATUS" "the step with ssh.socket on 2222"
assert_file_contains "$STUB_LOG" "sudo ufw allow from 192.168.0.0/16 to any port 2222 proto tcp"
assert_file_contains "$STUB_LOG" "sudo ufw allow from fe80::/10 to any port 22 proto tcp"
assert_exit 0 ufw_configured -n
sessions 22 192.168.1.5:22 192.168.1.20:51000
sessions 2222 '[::ffff:192.168.1.5]:2222' '[::ffff:198.51.100.7]:50000'
logins 198.51.100.7
firewall_run
assert_eq 1 "$RUN_STATUS" "the step with an IPv4-mapped session from outside"
assert_file_contains "$STUB_LOG" "ss -Htn state established ( sport = :2222 )"
assert_contains "$RUN_OUTPUT" "198.51.100.7"
firewall_unchanged
sessions 2222 '[2001:db8:1::5]:2222' '[2001:db8:9::7]:50000'
logins 2001:db8:9::7
firewall_run
assert_eq 1 "$RUN_STATUS" "the step with an IPv6 session from outside"
assert_contains "$RUN_OUTPUT" "2001:db8:9::7"
firewall_unchanged
echo 22 > "$SANDBOX/socket-ports"
rm "$SANDBOX/ss-2222"
rules_present

# logind failing or naming a host (UseDNS yes): every outside connection counts
sessions 22 192.168.1.5:22 203.0.113.9:51000
logins 192.168.1.20
touch "$SANDBOX/logind-fails"
firewall_run
assert_eq 1 "$RUN_STATUS" "the step without logind's sessions"
assert_contains "$RUN_OUTPUT" "203.0.113.9"
firewall_unchanged
rm "$SANDBOX/logind-fails"
logins client.example.net
firewall_run
assert_eq 1 "$RUN_STATUS" "the step with a session named by host"
assert_contains "$RUN_OUTPUT" "203.0.113.9"
firewall_unchanged

# With ufw on, an outside session doesn't block adding allow rules, which can't cut anyone off
ufw_on
sessions 22 192.168.1.5:22 203.0.113.9:51000
logins 203.0.113.9
rules_missing
: > "$STUB_LOG"
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
: > "$STUB_LOG"
run main
assert_eq 1 "$RUN_STATUS" "the step without the connections"
assert_contains "$RUN_OUTPUT" "Couldn't list the established SSH connections"
firewall_unchanged
assert_file_contains "$STUB_LOG" "loginctl enable-linger"
assert_not_contains "$RUN_OUTPUT" "  Applied."
rm "$SANDBOX/ss-fails"

firewall_run
assert_eq 0 "$RUN_STATUS" "the step once the connections can be listed"
assert_exit 0 status
assert_not_contains "$RUN_OUTPUT" "Temporary"
unset DOTFILES_ASSUME_YES
test_done
