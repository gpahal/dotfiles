#!/bin/bash
# The steps' functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail
# os: ubuntu

# The read-only diagnostics in the ubuntu and docker steps' status reports: free space, SMART
# health, firmware updates, and Docker's disk usage, and run_bounded with timeout(1). Failing SMART
# health, low free space, and unknown results need attention; firmware and Docker's usage are
# information. df, sudo, smartctl, fwupdmgr, systemctl, and docker are stubs, and the checks below
# prove status asks for no password, starts no service, and refreshes, prunes, or wakes nothing.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox
load_script lib/common.sh
# The ubuntu step's status reads apt's periodic settings
stub_apt_config 'echo "APT::Periodic::Update-Package-Lists \"1\";"
echo "APT::Periodic::Unattended-Upgrade \"1\";"'

# Fail when a status run did something it mustn't: asked sudo for a password, started or
# restarted a unit, refreshed fwupd's metadata or installed firmware, ran a SMART self-test, or
# pruned, stopped, or started anything in Docker
read_only() {
    local log
    log="$(cat "$STUB_LOG")"
    if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
        fail "status ran sudo without -n:"
        _show "$(grep '^sudo' "$STUB_LOG")"
    fi
    if grep -qE '^systemctl ([^ ]+ )*(start|restart|try-restart|reload|enable|stop)( |$)|^fwupdmgr (refresh|update|install|upgrade)|^smartctl .*( -t | --test)|^docker ([^ ]+ )*(prune|stop|start|rm|kill)( |$)' <<< "$log"; then
        fail "status changed something:"
        _show "$log"
    fi
    : > "$STUB_LOG"
}

# Run one diagnostic, and exit as the status report would: 3 when it needs attention
diag() {
    "$@"
    status_result
}

# --- run_bounded with timeout(1) ---
# It stops a command that runs too long with 124, as timeout(1) does, and passes on another
# command's status and output
assert_exit 124 run_bounded 1 sleep 10
assert_exit 3 run_bounded 5 bash -c 'echo out; exit 3'
assert_eq out "$RUN_OUTPUT" "run_bounded's output"
# timeout(1) gets -k 5. It exits 137 when it sent SIGKILL, which run_bounded reports as 124, but a
# command killed before the deadline keeps its 137.
run_bounded_killed() {
    stub timeout '[ "$1 $2" == "-k 5" ] || exit 99; [ "$3" -lt 2 ] || exit 137; sleep "$3"; exit 137'
    assert_exit 124 run_bounded 1 sleep 10
    assert_exit 137 run_bounded 5 sleep 10
    rm "$STUB_DIR/timeout"
}
subtest run_bounded_killed

# --- free space (status_disk_space) ---
# df_lines <line>...: df -P -k prints the header, then the first line whose mount point is the path
# it's given, or the first line when none is. A path in $SANDBOX/df-fails makes it fail.
df_lines() {
    printf '%s\n' "$@" > "$SANDBOX/df-table"
    : > "$SANDBOX/df-fails"
    stub df 'path="${!#}"
! grep -qxF -- "$path" "'"$SANDBOX"'/df-fails" || { echo "df: $path: No such file or directory" >&2; exit 1; }
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
line="$(grep -F " $path" "'"$SANDBOX"'/df-table" | head -n 1)"
[ -n "$line" ] || line="$(head -n 1 "'"$SANDBOX"'/df-table")"
echo "$line"'
}
GIB=1048576
# A normal filesystem is ok, with its size, free space, and percentage
df_lines "/dev/sda2 $((500 * GIB)) $((380 * GIB)) $((120 * GIB)) 76% /"
assert_exit 0 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "ok         Free space on /: 120.0 GiB of 500.0 GiB (24%)"
assert_file_contains "$STUB_LOG" "df -P -k /"
# A full one, and one under 10% or under 10 GiB free, need attention
df_lines "/dev/sda2 $((500 * GIB)) $((500 * GIB)) 0 100% /"
assert_exit 3 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "missing    Free space on /: 0.0 GiB of 500.0 GiB (0%)"
assert_contains "$RUN_OUTPUT" "under 10% or 10 GiB"
df_lines "/dev/sda2 $((2000 * GIB)) $((1850 * GIB)) $((150 * GIB)) 93% /"
assert_exit 3 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "missing    Free space on /: 150.0 GiB of 2000.0 GiB (7%)"
df_lines "/dev/vda1 $((40 * GIB)) $((31 * GIB)) $((9 * GIB)) 78% /"
assert_exit 3 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "missing    Free space on /: 9.0 GiB of 40.0 GiB (22%)"
# Exactly at the floor is enough
df_lines "/dev/vda1 $((100 * GIB)) $((90 * GIB)) $((10 * GIB)) 90% /"
assert_exit 0 diag status_disk_space /
# Paths on the same filesystem, or on a bind mount of it, get one item
df_lines "/dev/sda2 $((500 * GIB)) $((380 * GIB)) $((120 * GIB)) 76% /" \
    "/dev/sda2 $((500 * GIB)) $((380 * GIB)) $((120 * GIB)) 76% /srv/bind" \
    "/dev/sdb1 $((900 * GIB)) $((100 * GIB)) $((800 * GIB)) 12% /home"
