#!/bin/bash
set -euo pipefail
# os: macos

# The macos step's read-only status diagnostics, and run_bounded without timeout(1).

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

read_only() {
    if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
        fail "status ran sudo without -n:"
        _show "$(grep '^sudo' "$STUB_LOG")"
    fi
    : > "$STUB_LOG"
}

diag() {
    "$@"
    status_result
}

# info doesn't need attention
report() {
    local state
    for state in "$@"; do
        status_item "$state" "item"
    done
    status_result
}
assert_exit 0 report ok info skipped
assert_contains "$RUN_OUTPUT" "  info       item"

run_bounded_without_timeout() {
    local start=$SECONDS
    hide timeout
    assert_exit 124 run_bounded 1 sleep 10
    [ $((SECONDS - start)) -lt 5 ] || fail "run_bounded without timeout(1) waited out the command"
    assert_exit 3 run_bounded 5 bash -c 'echo out; exit 3'
    assert_eq out "$RUN_OUTPUT" "run_bounded's output without timeout(1)"
    # 142 (SIGALRM) or 143 from the command itself isn't a timeout
    assert_exit 142 run_bounded 5 sh -c 'exit 142'
    assert_exit 143 run_bounded 5 sh -c 'kill -TERM $$'
}
subtest run_bounded_without_timeout

df_lines() {
    printf '%s\n' "$@" > "$SANDBOX/df-table"
    stub df 'path="${!#}"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
line="$(grep -F " $path" "'"$SANDBOX"'/df-table" | head -n 1)"
[ -n "$line" ] || line="$(head -n 1 "'"$SANDBOX"'/df-table")"
echo "$line"'
}
GIB=1048576
# Spaces in the mount point and the filesystem name (macOS's automounter)
df_lines "map auto_home $((100 * GIB)) $((10 * GIB)) $((90 * GIB)) 11% /Volumes/My Disk"
assert_exit 0 diag status_disk_space "/Volumes/My Disk"
assert_contains "$RUN_OUTPUT" "ok         Free space on /Volumes/My Disk: 90.0 GiB of 100.0 GiB (90%)"
# APFS volumes share their container's space, so Used + Available < size
df_lines "/dev/disk3s5   $((994 * GIB))  $((600 * GIB)) $((380 * GIB))    62%    /System/Volumes/Data"
assert_exit 0 diag status_disk_space "$HOME"
assert_contains "$RUN_OUTPUT" "ok         Free space on /System/Volumes/Data: 380.0 GiB of 994.0 GiB (38%)"
read_only

stub scutil 'echo Garvits-MacBook-Pro'

export DOTFILES_PAM_DIR="$SANDBOX/pam.d"
load_script macos/install.sh
as_os macos
# The macos step mustn't load the Touch ID script's functions
assert_eq "" "$(declare -F usage install_reattach_module || true)" "the Touch ID script's functions"
SUDO_LOCAL="$DOTFILES_PAM_DIR/sudo_local"
REATTACH="$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_reattach.so"
# shellcheck disable=SC2034 # macos/pam.sh reads them
PAM_ROOT_UID="$(id -u)" PAM_TRUSTED_DIR="$SANDBOX"
HEADER="# sudo_local: local config file which survives system update and is included for sudo"
TID_LINE="auth       sufficient     pam_tid.so"
mkdir -p "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR"
printf '%s\n' "auth       include        sudo_local" "auth       required       pam_opendirectory.so" > "$DOTFILES_PAM_DIR/sudo"
# OpenPAM finds macOS's .so.2 modules by bare name
touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"

assert_exit 0 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "skipped    Touch ID for sudo: off"
assert_contains "$RUN_OUTPUT" "just touch-id"
echo "$HEADER" > "$SUDO_LOCAL"
assert_exit 0 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "skipped    Touch ID for sudo: off"
mkdir -p "$(dirname "$REATTACH")"
touch "$REATTACH"
chmod 755 "$(dirname "$REATTACH")"
chmod 444 "$REATTACH"
printf '%s\n' "$HEADER" "auth       optional       $REATTACH ignore_ssh" "$TID_LINE" > "$SUDO_LOCAL"
assert_exit 0 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
# A loaded module that's gone, as after brew bundle cleanup
rm "$REATTACH"
assert_exit 3 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads $REATTACH, which doesn't exist"
assert_contains "$RUN_OUTPUT" "run brew install pam-reattach, then just touch-id"
assert_contains "$RUN_OUTPUT" "sudo may fail"
# A bare name a newer macOS dropped
printf '%s\n' "$HEADER" "$TID_LINE" > "$SUDO_LOCAL"
rm "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
assert_exit 3 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads $DOTFILES_PAM_MODULES_DIR/pam_tid.so, which doesn't exist"
touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
printf '%s\n' "auth       sufficient     /usr/local/lib/pam/pam_watchid.so" "$TID_LINE" > "$SUDO_LOCAL"
assert_exit 3 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads /usr/local/lib/pam/pam_watchid.so, which doesn't exist"
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: $SUDO_LOCAL differs"
assert_not_contains "$RUN_OUTPUT" "pam-reattach"
# Root reads any file
chmod 000 "$SUDO_LOCAL"
if [ ! -r "$SUDO_LOCAL" ]; then
    assert_exit 0 diag status_touch_id skipped
    assert_contains "$RUN_OUTPUT" "unverified Touch ID for sudo: $SUDO_LOCAL isn't readable"
fi
chmod 644 "$SUDO_LOCAL"
assert_eq "auth       sufficient     /usr/local/lib/pam/pam_watchid.so
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local"
[ ! -e "$REATTACH" ] || fail "status put the module back"

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
# socketfilterfw isn't on PATH on macOS
firewall_off_path() {
    hide socketfilterfw
    APP_FIREWALL_DIR="$SANDBOX/alf"
    mkdir -p "$APP_FIREWALL_DIR"
    cp "$STUB_DIR/fdesetup" "$APP_FIREWALL_DIR/socketfilterfw"
    assert_eq "$APP_FIREWALL_DIR/socketfilterfw" "$(firewall_cmd)" "socketfilterfw's path"
}
subtest firewall_off_path
read_only

replace_fn default_matches 'return 0'
replace_fn hotkey_off 'return 0'
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
printf '%s\n' "$HEADER" "$TID_LINE" > "$SUDO_LOCAL"
DOTFILES_STATUS_QUICK=1 run status
assert_contains "$RUN_OUTPUT" "Touch ID for sudo, in $SUDO_LOCAL"
read_only
test_done
