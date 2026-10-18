#!/bin/bash
# The steps' functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail
# os: macos

# The read-only diagnostics in the macos step's status report: free space as macOS's df prints it,
# the PAM modules sudo_local loads, FileVault, and the application firewall, and run_bounded
# without timeout(1), as on macOS. A PAM module that's gone needs attention; FileVault and the
# firewall are information. df, fdesetup, and socketfilterfw are stubs, and the checks below prove
# status asks sudo for no password.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

# Fail when a status run asked sudo for a password
read_only() {
    if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
        fail "status ran sudo without -n:"
        _show "$(grep '^sudo' "$STUB_LOG")"
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

# --- run_bounded without timeout(1) ---
# It stops a command that runs too long with 124, and passes on another command's status and
# output
run_bounded_without_timeout() {
    local start=$SECONDS
    hide timeout
    assert_exit 124 run_bounded 1 sleep 10
    [ $((SECONDS - start)) -lt 5 ] || fail "run_bounded without timeout(1) waited out the command"
    assert_exit 3 run_bounded 5 bash -c 'echo out; exit 3'
    assert_eq out "$RUN_OUTPUT" "run_bounded's output without timeout(1)"
    # A command that exits 142 (SIGALRM's status) or 143 on its own, before the deadline, keeps it
    assert_exit 142 run_bounded 5 sh -c 'exit 142'
    assert_exit 143 run_bounded 5 sh -c 'kill -TERM $$'
}
subtest run_bounded_without_timeout

# --- free space (status_disk_space) ---
# df_lines <line>...: df -P -k prints the header, then the first line whose mount point is the path
# it's given, or the first line when none is
df_lines() {
    printf '%s\n' "$@" > "$SANDBOX/df-table"
    stub df 'path="${!#}"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
line="$(grep -F " $path" "'"$SANDBOX"'/df-table" | head -n 1)"
[ -n "$line" ] || line="$(head -n 1 "'"$SANDBOX"'/df-table")"
echo "$line"'
}
GIB=1048576
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
read_only

# test-macos-hostname.sh covers the hostname
stub scutil 'echo Garvits-MacBook-Pro'

# --- the macos step ---
export DOTFILES_PAM_DIR="$SANDBOX/pam.d"
load_script macos/install.sh
is_macos() { true; }
# Only the macos step's own functions: none of the Touch ID script's, such as usage and
# install_reattach_module
assert_eq "" "$(declare -F usage install_reattach_module || true)" "the Touch ID script's functions"
SUDO_LOCAL="$DOTFILES_PAM_DIR/sudo_local"
# The root-owned copy sudo loads, which in the sandbox is yours
REATTACH="$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_reattach.so"
# shellcheck disable=SC2034 # macos/pam.sh reads them
PAM_ROOT_UID="$(id -u)" PAM_TRUSTED_DIR="$SANDBOX"
HEADER="# sudo_local: local config file which survives system update and is included for sudo"
TID_LINE="auth       sufficient     pam_tid.so"
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
firewall_off_path() {
    hide socketfilterfw
    APP_FIREWALL_DIR="$SANDBOX/alf"
    mkdir -p "$APP_FIREWALL_DIR"
    cp "$STUB_DIR/fdesetup" "$APP_FIREWALL_DIR/socketfilterfw"
    assert_eq "$APP_FIREWALL_DIR/socketfilterfw" "$(firewall_cmd)" "socketfilterfw's path"
}
subtest firewall_off_path
read_only

# The whole report: the diagnostics are in it, and none needs attention
default_matches() { true; }
hotkey_off() { true; }
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
read_only
# The whole report under --quick, with Touch ID on, is read-only too
printf '%s\n' "$HEADER" "$TID_LINE" > "$SUDO_LOCAL"
DOTFILES_STATUS_QUICK=1 run status
assert_contains "$RUN_OUTPUT" "Touch ID for sudo, in $SUDO_LOCAL"
read_only
test_done