assert_exit 0 diag status_disk_space / /srv/bind /home
assert_eq 2 "$(grep -c 'Free space on' <<< "$RUN_OUTPUT")" "items for two filesystems"
assert_contains "$RUN_OUTPUT" "ok         Free space on /home: 800.0 GiB of 900.0 GiB (88%)"
# A path df can't read is unknown, and the others are still reported
echo /gone > "$SANDBOX/df-fails"
assert_exit 3 diag status_disk_space /gone /
assert_contains "$RUN_OUTPUT" "unknown    Free space on /gone: df couldn't read it"
assert_contains "$RUN_OUTPUT" "ok         Free space on /:"
# Output df can't have printed is unknown
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "garbage"'
assert_exit 3 diag status_disk_space /
assert_contains "$RUN_OUTPUT" "unknown    Free space on /: df couldn't read it"
read_only

# --- the ubuntu step: SMART ---
# sbin_cmd searches only the stubs
load_script ubuntu/install.sh
ubuntu_sandbox_paths
is_ubuntu() { true; }
in_vm() { false; }
# sudo -n runs a command when $SANDBOX/sudo-cached exists, and fails without asking otherwise.
# Not stub_sudo_exec, which would refuse the disks' /dev paths; smartctl, the only command it
# runs here, is a stub.
stub sudo '[ "$1" == -n ] || { echo "sudo asked for a password" >&2; exit 1; }
[ -e "'"$SANDBOX"'/sudo-cached" ] || { echo "sudo: a password is required" >&2; exit 1; }
shift
exec "$@"'
touch "$SANDBOX/sudo-cached"
# smartctl --scan lists $SANDBOX/disks, one "<device> <type>" per line. smartctl -H prints
# $SANDBOX/smart/<name> and exits with $SANDBOX/smart/<name>.status. The output includes a serial
# number, which the report mustn't show.
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

# smartctl runs under sudo, so it comes only from the system dirs in SBIN_PATH, never from the
# user's PATH, where a smartctl planted in a dir such as ~/.cargo/bin would run as root
mkdir -p "$HOME/.cargo/bin"
printf '#!/bin/bash\n' > "$HOME/.cargo/bin/smartctl"
chmod +x "$HOME/.cargo/bin/smartctl"
PATH="$HOME/.cargo/bin:$PATH" run sbin_cmd smartctl
assert_eq "$STUB_DIR/smartctl" "$RUN_OUTPUT" "the smartctl chosen"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$SANDBOX/no-such-dir"
PATH="$HOME/.cargo/bin:$PATH" run sbin_cmd smartctl
assert_eq 1 "$RUN_STATUS" "sbin_cmd's exit status with smartctl only on PATH: $RUN_OUTPUT"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$STUB_DIR"
rm "$HOME/.cargo/bin/smartctl"

: > "$SANDBOX/disks"
disk nvme0 nvme "${HEADER}SMART overall-health self-assessment test result: PASSED\n"
disk sda sat "${HEADER}SMART overall-health self-assessment test result: PASSED\n"
disk sdb scsi "${HEADER}SMART Health Status: OK\n"
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "ok         Disk health (SMART) of /dev/nvme0: PASSED"
assert_contains "$RUN_OUTPUT" "ok         Disk health (SMART) of /dev/sda: PASSED"
assert_contains "$RUN_OUTPUT" "ok         Disk health (SMART) of /dev/sdb: OK"
assert_not_contains "$RUN_OUTPUT" "S6B0NX0T123456"
# Only the health check, through sudo -n, without waking a disk in standby, and with each
# device's type from the scan
assert_file_contains "$STUB_LOG" "sudo -n $STUB_DIR/smartctl -H -n standby -d sat /dev/sda"
assert_file_contains "$STUB_LOG" "sudo -n $STUB_DIR/smartctl -H -n standby -d nvme /dev/nvme0"
read_only

