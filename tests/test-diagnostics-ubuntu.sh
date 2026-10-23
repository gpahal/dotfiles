#!/bin/bash
# shellcheck disable=SC2329 # the steps call the replaced functions
set -euo pipefail

# Status's free space check on either OS, and the ubuntu step's read-only SMART and firmware checks.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=diagnostics-fixture.sh
source "$TESTS_DIR/diagnostics-fixture.sh"

setup_sandbox
load_script lib/common.sh
stub dpkg-query 'exit 1'
stub_dpkg_arch
stub_apt_config

# --- free space (status_disk_space) ---
df_lines "/dev/sda2 $((500 * GIB)) $((380 * GIB)) $((120 * GIB)) 76% /"
assert_exit 0 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "ok         Free space on /: 120.0 GiB of 500.0 GiB (24%)"
assert_file_contains "$STUB_LOG" "df -P -k /"
df_lines "/dev/sda2 $((500 * GIB)) $((500 * GIB)) 0 100% /"
assert_exit 3 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "missing    Free space on /: 0.0 GiB of 500.0 GiB (0%)"
df_lines "/dev/sda2 $((2000 * GIB)) $((1850 * GIB)) $((150 * GIB)) 93% /"
assert_exit 3 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "missing    Free space on /: 150.0 GiB of 2000.0 GiB (7%)"
df_lines "/dev/vda1 $((40 * GIB)) $((31 * GIB)) $((9 * GIB)) 78% /"
assert_exit 3 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "missing    Free space on /: 9.0 GiB of 40.0 GiB (22%)"
# Exactly at the floor is enough
df_lines "/dev/vda1 $((100 * GIB)) $((90 * GIB)) $((10 * GIB)) 90% /"
assert_exit 0 diag status_disk_space /
# Same filesystem or a bind mount of it: one item
df_lines "/dev/sda2 $((500 * GIB)) $((380 * GIB)) $((120 * GIB)) 76% /" \
    "/dev/sda2 $((500 * GIB)) $((380 * GIB)) $((120 * GIB)) 76% /srv/bind" \
    "/dev/sdb1 $((900 * GIB)) $((100 * GIB)) $((800 * GIB)) 12% /home"
assert_exit 0 diag status_disk_space / /srv/bind /home
assert_eq 2 "$(grep -c 'Free space on' <<< "$RUN_OUTPUT")" "items for two filesystems"
assert_contains "$RUN_OUTPUT" "ok         Free space on /home: 800.0 GiB of 900.0 GiB (88%)"
echo /gone > "$SANDBOX/df-fails"
assert_exit 3 diag status_disk_space /gone /
assert_contains "$RUN_OUTPUT" "unknown    Free space on /gone: df couldn't read it"
assert_contains "$RUN_OUTPUT" "ok         Free space on /:"
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "garbage"'
assert_exit 3 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "unknown    Free space on /: df couldn't read it"
# Spaces in the mount point and the filesystem name (macOS's automounter)
df_lines "map auto_home $((100 * GIB)) $((10 * GIB)) $((90 * GIB)) 11% /Volumes/My Disk"
assert_exit 0 diag status_disk_space "/Volumes/My Disk"
assert_contains "$RUN_OUTPUT" "ok         Free space on /Volumes/My Disk: 90.0 GiB of 100.0 GiB (90%)"
# APFS volumes share their container's space, so Used + Available < size
df_lines "/dev/disk3s5   $((994 * GIB))  $((600 * GIB)) $((380 * GIB))    62%    /System/Volumes/Data"
assert_exit 0 diag status_disk_space "$HOME"
assert_contains "$RUN_OUTPUT" "ok         Free space on /System/Volumes/Data: 380.0 GiB of 994.0 GiB (38%)"
read_only

# --- the ubuntu step: SMART ---
load_script ubuntu/install.sh
ubuntu_sandbox_paths
as_os ubuntu
replace_fn in_vm false
stub_sudo_exec '[ "$1" == -n ] || { echo "sudo asked for a password" >&2; exit 1; }
[ -e "'"$SANDBOX"'/sudo-cached" ] || { echo "sudo: a password is required" >&2; exit 1; }'
touch "$SANDBOX/sudo-cached"
# HEADER's serial number mustn't reach the report
mkdir -p "$SANDBOX/smart"
stub smartctl 'dir="'"$SANDBOX"'"
if [ "$1" == --scan ]; then
    [ ! -e "$dir/scan-fails" ] || exit 2
    while read -r dev type; do echo "$dev -d $type # $dev, $type device"; done < "$dir/disks"
    exit 0
fi
name="${!#}"; name="${name##*/}"
cat "$dir/smart/$name"
exit "$(cat "$dir/smart/$name.status" 2> /dev/null || echo 0)"'
disk() {
    echo "/dev/$1 $2" >> "$SANDBOX/disks"
    printf '%b' "$3" > "$SANDBOX/smart/$1"
    echo "${4:-0}" > "$SANDBOX/smart/$1.status"
}
HEADER='smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.17.0] (local build)\nSerial Number:    S6B0NX0T123456\n\n=== START OF READ SMART DATA SECTION ===\n'

