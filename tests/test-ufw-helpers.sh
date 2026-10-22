#!/bin/bash
set -euo pipefail

# The ubuntu step's ufw helpers: the SSH ports, which addresses count as outside, which rules let SSH
# in from outside the private ranges, and when ufw counts as on. test-ufw-recheck.sh covers the step
# around them.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox
load_script ubuntu/install.sh
ubuntu_sandbox_paths

stub_sudo_exec
mkdir -p "$SSHD_RUN_DIR"

# --- sshd_ports ---
stub sshd '[ "$1" != -T ] || printf "%s\n" "port 22" "listenaddress 127.0.0.1:2300"'
stub systemctl 'case "$*" in
    "is-active -q ssh.socket") ;;
    "show ssh.socket -p Listen --value") printf "%s\n" "0.0.0.0:2222 (Stream)" "[::]:2222 (Stream)" ;;
    *) exit 1 ;;
esac'
assert_eq "22
2222
2300" "$(sshd_ports -n)" "the SSH ports with ssh.socket active"
stub systemctl '[ "$1" != is-active ] || exit 3'
assert_eq "22
2300" "$(sshd_ports -n)" "the SSH ports with ssh.socket inactive"
stub sshd 'exit 255'
assert_exit 1 sshd_ports -n

# --- outside_address ---
stub ip 'case "$3" in
    100.64.0.2 | fd7a:115c:a1e0::2) echo "$3 dev tailscale0 table 52 src 100.64.0.1" ;;
    127.0.0.1 | ::1) echo "local $3 dev lo src 127.0.0.1" ;;
    198.51.100.1) exit 2 ;;
    *) echo "$3 via 192.168.1.1 dev eth0 src 192.168.1.5" ;;
esac'
outside() { if outside_address "$1"; then echo outside; else echo inside; fi; }
for address in 10.1.2.3 192.168.1.20 fd12:3456::1 fe80::5 fe80::5%wg0 \
    febf::1 100.64.0.2 fd7a:115c:a1e0::2 127.0.0.1 ::1; do
    assert_eq inside "$(outside "$address")" "$address"
done
# 172.16.0.0/12 holds Docker's bridges, so it's outside
for address in 203.0.113.9 172.16.0.9 172.17.0.2 172.31.255.1 172.32.0.1 172.15.0.1 192.169.1.1 \
    11.0.0.1 2001:db8::7 fc00::1 fec0::1 fd::1 198.51.100.1; do
    assert_eq outside "$(outside "$address")" "$address"
done

# --- ufw_broad_ssh_rules ---
stub sshd '[ "$1" != -T ] || printf "%s\n" "port 22" "port 2222"'
stub systemctl '[ "$1" != is-active ] || exit 3'
stub ufw '[ "$1" != status ] || cat "'"$SANDBOX"'/ufw-rules"'
wanted_rules() {
    ufw_header
    ufw_range_rules 22
    ufw_range_rules 2222
    ufw_tailscale_rules
}
# Narrower ranges inside each private one, and other ports, aren't broad
{
    wanted_rules
    printf '%s\n' "22/tcp                     ALLOW       192.168.1.0/24" \
        "22/tcp                     ALLOW       10.0.0.0/12" \
        "22/tcp                     ALLOW       10.1.2.3" \
        "22/tcp                     ALLOW       fd00::/9" \
        "22/tcp                     ALLOW       fe80::/64" \
        "80/tcp                     ALLOW       Anywhere" \
        "22/udp                     ALLOW       Anywhere" \
        "22/tcp                     ALLOW OUT   Anywhere" \
        "22/tcp                     DENY        Anywhere" \
        "8000:8100/tcp              ALLOW       Anywhere"
} > "$SANDBOX/ufw-rules"
assert_eq "" "$(ufw_broad_ssh_rules -n)" "the broad SSH rules among the wanted ones"
{
    wanted_rules
    printf '%s\n' "22/tcp                     ALLOW       Anywhere" \
        "22/tcp (v6)                ALLOW       Anywhere (v6)" \
        "OpenSSH                    LIMIT       Anywhere" \
        "2000:3000/tcp              ALLOW       Anywhere" \
        "80,2222/tcp                ALLOW       Anywhere # web" \
        "Anywhere                   ALLOW       203.0.113.9" \
        "22                         ALLOW       10.0.0.0/7" \
        "192.168.1.5 22/tcp on eth0 ALLOW       Anywhere" \
        "22/tcp                     ALLOW       172.16.0.0/12" \
        "22/tcp                     ALLOW       192.168.0.0/15" \
        "22/tcp                     ALLOW       fd00::/7" \
        "22/tcp                     ALLOW       fe80::/9"
} > "$SANDBOX/ufw-rules"
assert_eq "$(printf '%s\t%s\n' Anywhere "22/tcp ALLOW Anywhere" Anywhere "22/tcp (v6) ALLOW Anywhere (v6)" \
    Anywhere "OpenSSH LIMIT Anywhere" Anywhere "2000:3000/tcp ALLOW Anywhere" \
    Anywhere "80,2222/tcp ALLOW Anywhere # web" 203.0.113.9 "Anywhere ALLOW 203.0.113.9" \
    10.0.0.0/7 "22 ALLOW 10.0.0.0/7" Anywhere "192.168.1.5 22/tcp on eth0 ALLOW Anywhere" \
    172.16.0.0/12 "22/tcp ALLOW 172.16.0.0/12" 192.168.0.0/15 "22/tcp ALLOW 192.168.0.0/15" \
    fd00::/7 "22/tcp ALLOW fd00::/7" fe80::/9 "22/tcp ALLOW fe80::/9")" "$(ufw_broad_ssh_rules -n)" "the broad SSH rules"
stub ufw 'exit 1'
assert_exit 1 ufw_broad_ssh_rules -n
stub ufw '[ "$1" != status ] || cat "'"$SANDBOX"'/ufw-rules"'
stub sshd 'exit 255'
assert_exit 1 ufw_broad_ssh_rules -n

# --- ufw_enabled: incoming denied by DROP or REJECT ---
stub ufw
stub systemctl
mkdir -p "$(dirname "$UFW_CONF")"
echo ENABLED=yes > "$UFW_CONF"
for policy in DROP REJECT; do
    echo "DEFAULT_INPUT_POLICY=\"$policy\"" > "$UFW_DEFAULTS"
    assert_exit 0 ufw_enabled
done
echo 'DEFAULT_INPUT_POLICY="ACCEPT"' > "$UFW_DEFAULTS"
assert_exit 1 ufw_enabled
test_done
