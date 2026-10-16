#!/bin/bash
# The steps' functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The read-only diagnostics in the status reports: free space on both OSes, the PAM modules
# sudo_local loads, FileVault, and the application firewall in the macos step, SMART health and
# firmware updates in the ubuntu step, and Docker's disk usage in the docker step. Failing SMART
# health, low free space, a PAM module that's gone, and unknown results need attention; FileVault,
# the firewall, firmware, and Docker's usage are information. df, sudo, smartctl, fwupdmgr,
# fdesetup, socketfilterfw, systemctl, and docker are stubs, and the checks below prove status asks
# for no password, starts no service, and refreshes, prunes, or wakes nothing.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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

# --- the informational state ---
# info carries a value, such as FileVault being off, and doesn't need attention
report() {
    local state
    for state in "$@"; do
        status_item "$state" "item"
    done
    status_result
}
assert_exit 0 report ok info skipped
assert_contains "$RUN_OUTPUT" "  info       item"

# --- run_bounded ---
# It stops a command that runs too long with 124, as timeout(1) does, also where there's no
# timeout(1), as on macOS, and passes on another command's status and output
assert_exit 124 run_bounded 1 sleep 10
assert_exit 3 run_bounded 5 bash -c 'echo out; exit 3'
assert_eq out "$RUN_OUTPUT" "run_bounded's output"
(
    hide timeout
    start=$SECONDS
    assert_exit 124 run_bounded 1 sleep 10
    [ $((SECONDS - start)) -lt 5 ] || fail "run_bounded without timeout(1) waited out the command"
    assert_exit 3 run_bounded 5 bash -c 'echo out; exit 3'
    assert_eq out "$RUN_OUTPUT" "run_bounded's output without timeout(1)"
    # A slow command, such as a hung stub, exits 124 at the deadline
    stub slow 'exec sleep 30'
    start=$SECONDS
    assert_exit 124 run_bounded 1 slow
    [ $((SECONDS - start)) -lt 5 ] || fail "run_bounded without timeout(1) waited out a slow stub"
    # A command that exits 142 (SIGALRM's status) or 143 on its own, before the deadline, keeps it
    assert_exit 142 run_bounded 5 sh -c 'exit 142'
    assert_exit 143 run_bounded 5 sh -c 'kill -TERM $$'
    exit "$TEST_FAILURES"
) || TEST_FAILURES=$((TEST_FAILURES + $?))
# timeout(1) gets -k 5. It exits 137 when it sent SIGKILL, which run_bounded reports as 124, but a
# command killed before the deadline keeps its 137.
(
    stub timeout '[ "$1 $2" == "-k 5" ] || exit 99; [ "$3" -lt 2 ] || exit 137; sleep "$3"; exit 137'
    assert_exit 124 run_bounded 1 sleep 10
    assert_exit 137 run_bounded 5 sleep 10
    rm "$STUB_DIR/timeout"
    exit "$TEST_FAILURES"
) || TEST_FAILURES=$((TEST_FAILURES + $?))

# --- free space (status_disk_space), on both OSes ---
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
# A mount point with spaces, and a BSD filesystem name with one (macOS's automounter)
df_lines "map auto_home $((100 * GIB)) $((10 * GIB)) $((90 * GIB)) 11% /Volumes/My Disk"
assert_exit 0 diag status_disk_space "/Volumes/My Disk"
assert_contains "$RUN_OUTPUT" "ok         Free space on /Volumes/My Disk: 90.0 GiB of 100.0 GiB (90%)"
# macOS's df -P, which aligns its columns with runs of spaces: APFS volumes share their
# container's free space, so Used + Available is less than the size, and Capacity is Used's share
# of the two
df_lines "/dev/disk3s5   $((994 * GIB))  $((600 * GIB)) $((380 * GIB))    62%    /System/Volumes/Data"
assert_exit 0 diag status_disk_space "$HOME"
assert_contains "$RUN_OUTPUT" "ok         Free space on /System/Volumes/Data: 380.0 GiB of 994.0 GiB (38%)"
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