: > "$SANDBOX/disks"
disk nvme0 nvme "${HEADER}SMART overall-health self-assessment test result: PASSED\n"
disk sda sat "${HEADER}SMART overall-health self-assessment test result: PASSED\n"
disk sdb scsi "${HEADER}SMART Health Status: OK\n"
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "ok         Disk health (SMART) of /dev/nvme0: PASSED"
assert_contains "$RUN_OUTPUT" "ok         Disk health (SMART) of /dev/sda: PASSED"
assert_contains "$RUN_OUTPUT" "ok         Disk health (SMART) of /dev/sdb: OK"
assert_not_contains "$RUN_OUTPUT" "S6B0NX0T123456"
# Health only, via sudo -n, without waking a disk in standby
assert_file_contains "$STUB_LOG" "sudo -n $STUB_DIR/smartctl -H -n standby -d sat /dev/sda"
assert_file_contains "$STUB_LOG" "sudo -n $STUB_DIR/smartctl -H -n standby -d nvme /dev/nvme0"
read_only

# A past threshold crossing or log errors are ok
: > "$SANDBOX/disks"
disk sda sat "${HEADER}SMART overall-health self-assessment test result: FAILED!\nDrive failure expected in less than 24 hours. SAVE ALL DATA.\n" 24
disk sdb sat "${HEADER}SMART overall-health self-assessment test result: PASSED\n" 16
disk sdc sat "${HEADER}SMART overall-health self-assessment test result: PASSED\n" 96
assert_exit 3 diag status_smart
assert_contains "$RUN_OUTPUT" "missing    Disk health (SMART) of /dev/sda: FAILED"
assert_contains "$RUN_OUTPUT" "back up"
assert_contains "$RUN_OUTPUT" "missing    Disk health (SMART) of /dev/sdb: a prefailure attribute is at or below its threshold"
assert_contains "$RUN_OUTPUT" "ok         Disk health (SMART) of /dev/sdc: PASSED, but an attribute was at or below its threshold before, and its error log has errors"
assert_not_contains "$RUN_OUTPUT" "S6B0NX0T123456"

: > "$SANDBOX/disks"
disk sda sat "${HEADER}Device is in STANDBY mode, exit(2)\n" 2
disk sdb sat "${HEADER}SMART support is: Unavailable - device lacks SMART capability.\n" 4
disk sdc sat "Smartctl open device: /dev/sdc failed: No such device\n" 2
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART) of /dev/sda: in standby"
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART) of /dev/sdb: it doesn't report SMART health"
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART) of /dev/sdc: smartctl couldn't open it"

: > "$SANDBOX/disks"
disk sda sat "something unexpected\n"
assert_exit 3 diag status_smart
assert_contains "$RUN_OUTPUT" "unknown    Disk health (SMART) of /dev/sda: couldn't read smartctl's output"
# A kill's 137 has bit 8 set, but isn't smartctl's
: > "$SANDBOX/disks"
disk sda sat "" 137
assert_exit 3 diag status_smart
assert_contains "$RUN_OUTPUT" "unknown    Disk health (SMART) of /dev/sda: smartctl didn't run (exit 137)"
: > "$SANDBOX/disks"
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART): smartctl found no disks"
touch "$SANDBOX/scan-fails"
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART): smartctl couldn't list the disks"
rm "$SANDBOX/scan-fails"
read_only

disk sda sat "${HEADER}SMART overall-health self-assessment test result: PASSED\n"
rm "$SANDBOX/sudo-cached"
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART): reading it needs root"
assert_file_not_contains "$STUB_LOG" "smartctl"
# A sudoers rule may refuse smartctl alone
stub sudo '[ "$1" == -n ] || exit 1
[ "$2" == true ] || { echo "Sorry, user me is not allowed to execute smartctl" >&2; exit 1; }'
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART)"
assert_not_contains "$RUN_OUTPUT" "missing"
read_only
replace_fn in_vm true
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "skipped    Disk health (SMART): this is a VM"
assert_file_not_contains "$STUB_LOG" "smartctl"
replace_fn in_vm false
read_only

# --- the ubuntu step: firmware ---
# fwupdmgr would start a stopped fwupd over D-Bus
stub systemctl '[ "$*" != "is-active --quiet fwupd.service" ] || [ ! -e "'"$SANDBOX"'/fwupd-inactive" ]'
stub fwupdmgr
touch "$SANDBOX/fwupd-inactive"
: > "$STUB_LOG"
assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "info       Firmware updates: fwupd isn't running, and status doesn't start it"
assert_file_not_contains "$STUB_LOG" "fwupdmgr"
rm "$SANDBOX/fwupd-inactive"
: > "$STUB_LOG"
DOTFILES_STATUS_QUICK=1 assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "unverified Firmware updates: skipped by --quick"
assert_file_not_contains "$STUB_LOG" "fwupdmgr"
firmware_without_fwupd() {
    hide fwupdmgr
    assert_exit 0 diag status_firmware
    assert_contains "$RUN_OUTPUT" "skipped    Firmware updates: fwupd isn't installed"
}
subtest firmware_without_fwupd
read_only

stub apt-get
stub lsblk
ubuntu_report() {
    hide tailscale nmcli
    replace_fn ufw_enabled false
    run status
    assert_file_contains "$STUB_LOG" "df -P -k /"
    assert_file_contains "$STUB_LOG" "df -P -k $HOME"
    assert_file_contains "$STUB_LOG" "df -P -k /var"
    assert_contains "$RUN_OUTPUT" "Disk health (SMART)"
    assert_contains "$RUN_OUTPUT" "Firmware updates"
    read_only
    # --quick still runs the firewall checks
    replace_fn ufw_enabled true
    replace_fn apt_installed true
    SSHD_RUN_DIR="$SANDBOX/run-sshd"
    mkdir -p "$SSHD_RUN_DIR"
    DOTFILES_STATUS_QUICK=1 run status
    assert_contains "$RUN_OUTPUT" "Disk health (SMART)"
    assert_contains "$RUN_OUTPUT" "ufw rules allowing SSH"
    read_only
}
subtest ubuntu_report
test_done
