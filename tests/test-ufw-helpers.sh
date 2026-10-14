#!/bin/bash
set -euo pipefail

# The ubuntu step's firewall helpers: sshd_ports adds the ports ssh.socket listens on to sshd's,
# and outside_address tells the addresses the firewall would cut off.
# test-ufw-recheck.sh covers the step around them.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ubuntu/install.sh

# sudo runs the command
stub sudo '[ "$1" != -n ] || shift; exec "$@"'
SSHD_RUN_DIR="$SANDBOX/run-sshd"
mkdir -p "$SSHD_RUN_DIR"

# --- sshd_ports: sshd -T's ports, and ssh.socket's while it's active ---
# sshd -T reports 22, and a ListenAddress with its own port, while ssh.socket listens on 2222, as
# systemctl show lists its addresses
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
# sshd -T failing fails it
stub sshd 'exit 255'
assert_exit 1 sshd_ports -n

# --- outside_address: outside the private ranges, and not over tailscale0 or lo ---
stub ip 'case "$3" in
    100.64.0.2 | fd7a:115c:a1e0::2) echo "$3 dev tailscale0 table 52 src 100.64.0.1" ;;
    127.0.0.1 | ::1) echo "local $3 dev lo src 127.0.0.1" ;;
    198.51.100.1) exit 2 ;;
    *) echo "$3 via 192.168.1.1 dev eth0 src 192.168.1.5" ;;
esac'
outside() { if outside_address "$1"; then echo outside; else echo inside; fi; }
for address in 10.1.2.3 172.16.0.9 172.31.255.1 192.168.1.20 fd12:3456::1 fe80::5 fe80::5%wg0 \
    febf::1 100.64.0.2 fd7a:115c:a1e0::2 127.0.0.1 ::1; do
    assert_eq inside "$(outside "$address")" "$address"
done
for address in 203.0.113.9 172.32.0.1 172.15.0.1 192.169.1.1 11.0.0.1 2001:db8::7 fc00::1 \
    fec0::1 fd::1 198.51.100.1; do
    assert_eq outside "$(outside "$address")" "$address"
done
test_done
