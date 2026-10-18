#!/bin/bash
set -euo pipefail
# os: ubuntu

# The ubuntu step doesn't ask for sudo just to re-check the ufw rules. It checks them up front when
# sudo credentials are cached, and after the confirm when other changes need sudo anyway. It leaves
# rules you added by hand alone. While a logged-in SSH session comes from outside the private ranges
# and the tailnet, it doesn't turn ufw on, and fails; with ufw on, it adds the missing rules, which
# can't cut anyone off. A connection that hasn't logged in doesn't count. The SSH ports include
# ssh.socket's.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox
load_script ubuntu/install.sh
ubuntu_sandbox_paths
is_ubuntu() { true; }
# test-diagnostics-ubuntu.sh covers SMART health and firmware updates
status_smart() { :; }
status_firmware() { :; }
# ufw's on state and linger come from files under /etc and /var, so those checks are replaced.
# Linger is on when $SANDBOX/linger exists, and loginctl turns it on.
ufw_enabled() { [ ! -e "$SANDBOX/ufw-off" ]; }
echo IPV6=yes > "$UFW_DEFAULTS"
lingering() { [ -e "$SANDBOX/linger" ]; }
# test-ubuntu-step.sh covers smartd with its hook, the locale, unattended-upgrades with its
# conffile options, the packages apt holds back, and the health alerts' worktree check and reload
smartd_enabled() { true; }
smartd_hook_installed() { true; }
keep_conffiles_written() { true; }
status_held_back() { :; }
in_git_worktree() { false; }
health_units_loaded() { true; }
# test-ubuntu-ups.sh covers the UPS
ups_todo() { :; }
status_ups() { :; }
warn_no_ups() { :; }
# The kernel has the sysctl settings, which test-ubuntu-step.sh covers
sysctl_in_effect() { true; }
locale_installed() { true; }
unattended_upgrades_running() { true; }
# test-ubuntu-step.sh covers apt's timers, sshd at boot, and a pending reboot
apt_timers_enabled() { true; }
sshd_enabled() { true; }
touch "$SANDBOX/linger"

# sudo without -n runs the command, as if you typed your password. sudo -n works only while
# $SANDBOX/cached exists. sudo install makes $SSHD_RUN_DIR, the only install this test reaches,
# instead of touching the real /run.
stub sudo 'if [ "$1" == -n ]; then
    [ -e "'"$SANDBOX"'/cached" ] || exit 1
    shift
fi
[ "$1" != install ] || { mkdir -p "'"$SANDBOX"'/run-sshd"; exit 0; }
exec "$@"'
cached() { touch "$SANDBOX/cached"; }
not_cached() { rm -f "$SANDBOX/cached"; }

# Everything else is set up
# ssh.socket listens on the ports in $SANDBOX/socket-ports, one per line, as systemctl show lists
# its addresses
stub systemctl 'case "$1" in
    is-enabled) echo masked ;;
    show) [ "$2" != ssh.socket ] || sed "s/.*/[::]:& (Stream)/" "'"$SANDBOX"'/socket-ports" ;;
esac'
echo 22 > "$SANDBOX/socket-ports"
stub dpkg-query 'echo "install ok installed"'
# Tailscale's apt source is the one the step writes
tailscale_list_line > "$TAILSCALE_LIST"
stub tailscale 'case "$1" in
    debug) echo "{\"AutoUpdate\": {\"Apply\": true}, \"OperatorUser\": \"$(id -un)\"}" ;;
    status) echo "{\"BackendState\": \"Running\"}" ;;
esac'
# sshd -T prints the port, and the drop-in's settings as sshd takes them
stub sshd '[ "$1" != -T ] || { echo "port 22"; awk "{ print tolower(\$1), \$2 }" "'"$SANDBOX"'/10-dotfiles.conf"; }'
# No SSH sessions, as at the console; the end of the test covers them
stub ss
stub loginctl 'touch "'"$SANDBOX"'/linger"'
stub nmcli
stub lsblk
SSHD_DROP_IN="$SANDBOX/10-dotfiles.conf"
# Password logins already off
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in > "$SSHD_DROP_IN"
# The rest is set up too, through sandbox paths
mkdir -p "$SSHD_RUN_DIR" "$(dirname "$SLEEP_CONF")" "$(dirname "$SYSCTL_CONF")"
printf '%s\n' "$SLEEP_CONF_CONTENT" > "$SLEEP_CONF"
printf '%s\n' "$SYSCTL_CONTENT" > "$SYSCTL_CONF"