# --- the macos step ---
export DOTFILES_PAM_DIR="$SANDBOX/pam.d"
load_script macos/install.sh
is_macos() { true; }
# test-macos-hostname.sh covers the hostname
stub scutil 'echo Garvits-MacBook-Pro'
# Only the macos step's own functions: none of the Touch ID script's, such as usage and
# write_sudo_local
assert_eq "" "$(declare -F usage write_sudo_local || true)" "the Touch ID script's functions"
SUDO_LOCAL="$DOTFILES_PAM_DIR/sudo_local"
# The root-owned copy sudo loads, which in the sandbox is yours
REATTACH="$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_reattach.so"
# shellcheck disable=SC2034 # macos/pam.sh reads it
PAM_ROOT_UID="$(id -u)"
HEADER="# sudo_local: local config file which survives system update and is included for sudo"
TID_LINE="auth       sufficient     pam_tid.so"
stub brew '[ "$1" != --prefix ] || echo "$(dirname "$STUB_LOG")/brew"'
mkdir -p "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR"
printf '%s\n' "auth       include        sudo_local" "auth       required       pam_opendirectory.so" > "$DOTFILES_PAM_DIR/sudo"
# macOS ships its own modules with .2, which OpenPAM finds for a bare name
touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"

# PAM: Touch ID off is an option, so the macos step skips it
assert_exit 0 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "skipped    Touch ID for sudo: off"
assert_contains "$RUN_OUTPUT" "just touch-id"
echo "$HEADER" > "$SUDO_LOCAL"
assert_exit 0 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "skipped    Touch ID for sudo: off"
# On, as just touch-id writes it
mkdir -p "$(dirname "$REATTACH")"
touch "$REATTACH"
chmod 755 "$(dirname "$REATTACH")"
chmod 444 "$REATTACH"
printf '%s\n' "$HEADER" "auth       optional       $REATTACH ignore_ssh" "$TID_LINE" > "$SUDO_LOCAL"
assert_exit 0 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
# A module it loads that's gone, such as after brew bundle cleanup, needs attention, without
# claiming sudo always fails, and leads with the fix that needs no sudo
rm "$REATTACH"
assert_exit 3 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads $REATTACH, which doesn't exist"
assert_contains "$RUN_OUTPUT" "run brew install pam-reattach, then just touch-id"
assert_contains "$RUN_OUTPUT" "sudo may fail"
# A bare name that isn't there, such as a module a newer macOS dropped, needs attention too
printf '%s\n' "$HEADER" "$TID_LINE" > "$SUDO_LOCAL"
rm "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
assert_exit 3 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads $DOTFILES_PAM_MODULES_DIR/pam_tid.so, which doesn't exist"
touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
# Another module's path, also missing, and a file just touch-id would rewrite
printf '%s\n' "auth       sufficient     /usr/local/lib/pam/pam_watchid.so" "$TID_LINE" > "$SUDO_LOCAL"
assert_exit 3 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads /usr/local/lib/pam/pam_watchid.so, which doesn't exist"
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: $SUDO_LOCAL differs"
assert_not_contains "$RUN_OUTPUT" "pam-reattach"
# A sudo_local it can't read is unverified. Skipped as root, which reads any file.
chmod 000 "$SUDO_LOCAL"
if [ ! -r "$SUDO_LOCAL" ]; then
    assert_exit 0 diag status_touch_id skipped
    assert_contains "$RUN_OUTPUT" "unverified Touch ID for sudo: $SUDO_LOCAL isn't readable"
fi
chmod 644 "$SUDO_LOCAL"
# The sudo_local isn't touched, and the module isn't put back
assert_eq "auth       sufficient     /usr/local/lib/pam/pam_watchid.so
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local"
[ ! -e "$REATTACH" ] || fail "status put the module back"