# Failing health, or a prefailure attribute at its threshold now, needs attention. One past its
# threshold earlier, or errors in the log, is ok and says so.
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

# A disk in standby isn't woken, and an unsupported device or one that won't open is unverified;
# none needs attention
: > "$SANDBOX/disks"
disk sda sat "${HEADER}Device is in STANDBY mode, exit(2)\n" 2
disk sdb sat "${HEADER}SMART support is: Unavailable - device lacks SMART capability.\n" 4
disk sdc sat "Smartctl open device: /dev/sdc failed: No such device\n" 2
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART) of /dev/sda: in standby"
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART) of /dev/sdb: it doesn't report SMART health"
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART) of /dev/sdc: smartctl couldn't open it"

# Output with no health line is unknown
: > "$SANDBOX/disks"
disk sda sat "something unexpected\n"
assert_exit 3 diag status_smart
assert_contains "$RUN_OUTPUT" "unknown    Disk health (SMART) of /dev/sda: couldn't read smartctl's output"
# No disks, or a scan that fails, is unverified
: > "$SANDBOX/disks"
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART): smartctl found no disks"
touch "$SANDBOX/scan-fails"
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART): smartctl couldn't list the disks"
rm "$SANDBOX/scan-fails"
read_only

# Without cached sudo credentials it's unverified and runs no smartctl
disk sda sat "${HEADER}SMART overall-health self-assessment test result: PASSED\n"
rm "$SANDBOX/sudo-cached"
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART): reading it needs root; run sudo -v, then status, to check it"
assert_file_not_contains "$STUB_LOG" "smartctl"
# sudo -n that's refused for smartctl alone, as a sudoers rule may do, is unverified too
stub sudo '[ "$1" == -n ] || exit 1
[ "$2" == true ] || { echo "Sorry, user me is not allowed to execute smartctl" >&2; exit 1; }'
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "unverified Disk health (SMART)"
assert_not_contains "$RUN_OUTPUT" "missing"
read_only
# In a VM the host manages the disks
in_vm() { true; }
assert_exit 0 diag status_smart
assert_contains "$RUN_OUTPUT" "skipped    Disk health (SMART): this is a VM"
assert_file_not_contains "$STUB_LOG" "smartctl"
in_vm() { false; }
# Without smartctl, it's unknown and says what installs it
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$SANDBOX/no-such-dir"
assert_exit 3 diag status_smart
assert_contains "$RUN_OUTPUT" "unknown    Disk health (SMART): smartctl isn't installed"
assert_contains "$RUN_OUTPUT" "smartmontools"
load_script ubuntu/install.sh
ubuntu_sandbox_paths
is_ubuntu() { true; }
in_vm() { false; }
read_only

# --- the ubuntu step: firmware ---
# fwupd is running unless $SANDBOX/fwupd-inactive exists. fwupdmgr get-updates prints
# $SANDBOX/fwupd and exits with $SANDBOX/fwupd.status.
stub systemctl '[ "$*" != "is-active --quiet fwupd.service" ] || [ ! -e "'"$SANDBOX"'/fwupd-inactive" ]'
stub fwupdmgr '[ "$1" == get-updates ] || exit 1
cat "'"$SANDBOX"'/fwupd"
exit "$(cat "'"$SANDBOX"'/fwupd.status")"'
fwupd() {
    printf '%b' "$1" > "$SANDBOX/fwupd"
    echo "${2:-0}" > "$SANDBOX/fwupd.status"
}
mkdir -p "$FWUPD_METADATA_DIRS/lvfs"
touch "$FWUPD_METADATA_DIRS/lvfs/metadata.xml.zst"