# A small ufw over $SANDBOX/ufw-rules, which holds the rules as `ufw status` lists them. status
# lists them, or says it's inactive while $SANDBOX/ufw-off exists. allow from <range> to any port
# <port> proto tcp, allow in on tailscale0, and allow <port>/<proto> add their rule once, and
# --force enable turns ufw on.
stub ufw 'rules="'"$SANDBOX"'/ufw-rules"
case "$1" in
    status) if [ -e "'"$SANDBOX"'/ufw-off" ]; then echo "Status: inactive"; else cat "$rules"; fi ;;
    allow) case "$*" in
            "allow from "*) rule="$(printf "%-26s ALLOW       %s" "$7/tcp" "$3")" ;;
            "allow in on tailscale0") rule="Anywhere on tailscale0     ALLOW       Anywhere" ;;
            *) rule="$(printf "%-26s ALLOW       Anywhere" "$2")" ;;
        esac
        grep -qxF "$rule" "$rules" || echo "$rule" >> "$rules" ;;
    --force) rm -f "'"$SANDBOX"'/ufw-off" ;;
esac'
# The step's rules for SSH on port 22
range_rules() {
    local range
    for range in 10.0.0.0/8 192.168.0.0/16 fd00::/8 fe80::/10; do
        printf '%-26s ALLOW       %s\n' "${1:-22}/tcp" "$range"
    done
}
rules_present() {
    {
        printf '%s\n' "Status: active" "" "To                         Action      From" \
            "--                         ------      ----"
        range_rules
        printf '%s\n' "Anywhere on tailscale0     ALLOW       Anywhere" "41641/udp                  ALLOW       Anywhere"
    } > "$SANDBOX/ufw-rules"
}
rules_missing() {
    printf 'Status: active\n\nAnywhere on tailscale0     ALLOW       Anywhere\n' > "$SANDBOX/ufw-rules"
}

# Only sudo -n ran, so nothing asked for a password
no_prompting_sudo() {
    if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
        fail "the step ran sudo without -n:"
        _show "$(grep '^sudo' "$STUB_LOG")"
    fi
}

# Nothing else pending, credentials not cached: no confirm, no prompt, and a hint to check them
rules_present
not_cached
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_not_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "run sudo -v and re-run this step to check them"
no_prompting_sudo

# Credentials cached: checked up front, so present rules are set up and missing ones are pending
cached
rules_present
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
assert_not_contains "$RUN_OUTPUT" "sudo -v"
no_prompting_sudo
rules_missing
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Firewall: install and enable ufw"
assert_contains "$RUN_OUTPUT" "Left unchanged"

# Something else pending and approved, credentials not cached: the rules are checked with sudo
# after the confirm, and set only when they're missing
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

# Without $SSHD_RUN_DIR, which only the install path creates, the rules can't be read even with
# cached credentials. With nothing else pending, the step says why and asks for nothing.
unset DOTFILES_ASSUME_YES
cached
rmdir "$SSHD_RUN_DIR"
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_contains "$RUN_OUTPUT" "first SSH connection"
[ ! -e "$SSHD_RUN_DIR" ] || fail "main created $SSHD_RUN_DIR without asking"
no_prompting_sudo

