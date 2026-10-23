#!/bin/bash
set -euo pipefail
# os: macos

# The macos step's read-only status diagnostics.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=diagnostics-fixture.sh
source "$TESTS_DIR/diagnostics-fixture.sh"

setup_sandbox
stub scutil 'echo Garvits-MacBook-Pro'

load_script macos/install.sh
as_os macos
# firewall() below stubs socketfilterfw here
APP_FIREWALL_DIR="$STUB_DIR"
# The macos step mustn't load the Touch ID script's functions
assert_eq "" "$(declare -F usage install_reattach_module || true)" "the Touch ID script's functions"
pam_sandbox
REATTACH="$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_reattach.so"

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
snapshot "$SUDO_LOCAL"
rm "$REATTACH"
assert_exit 3 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads $REATTACH, which doesn't exist"
# Root reads any file
chmod 000 "$SUDO_LOCAL"
if [ ! -r "$SUDO_LOCAL" ]; then
    assert_exit 0 diag status_touch_id skipped
    assert_contains "$RUN_OUTPUT" "unverified Touch ID for sudo: $SUDO_LOCAL isn't readable"
fi
chmod 644 "$SUDO_LOCAL"
assert_unchanged "$SUDO_LOCAL" "after status"
[ ! -e "$REATTACH" ] || fail "status put the module back"
# A bare name a newer macOS dropped breaks sudo too
printf '%s\n' "$HEADER" "$TID_LINE" > "$SUDO_LOCAL"
rm "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
assert_exit 3 diag status_touch_id skipped
assert_contains "$RUN_OUTPUT" "loads $DOTFILES_PAM_MODULES_DIR/pam_tid.so, which doesn't exist, so sudo may fail"
touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"

# FileVault's state is only info; status never reads it with sudo
filevault() {
    stub fdesetup "[ \"\$1\" == status ] || exit 1
printf '%b' '$1'
exit ${2:-0}"
}
filevault 'FileVault is On.\n'
assert_exit 0 diag status_filevault
assert_file_not_contains "$STUB_LOG" "sudo"

# firewall <--getglobalstate output> [<--getstealthmode output>]
firewall() {
    stub socketfilterfw "case \"\$1\" in
    --getglobalstate) printf '%b' '$1' ;;
    --getstealthmode) printf '%b' '${2:-}' ;;
    *) exit 1 ;;
esac"
}
# The step runs the system's socketfilterfw, not one earlier on PATH
firewall_system_copy() {
    firewall 'Firewall is disabled. (State = 0)\n'
    APP_FIREWALL_DIR="$SANDBOX/alf"
    mkdir -p "$APP_FIREWALL_DIR"
    mv "$STUB_DIR/socketfilterfw" "$APP_FIREWALL_DIR/socketfilterfw"
    firewall 'Firewall is enabled. (State = 1)\n'
    ! firewall_on || fail "firewall_on ran the socketfilterfw on PATH"
}
subtest firewall_system_copy
read_only

replace_fn default_matches 'return 0'
replace_fn hotkey_off 'return 0'
mkdir -p "$HOME/Screenshots"
rm "$SUDO_LOCAL"
firewall 'Firewall is disabled. (State = 0)\n' 'Firewall stealth mode is off\n'
stub defaults 'exit 1'
df_lines "/dev/disk3s5 $((994 * GIB)) $((600 * GIB)) $((380 * GIB)) 62% /System/Volumes/Data"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "skipped    Touch ID for sudo"
assert_contains "$RUN_OUTPUT" "missing    Application firewall on"
assert_contains "$RUN_OUTPUT" "missing    Firewall stealth mode on"
assert_contains "$RUN_OUTPUT" "missing    App Store apps update automatically"
assert_contains "$RUN_OUTPUT" "ok         Free space on /System/Volumes/Data"
read_only
printf '%s\n' "$HEADER" "$TID_LINE" > "$SUDO_LOCAL"
DOTFILES_STATUS_QUICK=1 run status
assert_contains "$RUN_OUTPUT" "Touch ID for sudo, in $SUDO_LOCAL"
read_only
test_done