# None, in fwupd 1.9's and 2.0's wording
fwupd 'Devices with no available firmware updates:\n • System Firmware\nNo updates available\n' 2
assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "info       Firmware updates: none available"
# JSON, which jq reads: the devices with a release, or none
if command -v jq &> /dev/null; then
    fwupd '{\n  "Devices" : [\n    {\n      "Name" : "System Firmware",\n      "Version" : "1.2.3",\n      "Releases" : [ { "Version" : "1.2.4" } ]\n    },\n    {\n      "Name" : "UEFI dbx",\n      "Version" : "371",\n      "Releases" : [ { "Version" : "377" } ]\n    }\n  ]\n}\n'
    assert_exit 0 diag status_firmware
    assert_contains "$RUN_OUTPUT" "info       Firmware updates: available for System Firmware (1.2.3 to 1.2.4), UEFI dbx (371 to 377)"
    assert_contains "$RUN_OUTPUT" "metadata from the last 30 days"
    assert_file_contains "$STUB_LOG" "fwupdmgr get-updates --json --no-unreported-check --no-metadata-check --no-reboot-check"
    # A warning before the JSON doesn't get in the way
    fwupd 'WARNING: something\n{ "Devices" : [ { "Name" : "Disk", "Version" : "1", "Releases" : [ { "Version" : "2" } ] } ] }\n'
    assert_exit 0 diag status_firmware
    assert_contains "$RUN_OUTPUT" "info       Firmware updates: available for Disk (1 to 2)"
    fwupd '{ "Devices" : [ { "Name" : "Disk", "Version" : "1", "Releases" : [] } ] }\n'
    assert_exit 0 diag status_firmware
    assert_contains "$RUN_OUTPUT" "info       Firmware updates: none available"
else
    skip_rest "jq isn't installed, so fwupdmgr's JSON can't be read"
fi
# Without jq it says it can't list them
firmware_without_jq() {
    hide jq
    fwupd '{ "Devices" : [ { "Name" : "Disk", "Version" : "1", "Releases" : [ { "Version" : "2" } ] } ] }\n'
    assert_exit 0 diag status_firmware
    assert_contains "$RUN_OUTPUT" "info       Firmware updates: couldn't read fwupdmgr's JSON without jq"
}
subtest firmware_without_jq
# No device fwupd supports
fwupd 'No updatable devices\n' 2
assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "info       Firmware updates: no device here that fwupd updates"
# Stale or missing metadata says so, and status doesn't refresh it
touch -t 202001010000 "$FWUPD_METADATA_DIRS/lvfs/metadata.xml.zst"
fwupd 'No updates available\n' 2
assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "metadata over 30 days old (fwupdmgr refresh updates it)"
rm "$FWUPD_METADATA_DIRS/lvfs/metadata.xml.zst"
assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "metadata of unknown age"
# A failure is information too
fwupd 'Failed to connect to daemon: Error calling StartServiceByName\n' 1
assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "info       Firmware updates: couldn't check (Failed to connect to daemon"
# fwupd that isn't running isn't started over D-Bus
touch "$SANDBOX/fwupd-inactive"
: > "$STUB_LOG"
assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "info       Firmware updates: fwupd isn't running, and status doesn't start it"
assert_file_not_contains "$STUB_LOG" "fwupdmgr"
rm "$SANDBOX/fwupd-inactive"
# --quick skips it
: > "$STUB_LOG"
DOTFILES_STATUS_QUICK=1 assert_exit 0 diag status_firmware
assert_contains "$RUN_OUTPUT" "unverified Firmware updates: skipped by --quick"
assert_file_not_contains "$STUB_LOG" "fwupdmgr"
# Without fwupd it's skipped
firmware_without_fwupd() {
    hide fwupdmgr
    assert_exit 0 diag status_firmware
    assert_contains "$RUN_OUTPUT" "skipped    Firmware updates: fwupd isn't installed"
}
subtest firmware_without_fwupd
read_only

# The ubuntu step's report has free space for /, ~, and /var, SMART, and firmware. apt-get -s
# upgrade, for the packages apt holds back, holds none back.
stub apt-get
ubuntu_report() {
    hide tailscale nmcli
    ufw_enabled() { false; }
    run status
    assert_file_contains "$STUB_LOG" "df -P -k /"
    assert_file_contains "$STUB_LOG" "df -P -k $HOME"
    assert_file_contains "$STUB_LOG" "df -P -k /var"
    assert_contains "$RUN_OUTPUT" "Disk health (SMART)"
    assert_contains "$RUN_OUTPUT" "Firmware updates"
    read_only
    # And under --quick, with sudo cached, sshd installed, and ufw on, so the firewall checks run
    ufw_enabled() { true; }
    apt_installed() { true; }
    SSHD_RUN_DIR="$SANDBOX/run-sshd"
    mkdir -p "$SSHD_RUN_DIR"
    DOTFILES_STATUS_QUICK=1 run status
    assert_contains "$RUN_OUTPUT" "Disk health (SMART)"
    assert_contains "$RUN_OUTPUT" "ufw rules allowing SSH"
    read_only
}
subtest ubuntu_report