# Rules you added by hand, even ones that let SSH in from anywhere, don't fail the check, and the
# step deletes nothing. Status reports each one that lets SSH in from elsewhere.
mkdir -p "$SSHD_RUN_DIR"
cached
rules_present
printf '%s\n' "80/tcp                     ALLOW       Anywhere" >> "$SANDBOX/ufw-rules"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         ufw rules allowing SSH from the private ranges"
assert_not_contains "$RUN_OUTPUT" "lets SSH in"
assert_contains "$RUN_OUTPUT" "ok         ufw filters IPv6"
# ufw on with IPV6=no leaves sshd open on the global IPv6 address: status says so, and the step
# leaves the file to you
echo IPV6=no > "$UFW_DEFAULTS"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw filters IPv6: $UFW_DEFAULTS lacks IPV6=yes, so sshd answers on the global IPv6 address; set it, then run sudo ufw reload"
assert_exit 0 main
assert_eq IPV6=no "$(cat "$UFW_DEFAULTS")" "ufw's defaults after a run"
echo IPV6=yes > "$UFW_DEFAULTS"
printf '%s\n' "22/tcp                     ALLOW       Anywhere" \
    "OpenSSH                    ALLOW       Anywhere" \
    "22/tcp                     ALLOW       203.0.113.0/24" >> "$SANDBOX/ufw-rules"
assert_exit 0 ufw_configured -n
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "ok         ufw rules allowing SSH from the private ranges"
assert_contains "$RUN_OUTPUT" "missing    ufw rule lets SSH in from anywhere: 22/tcp ALLOW Anywhere; remove it with sudo ufw delete <number> (sudo ufw status numbered lists the numbers)"
assert_contains "$RUN_OUTPUT" "missing    ufw rule lets SSH in from anywhere: OpenSSH ALLOW Anywhere;"
assert_contains "$RUN_OUTPUT" "missing    ufw rule lets SSH in from 203.0.113.0/24, outside the private ranges: 22/tcp ALLOW 203.0.113.0/24;"
# The rule for 172.16.0.0/12 an earlier version added, which lets Docker's containers reach sshd
printf '%s\n' "22/tcp                     ALLOW       172.16.0.0/12" >> "$SANDBOX/ufw-rules"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    ufw rule lets SSH in from 172.16.0.0/12, outside the private ranges: 22/tcp ALLOW 172.16.0.0/12;"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
assert_not_contains "$RUN_OUTPUT" "ufw delete"
assert_file_not_contains "$STUB_LOG" "ufw delete"
rules_present

# --- the SSH sessions, from ss and logind, not the pane's SSH_CONNECTION ---
# ss lists the established connections to a port from $SANDBOX/ss-<port>, and fails while
# $SANDBOX/ss-fails exists. ip route get shows a gateway for an address outside the local
# network, tailscale0 for the tailnet, and eth0 for the rest, IPv6 too, but for a link-local
# address, which it routes on wg0, a VPN's interface.
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
# logind lists a session for each address in $SANDBOX/logins, its RemoteHost, as pam_systemd
# registers one once an SSH login succeeds, and fails while $SANDBOX/logind-fails exists
stub loginctl 'case "$1" in
    list-sessions)
        [ ! -e "'"$SANDBOX"'/logind-fails" ] || exit 1
        awk "{ print NR, 1000, \"me\", \"-\", 100 + NR, \"user\", \"pts/\" NR, \"no\", \"-\" }" "'"$SANDBOX"'/logins" 2> /dev/null || true ;;
    show-session) sed -n "$2p" "'"$SANDBOX"'/logins" ;;
    *) touch "'"$SANDBOX"'/linger" ;;
esac'
# Set the established connections to a port: "<local> <peer>" pairs, as ss prints them
sessions() {
    local port="$1"
    shift
    printf '0 0 %s %s\n' "$@" > "$SANDBOX/ss-$port"
}
# Set the addresses SSH logins came from
logins() { printf '%s\n' "$@" > "$SANDBOX/logins"; }
no_sessions() { rm -f "$SANDBOX"/ss-[0-9]* "$SANDBOX/logins"; }
# Turn ufw off and run the step, which then sets the firewall up
firewall_run() {
    touch "$SANDBOX/ufw-off"
    : > "$STUB_LOG"
    run main
}
# The firewall was left as it was
firewall_unchanged() {
    assert_file_not_contains "$STUB_LOG" "ufw --force enable"
    assert_file_not_contains "$STUB_LOG" "ufw default deny"
    assert_file_not_contains "$STUB_LOG" "ufw allow"
}
export DOTFILES_ASSUME_YES=1
cached
rules_present

