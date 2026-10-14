#!/bin/bash
# The script's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# macos/setup-touch-id-sudo.sh rebuilds sudo_local each run: the template's header, a pam_reattach
# line when pam-reattach is installed, then pam_tid. It replaces a file that differs, dropping any
# other line. DOTFILES_PAM_DIR points it at a sandbox copy of /etc/pam.d. sudo and brew are stubs,
# and the sudo stub refuses any path under /etc, so a mistake can't reach the real one.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export DOTFILES_PAM_DIR="$SANDBOX/pam.d"
load_script macos/setup-touch-id-sudo.sh
is_macos() { true; }

SUDO_LOCAL="$DOTFILES_PAM_DIR/sudo_local"
REATTACH="$SANDBOX/brew/lib/pam/pam_reattach.so"
HEADER="# sudo_local: local config file which survives system update and is included for sudo"
TID_LINE="auth       sufficient     pam_tid.so"
REATTACH_LINE="auth       optional       $REATTACH ignore_ssh"

stub sudo 'for a in "$@"; do case "$a" in /etc/* | /private/etc/*) echo "refused: $a" >&2; exit 1 ;; esac; done
exec "$@"'
# brew --prefix is $SANDBOX/brew; the script never installs anything with it
stub brew '[ "$1" != --prefix ] || echo "$(dirname "$STUB_LOG")/brew"'

# reset: a pam.d whose sudo includes sudo_local, macOS's pam_tid, no sudo_local, no pam-reattach, an
# empty log, and no DOTFILES_ASSUME_YES
reset() {
    rm -rf "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR" "$DOTFILES_PAM_LOCAL_MODULES_DIR" "$SANDBOX/brew"
    mkdir -p "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR"
    touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
    printf '%s\n' "# sudo: auth account password session" "auth       include        sudo_local" \
        "auth       required       pam_opendirectory.so" > "$DOTFILES_PAM_DIR/sudo"
    : > "$STUB_LOG"
    unset DOTFILES_ASSUME_YES
}

put_reattach() {
    mkdir -p "$(dirname "$REATTACH")"
    touch "$REATTACH"
}

# Ubuntu: says it's macOS only, and does nothing
reset
is_macos() { false; }
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "macOS only"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    Touch ID for sudo: macOS only"
assert_file_not_contains "$STUB_LOG" "sudo"
is_macos() { true; }

# Not set up: status needs attention. Without a terminal, main shows the file, writes nothing,
# and doesn't fail.
reset
put_reattach
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: off"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "$TID_LINE"
assert_contains "$RUN_OUTPUT" "Left unchanged"
[ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written without asking"
assert_file_not_contains "$STUB_LOG" "sudo"

# Approved: the header, pam_reattach, then pam_tid, read-only. brew installs nothing.
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local"
assert_eq "-r--r--r--" "$(/bin/ls -l "$SUDO_LOCAL" | cut -c 1-10)" "sudo_local's mode"
assert_file_not_contains "$STUB_LOG" "brew install"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
assert_not_contains "$RUN_OUTPUT" "pam-reattach isn't installed"

# Re-run: already set up, and no sudo
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already on"
assert_file_not_contains "$STUB_LOG" "sudo"

# Without pam-reattach: pam_tid alone, and the homebrew step is named as what installs it
reset
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local without pam-reattach"
assert_contains "$RUN_OUTPUT" "homebrew step"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
assert_contains "$RUN_OUTPUT" "skipped    Touch ID in tmux: pam-reattach isn't installed"

# Installed later: status sees the file is stale, and main adds the line
put_reattach
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: $SUDO_LOCAL differs"
assert_exit 0 main
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local after installing pam-reattach"

# Uninstalled later: the line names a module that's gone, which status flags, naming the homebrew
# step, and main drops the line
rm "$REATTACH"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads $REATTACH, which doesn't exist"
assert_contains "$RUN_OUTPUT" "homebrew step"
assert_exit 0 main
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local after uninstalling pam-reattach"

# Any other file is rebuilt from scratch: other modules, comments, and a pam_reattach line after
# pam_tid or with other options all go
reset
put_reattach
export DOTFILES_ASSUME_YES=1
printf '%s\n' "$HEADER" "#auth       sufficient     pam_tid.so" "auth       sufficient     pam_watchid.so" \
    "$TID_LINE" "auth optional $REATTACH debug" > "$SUDO_LOCAL"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "differs"
assert_exit 0 main
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local rebuilt"

# OpenPAM finds a bare module name in /usr/lib/pam or /usr/local/lib/pam, with or without .2, as
# pam-watchid's install leaves pam_watchid.so.2 in the second
reset
mkdir -p "$DOTFILES_PAM_LOCAL_MODULES_DIR"
touch "$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_watchid.so.2"
printf '%s\n' "auth       sufficient     pam_watchid.so" "$TID_LINE" "auth       optional       pam_reattach.so" > "$SUDO_LOCAL"
assert_eq "$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_watchid.so
$DOTFILES_PAM_MODULES_DIR/pam_tid.so
$DOTFILES_PAM_MODULES_DIR/pam_reattach.so" "$(sudo_local_modules)" "where the bare names resolve"
pam_module_exists "$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_watchid.so" || fail "pam_watchid.so.2 wasn't found"
# A bare pam_reattach.so that's in neither is missing
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "$DOTFILES_PAM_MODULES_DIR/pam_reattach.so, which doesn't exist"

# Without Homebrew, it turns on Touch ID and says the homebrew step installs pam-reattach
reset
export DOTFILES_ASSUME_YES=1
rm "$STUB_DIR/brew"
PATH="$STUB_DIR:/usr/bin:/bin" run main
assert_eq 0 "$RUN_STATUS" "exit status without Homebrew: $RUN_OUTPUT"
assert_contains "$RUN_OUTPUT" "homebrew step"
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local without Homebrew"

# A failed write fails the run
reset
export DOTFILES_ASSUME_YES=1
stub sudo 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't write $SUDO_LOCAL"

# A macOS whose /etc/pam.d/sudo doesn't include sudo_local (before 14): main fails, writing nothing
reset
export DOTFILES_ASSUME_YES=1
grep -v sudo_local "$DOTFILES_PAM_DIR/sudo" > "$SANDBOX/sudo" && mv "$SANDBOX/sudo" "$DOTFILES_PAM_DIR/sudo"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "doesn't include sudo_local"
[ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written though sudo doesn't read it"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: $DOTFILES_PAM_DIR/sudo doesn't include sudo_local"
test_done