# --- the docker step: disk usage, and ports published on every address ---
load_script docker/install.sh
is_macos() { false; }
# You're in the docker group while $SANDBOX/in-group exists. sudo -n runs a command while
# $SANDBOX/sudo-cached exists, and fails without asking otherwise.
stub id 'case "$1" in -un) echo me ;; -nG) [ -e "'"$SANDBOX"'/in-group" ] && echo "me docker" || echo me ;; esac'
touch "$SANDBOX/in-group"
stub_sudo_exec '[ "${1:-}" == -n ] || { echo "sudo asked for a password" >&2; exit 1; }
[ -e "'"$SANDBOX"'/sudo-cached" ] || { echo "sudo: a password is required" >&2; exit 1; }'
rm -f "$SANDBOX/sudo-cached"
# docker.service is active unless $SANDBOX/docker-inactive exists; docker.socket always is
stub systemctl 'case "$*" in
    "is-active --quiet docker.service") [ ! -e "'"$SANDBOX"'/docker-inactive" ] ;;
    *docker.socket*) exit 0 ;;
    *) exit 1 ;;
esac'
# docker system df and docker ps print $SANDBOX/docker-df and $SANDBOX/docker-ps, and exit with
# their .status files, 0 by default
stub docker 'case "$1 $2" in
    "system df") out=docker-df ;;
    "ps --format") out=docker-ps ;;
    *) exit 1 ;;
esac
cat "'"$SANDBOX"'/$out" 2> /dev/null
exit "$(cat "'"$SANDBOX"'/$out.status" 2> /dev/null || echo 0)"'
docker_df() {
    printf '%b' "$1" > "$SANDBOX/docker-df"
    echo "${2:-0}" > "$SANDBOX/docker-df.status"
}
# Docker 24's and 28's output: the reclaimable space with and without a percentage
docker_df 'Images\t12\t8.1GB\t3.2GB (39%)\nContainers\t3\t120MB\t0B (0%)\nLocal Volumes\t2\t1.5GB\t0B (0%)\nBuild Cache\t40\t2.3GB\t2.3GB\n'
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: images 12, 8.1GB (3.2GB reclaimable); containers 3, 120MB; local volumes 2, 1.5GB; build cache 40, 2.3GB (2.3GB reclaimable)"
assert_file_contains "$STUB_LOG" "docker system df --format"
docker_df 'Images\t0\t0B\t0B\nContainers\t0\t0B\t0B\nLocal Volumes\t0\t0B\t0B\nBuild Cache\t0\t0B\t0B\n'
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: images 0, 0B; containers 0, 0B; local volumes 0, 0B; build cache 0, 0B"
# Permission denied on the socket is unverified, and says why
docker_df 'permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock\n' 1
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage: me can't reach the daemon's socket yet; log out and back in"
# Outside the docker group, logging in again can't help: the check goes through sudo -n while sudo
# credentials are cached, and is unverified otherwise, without running docker
rm "$SANDBOX/in-group"
: > "$STUB_LOG"
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage: me isn't in the docker group; run sudo -v, then status, to check it"
assert_file_not_contains "$STUB_LOG" "docker system"
read_only
docker_df 'Images\t1\t1GB\t0B\n'
touch "$SANDBOX/sudo-cached"
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: images 1, 1GB"
assert_file_contains "$STUB_LOG" "sudo -n docker system df --format"
read_only
rm "$SANDBOX/sudo-cached"
touch "$SANDBOX/in-group"
# A daemon that went away, a failure, and output it can't read are information
docker_df 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n' 1
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: the daemon isn't running"
docker_df 'Error response from daemon: something broke\n' 1
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: couldn't check (Error response from daemon: something broke)"
docker_df 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\n'
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: couldn't read docker system df's output"
# A stopped daemon isn't started, though docker.socket would start it
touch "$SANDBOX/docker-inactive"
: > "$STUB_LOG"
assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: the daemon isn't running, and status doesn't start it"
assert_file_not_contains "$STUB_LOG" "docker system"
rm "$SANDBOX/docker-inactive"
# --quick skips it
: > "$STUB_LOG"
DOTFILES_STATUS_QUICK=1 assert_exit 0 diag status_docker_usage
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage: skipped by --quick"
assert_file_not_contains "$STUB_LOG" "docker system"
read_only
# Ports published on every address bypass ufw: status names each, with the container. Ones on
# 127.0.0.1 or another given address, and ports a container exposes without publishing, are fine.
printf '%b\n' 'web\t0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 127.0.0.1:9000->9000/tcp' \
    'db\t5432/tcp' 'old\t:::2222->22/tcp' 'local\t127.0.0.1:3000->3000/tcp, 192.168.1.5:53->53/udp' > "$SANDBOX/docker-ps"