# FileVault: on and off are information; needing more privilege is unverified; other output
# (another macOS's wording, or a failure) is information that says it couldn't tell
filevault() {
    stub fdesetup "[ \"\$1\" == status ] || exit 1
printf '%b' '$1'
exit ${2:-0}"
}
filevault 'FileVault is On.\n'
assert_exit 0 diag status_filevault
assert_contains "$RUN_OUTPUT" "info       FileVault: on"
filevault 'FileVault is On.\nEncryption in progress: Percent completed = 40\n'
assert_exit 0 diag status_filevault
assert_contains "$RUN_OUTPUT" "info       FileVault: on, encryption in progress"
filevault 'FileVault is Off.\n'
assert_exit 0 diag status_filevault
assert_contains "$RUN_OUTPUT" "info       FileVault: off"
filevault 'This tool needs to be run as root.\n' 1
assert_exit 0 diag status_filevault
assert_contains "$RUN_OUTPUT" "unverified FileVault"
assert_contains "$RUN_OUTPUT" "sudo fdesetup status"
filevault 'FileVault status: something new\n'
assert_exit 0 diag status_filevault
assert_contains "$RUN_OUTPUT" "info       FileVault: couldn't tell from fdesetup status"
filevault 'Error: something broke\n' 1
assert_exit 0 diag status_filevault
assert_contains "$RUN_OUTPUT" "info       FileVault: couldn't tell from fdesetup status"
assert_file_not_contains "$STUB_LOG" "sudo"

# The application firewall: the same, read with socketfilterfw --getglobalstate
firewall() {
    stub socketfilterfw "[ \"\$1\" == --getglobalstate ] || exit 1
printf '%b' '$1'
exit ${2:-0}"
}
firewall 'Firewall is enabled. (State = 1)\n'
assert_exit 0 diag status_app_firewall
assert_contains "$RUN_OUTPUT" "info       Application firewall: on"
firewall 'Firewall is blocking all non-essential incoming connections. (State = 2)\n'
assert_exit 0 diag status_app_firewall
assert_contains "$RUN_OUTPUT" "info       Application firewall: on, blocking all incoming connections"
firewall 'Firewall is disabled. (State = 0)\n'
assert_exit 0 diag status_app_firewall
assert_contains "$RUN_OUTPUT" "info       Application firewall: off"
firewall 'Must be root to change settings.\n' 1
assert_exit 0 diag status_app_firewall
assert_contains "$RUN_OUTPUT" "unverified Application firewall"
firewall 'Something else entirely\n'
assert_exit 0 diag status_app_firewall
assert_contains "$RUN_OUTPUT" "info       Application firewall: couldn't tell"
# It isn't on PATH on macOS: the step finds it in /usr/libexec/ApplicationFirewall
(
    hide socketfilterfw
    APP_FIREWALL_DIR="$SANDBOX/alf"
    mkdir -p "$APP_FIREWALL_DIR"
    cp "$STUB_DIR/fdesetup" "$APP_FIREWALL_DIR/socketfilterfw"
    assert_eq "$APP_FIREWALL_DIR/socketfilterfw" "$(firewall_cmd)" "socketfilterfw's path"
    exit "$TEST_FAILURES"
) || TEST_FAILURES=$((TEST_FAILURES + $?))
read_only

# The whole report: the diagnostics are in it, and only low space needs attention
default_matches() { true; }
spotlight_shortcut_off() { true; }
mkdir -p "$HOME/Screenshots"
rm "$SUDO_LOCAL"
filevault 'FileVault is Off.\n'
firewall 'Firewall is disabled. (State = 0)\n'
df_lines "/dev/disk3s5 $((994 * GIB)) $((600 * GIB)) $((380 * GIB)) 62% /System/Volumes/Data"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    Touch ID for sudo"
assert_contains "$RUN_OUTPUT" "info       FileVault: off"
assert_contains "$RUN_OUTPUT" "info       Application firewall: off"
assert_contains "$RUN_OUTPUT" "ok         Free space on /System/Volumes/Data"
df_lines "/dev/disk3s5 $((994 * GIB)) $((990 * GIB)) $((4 * GIB)) 100% /System/Volumes/Data"
assert_exit 3 status
read_only
# The whole report under --quick, with Touch ID on, is read-only too
printf '%s\n' "$HEADER" "$TID_LINE" > "$SUDO_LOCAL"
DOTFILES_STATUS_QUICK=1 run status
assert_contains "$RUN_OUTPUT" "Touch ID for sudo, in $SUDO_LOCAL"
read_only
rm "$SUDO_LOCAL"
# On Ubuntu the step is skipped, and checks none of it
is_macos() { false; }
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    macOS defaults: macOS only"
assert_not_contains "$RUN_OUTPUT" "FileVault"
assert_file_not_contains "$STUB_LOG" "fdesetup"
assert_file_not_contains "$STUB_LOG" "socketfilterfw"
assert_file_not_contains "$STUB_LOG" "df"
unset DOTFILES_PAM_DIR