# A console run, with no SSH session at all: ufw goes on. ss lists the connections without sudo.
no_sessions
firewall_run
assert_eq 0 "$RUN_STATUS" "the step from the console"
assert_file_contains "$STUB_LOG" "ss -Htn state established ( sport = :22 )"
assert_file_not_contains "$STUB_LOG" "sudo ss "
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# Sessions from the private ranges or the tailnet, over IPv4, IPv6, and IPv4-mapped IPv6, keep
# working, so ufw goes on. A link-local one does whatever interface it came in on, such as a VPN's,
# since ufw lets in fe80::/10 on any.
sessions 22 192.168.1.5:22 192.168.1.20:51000 100.64.0.1:22 100.64.0.2:51000 \
    '[::ffff:192.168.1.5]:22' '[::ffff:192.168.1.21]:51001' \
    '[fe80::5%eth0]:22' '[fe80::20%eth0]:51002' \
    '[fd7a:115c:a1e0::1]:22' '[fd7a:115c:a1e0::2]:51003' '[fe80::5%wg0]:22' '[fe80::30%wg0]:51004'
logins 192.168.1.20 100.64.0.2 fe80::30
firewall_run
assert_eq 0 "$RUN_STATUS" "the step over the LAN and the tailnet"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# A connection from outside with no login, such as a scanner's or one still logging in, doesn't
# count, so ufw goes on, as it would with port 22 open to the internet
sessions 22 192.168.1.5:22 192.168.1.20:51000 203.0.113.9:51000
logins 192.168.1.20
firewall_run
assert_eq 0 "$RUN_STATUS" "the step with a connection from outside that hasn't logged in"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# A session from outside leaves the firewall unchanged: the step says why, does the rest, and
# fails. The pane's SSH_CONNECTION, a stale tmux one, doesn't count.
logins 192.168.1.20 203.0.113.9
rm -f "$SANDBOX/linger"
export TMUX=/tmp/tmux-1000/default,1,0 SSH_CONNECTION="192.168.1.20 51000 192.168.1.5 22"
firewall_run
unset TMUX SSH_CONNECTION
assert_eq 1 "$RUN_STATUS" "the step with a session from outside"
assert_contains "$RUN_OUTPUT" "203.0.113.9"
assert_contains "$RUN_OUTPUT" "Tailscale"
assert_contains "$RUN_OUTPUT" "If the Mac connects over IPv6 (e.g. to $(hostname).local), connect to the machine's IPv4"
assert_contains "$RUN_OUTPUT" "address (ip -4 addr) or, once Tailscale is up, its tailnet name, and re-run."
assert_file_contains "$STUB_LOG" "loginctl enable-linger"
firewall_unchanged
assert_not_contains "$RUN_OUTPUT" "  Applied."

# sshd -T reports port 22 while ssh.socket listens on 2222 too: both get rules, and a session from
# outside on 2222, over IPv4-mapped IPv6 or IPv6, keeps the firewall as it is
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

# When logind can't say which connections logged in, or names a host it can't match, as with
# sshd's UseDNS yes, every connection from outside counts
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

# With ufw on, a session from outside doesn't stop the missing rules: allow rules can't cut anyone
# off. ufw isn't turned on again, nor its policy set.
rm -f "$SANDBOX/ufw-off"
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

# The connections can't be listed: ufw stays as it is, and the rest of the step still runs
touch "$SANDBOX/ss-fails"
rm -f "$SANDBOX/linger"
firewall_run
assert_eq 1 "$RUN_STATUS" "the step without the connections"
assert_contains "$RUN_OUTPUT" "Couldn't list the established SSH connections"
firewall_unchanged
assert_file_contains "$STUB_LOG" "loginctl enable-linger"
rm "$SANDBOX/ss-fails"

# Once the connections can be listed, the step succeeds
firewall_run
assert_eq 0 "$RUN_STATUS" "the step once the connections can be listed"
assert_exit 0 status
assert_not_contains "$RUN_OUTPUT" "Temporary"
unset DOTFILES_ASSUME_YES
test_done