: > "$STUB_LOG"
assert_exit 3 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "missing    Container ports published on every address, which ufw doesn't filter: web 0.0.0.0:8080->80/tcp, web [::]:8080->80/tcp, old :::2222->22/tcp; recreate each with -p 127.0.0.1:<port>:<container port>, or on a network created since the docker step ran"
assert_file_contains "$STUB_LOG" "docker ps --format {{.Names}}"
printf '%b\n' 'db\t5432/tcp' 'local\t127.0.0.1:3000->3000/tcp' > "$SANDBOX/docker-ps"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address"
: > "$SANDBOX/docker-ps"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address"
# The daemon out of reach without the docker group is unverified; another failure is unknown
echo 'permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock' > "$SANDBOX/docker-ps"
echo 1 > "$SANDBOX/docker-ps.status"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "unverified Container ports published on every address, which ufw doesn't filter: me can't reach the daemon's socket yet; log out and back in"
# Outside the docker group, it goes through sudo -n while sudo credentials are cached
rm "$SANDBOX/in-group"
: > "$STUB_LOG"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "unverified Container ports published on every address, which ufw doesn't filter: me isn't in the docker group; run sudo -v, then status, to check it"
assert_file_not_contains "$STUB_LOG" "docker ps"
read_only
printf '%b\n' 'web\t0.0.0.0:8080->80/tcp' > "$SANDBOX/docker-ps"
echo 0 > "$SANDBOX/docker-ps.status"
touch "$SANDBOX/sudo-cached"
assert_exit 3 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "missing    Container ports published on every address, which ufw doesn't filter: web 0.0.0.0:8080->80/tcp"
assert_file_contains "$STUB_LOG" "sudo -n docker ps --format"
read_only
rm "$SANDBOX/sudo-cached"
touch "$SANDBOX/in-group"
echo 1 > "$SANDBOX/docker-ps.status"
echo 'Error response from daemon: something broke' > "$SANDBOX/docker-ps"
assert_exit 3 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "unknown    Container ports published on every address, which ufw doesn't filter: couldn't list the containers (Error response from daemon: something broke)"
# A daemon that went away during the check, as a restart does, is information
echo 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' > "$SANDBOX/docker-ps"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "info       Container ports published on every address, which ufw doesn't filter: the daemon isn't running"
rm "$SANDBOX/docker-ps" "$SANDBOX/docker-ps.status"
# A stopped daemon isn't started. With no containerd shim running, it runs no containers. With one,
# live-restore kept containers running, whose ports can't be checked.
touch "$SANDBOX/docker-inactive"
# pgrep -f matches the shims' command lines in $SANDBOX/shims, as real pgrep does with ERE
stub pgrep '[ "$1" == -f ] && grep -qE -- "$2" "'"$SANDBOX"'/shims" 2> /dev/null'
: > "$STUB_LOG"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address, which ufw doesn't filter: the daemon isn't running"
assert_file_not_contains "$STUB_LOG" "docker ps"
# Another containerd client's shim, such as k3s's, isn't Docker's
echo "/usr/bin/containerd-shim-runc-v2 -namespace k8s.io -id abc -address /run/k3s/containerd/containerd.sock" > "$SANDBOX/shims"
assert_exit 0 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address"
echo "/usr/bin/containerd-shim-runc-v2 -namespace moby -id 032f -address /run/containerd/containerd.sock" >> "$SANDBOX/shims"
assert_exit 3 diag status_docker_ports
assert_contains "$RUN_OUTPUT" "unknown    Container ports published on every address, which ufw doesn't filter: containers are running while the Docker daemon is down, so their published ports can't be checked; start it with sudo systemctl start docker"
assert_file_not_contains "$STUB_LOG" "docker ps"
rm "$SANDBOX/docker-inactive" "$SANDBOX/shims"
read_only
# The docker step's report includes both once Docker is installed
docker_installed() { true; }
status_apt_source() { :; }
docker_df 'Images\t1\t1GB\t0B\n'
run status
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: images 1, 1GB"
assert_contains "$RUN_OUTPUT" "ok         No container ports published on every address"
DOTFILES_STATUS_QUICK=1 run status
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage: skipped by --quick"
read_only
docker_installed() { false; }
run status
assert_not_contains "$RUN_OUTPUT" "Docker disk usage"
read_only
test_done