# --- the ubuntu step: SMART ---
load_script ubuntu/install.sh
is_ubuntu() { true; }
in_vm() { false; }
# The system dirs sbin_cmd searches, here the stubs
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$STUB_DIR"
# sudo -n runs a command when $SANDBOX/sudo-cached exists, and fails without asking otherwise
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
PATH="$HOME/.cargo/bin:$PATH" run smartctl_cmd
assert_eq "$STUB_DIR/smartctl" "$RUN_OUTPUT" "the smartctl chosen"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$SANDBOX/no-such-dir"
PATH="$HOME/.cargo/bin:$PATH" run smartctl_cmd
assert_eq 1 "$RUN_STATUS" "smartctl_cmd's exit status with smartctl only on PATH: $RUN_OUTPUT"
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
smartctl_cmd() { return 1; }
assert_exit 3 diag status_smart
assert_contains "$RUN_OUTPUT" "unknown    Disk health (SMART): smartctl isn't installed"
assert_contains "$RUN_OUTPUT" "smartmontools"
unset -f smartctl_cmd
load_script ubuntu/install.sh
is_ubuntu() { true; }
in_vm() { false; }
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$STUB_DIR"
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
FWUPD_METADATA_DIRS="$SANDBOX/fwupd-metadata"
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
(
    hide jq
    fwupd '{ "Devices" : [ { "Name" : "Disk", "Version" : "1", "Releases" : [ { "Version" : "2" } ] } ] }\n'
    assert_exit 0 diag status_firmware
    assert_contains "$RUN_OUTPUT" "info       Firmware updates: couldn't read fwupdmgr's JSON without jq"
    exit "$TEST_FAILURES"
) || TEST_FAILURES=$((TEST_FAILURES + $?))
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
(
    hide fwupdmgr
    assert_exit 0 diag status_firmware
    assert_contains "$RUN_OUTPUT" "skipped    Firmware updates: fwupd isn't installed"
    exit "$TEST_FAILURES"
) || TEST_FAILURES=$((TEST_FAILURES + $?))
read_only

# The ubuntu step's report has free space for /, ~, and /var, SMART, and firmware. apt-get -s
# upgrade, for the packages apt holds back, holds none back.
stub apt-get
(
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
    exit "$TEST_FAILURES"
) || TEST_FAILURES=$((TEST_FAILURES + $?))

# --- the docker step: disk usage ---
load_script docker/install.sh
is_macos() { false; }
# docker.service is active unless $SANDBOX/docker-inactive exists; docker.socket always is
stub systemctl 'case "$*" in
    "is-active --quiet docker.service") [ ! -e "'"$SANDBOX"'/docker-inactive" ] ;;
    *docker.socket*) exit 0 ;;
    *) exit 1 ;;
esac'
# docker system df prints $SANDBOX/docker-df and exits with $SANDBOX/docker-df.status
stub docker '[ "$1 $2" == "system df" ] || exit 1
cat "'"$SANDBOX"'/docker-df"
exit "$(cat "'"$SANDBOX"'/docker-df.status")"'
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
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage"
assert_contains "$RUN_OUTPUT" "docker group"
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
# The docker step's report includes it once Docker is installed
docker_installed() { true; }
status_apt_source() { :; }
docker_df 'Images\t1\t1GB\t0B\n'
run status
assert_contains "$RUN_OUTPUT" "info       Docker disk usage: images 1, 1GB"
DOTFILES_STATUS_QUICK=1 run status
assert_contains "$RUN_OUTPUT" "unverified Docker disk usage: skipped by --quick"
read_only
docker_installed() { false; }
run status
assert_not_contains "$RUN_OUTPUT" "Docker disk usage"
read_only
test_done
