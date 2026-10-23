#!/bin/bash

# The ubuntu step's ufw helpers: the SSH ports, which addresses count as outside, and when ufw counts
# as on. test-ufw-recheck.sh covers the step around them.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

load_script ubuntu/install.sh
ubuntu_sandbox_paths

# --- sshd_ports: ssh.socket's, or 22 ---
stub systemctl '[ "$*" != "show ssh.socket -p Listen --value" ] ||
    printf "%s\n" "0.0.0.0:2222 (Stream)" "[::]:2222 (Stream)" "[::]:22 (Stream)"'
assert_eq "22
2222" "$(sshd_ports)" "the SSH ports ssh.socket listens on"
stub systemctl 'exit 1'
assert_eq 22 "$(sshd_ports)" "the SSH ports without ssh.socket"

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

# --- ufw_enabled: incoming denied by DROP or REJECT ---
stub ufw
stub systemctl
mkdir -p "$(dirname "$UFW_CONF")" "$(dirname "$UFW_DEFAULTS")"
echo ENABLED=yes > "$UFW_CONF"
for policy in DROP REJECT; do
    echo "DEFAULT_INPUT_POLICY=\"$policy\"" > "$UFW_DEFAULTS"
    assert_exit 0 ufw_enabled
done
echo 'DEFAULT_INPUT_POLICY="ACCEPT"' > "$UFW_DEFAULTS"
assert_exit 1 ufw_enabled
test_done
