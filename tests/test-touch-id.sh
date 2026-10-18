#!/bin/bash
# The script's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail
# os: macos

# macos/setup-touch-id-sudo.sh rebuilds sudo_local each run: the template's header, a pam_reattach
# line when pam-reattach is installed, then pam_tid. sudo loads a root-owned copy of pam-reattach's
# module, which the script installs from Homebrew's, so a process running as you can't replace
# what sudo runs as root. It replaces a sudo_local that differs, dropping any other line.
# DOTFILES_PAM_DIR and DOTFILES_PAM_LOCAL_MODULES_DIR point it at sandbox copies of /etc/pam.d and
# /usr/local/lib/pam, and HOMEBREW_PREFIX at a sandbox Homebrew. sudo is a stub, which drops
# install's -o and -g, which need root, and refuses any path outside the sandbox, so a mistake
# can't reach the real ones.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export DOTFILES_PAM_DIR="$SANDBOX/pam.d" HOMEBREW_PREFIX="$SANDBOX/brew"
load_script macos/setup-touch-id-sudo.sh
is_macos() { true; }
# The sandbox's files are yours, so "root-owned" means owned by you here, and the parent dirs the
# check walks stop at the sandbox
# shellcheck disable=SC2034 # macos/pam.sh reads them
PAM_ROOT_UID="$(id -u)" PAM_TRUSTED_DIR="$SANDBOX"

SUDO_LOCAL="$DOTFILES_PAM_DIR/sudo_local"
SOURCE="$SANDBOX/brew/lib/pam/pam_reattach.so"
MODULE="$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_reattach.so"
HEADER="# sudo_local: local config file which survives system update and is included for sudo"
TID_LINE="auth       sufficient     pam_tid.so"
REATTACH_LINE="auth       optional       $MODULE ignore_ssh"

stub_sudo_exec 'args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o | -g) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"'

# reset: a pam.d whose sudo includes sudo_local, macOS's pam_tid, no sudo_local, no pam-reattach
# and no copy of it, an empty log, and no DOTFILES_ASSUME_YES
reset() {
    rm -rf "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR" "$DOTFILES_PAM_LOCAL_MODULES_DIR" "$SANDBOX/brew"
    mkdir -p "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR"
    touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
    printf '%s\n' "# sudo: auth account password session" "auth       include        sudo_local" \
        "auth       required       pam_opendirectory.so" > "$DOTFILES_PAM_DIR/sudo"
    : > "$STUB_LOG"
    unset DOTFILES_ASSUME_YES
}

# put_reattach [content]: Homebrew's pam-reattach module
put_reattach() {
    mkdir -p "$(dirname "$SOURCE")"
    echo "${1:-reattach 1.0}" > "$SOURCE"
}

# Not set up: status needs attention. Without a terminal, main shows the copy and the file, changes
# nothing, and doesn't fail.
reset
put_reattach
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: off"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "$MODULE"
assert_contains "$RUN_OUTPUT" "$TID_LINE"
assert_contains "$RUN_OUTPUT" "Left unchanged"
[ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written without asking"
[ ! -e "$MODULE" ] || fail "the module was copied without asking"
assert_file_not_contains "$STUB_LOG" "sudo"

# Approved: the module is copied read-only into the root-owned dir, and sudo_local loads that copy
# before pam_tid. brew installs nothing.
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo install -d -o root -g wheel -m 755 $DOTFILES_PAM_LOCAL_MODULES_DIR"
assert_file_contains "$STUB_LOG" "sudo install -o root -g wheel -m 444 $SOURCE $MODULE"
assert_eq "reattach 1.0" "$(cat "$MODULE")" "the copy"
assert_eq "-r--r--r--" "$(/bin/ls -l "$MODULE" | cut -c 1-10)" "the copy's mode"
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local"
assert_eq "-r--r--r--" "$(/bin/ls -l "$SUDO_LOCAL" | cut -c 1-10)" "sudo_local's mode"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
assert_not_contains "$RUN_OUTPUT" "pam-reattach isn't installed"

# Re-run: already set up, and no sudo
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already on"
assert_file_not_contains "$STUB_LOG" "sudo"

# brew upgrade changed Homebrew's module: status says to re-run, and main copies the new one,
# leaving sudo_local as it is
chmod 644 "$SOURCE"
put_reattach "reattach 1.1"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: pam-reattach was upgraded; re-run just touch-id"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "reattach 1.1" "$(cat "$MODULE")" "the copy after the upgrade"
assert_file_not_contains "$STUB_LOG" "$SUDO_LOCAL"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"

# A copy, or its dir, that root doesn't own, or that others can write, needs attention, and main
# installs it again
chmod 664 "$MODULE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE"
assert_contains "$RUN_OUTPUT" "just touch-id"
assert_exit 0 main
assert_eq "-r--r--r--" "$(/bin/ls -l "$MODULE" | cut -c 1-10)" "the copy's mode after the fix"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"
# The copy's dir, or a parent, others can write: status gives the fix, and main refuses, since it
# doesn't change them
chmod 775 "$DOTFILES_PAM_LOCAL_MODULES_DIR"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: sudo can't safely load $MODULE: $DOTFILES_PAM_LOCAL_MODULES_DIR isn't root's alone to write; run sudo chown root $DOTFILES_PAM_LOCAL_MODULES_DIR && sudo chmod go-w $DOTFILES_PAM_LOCAL_MODULES_DIR"
: > "$STUB_LOG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sudo can't safely load pam-reattach from $DOTFILES_PAM_LOCAL_MODULES_DIR: $DOTFILES_PAM_LOCAL_MODULES_DIR isn't root's alone to write"
assert_file_not_contains "$STUB_LOG" "sudo"
chmod 755 "$DOTFILES_PAM_LOCAL_MODULES_DIR"
chmod 775 "$SANDBOX"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: sudo can't safely load $MODULE: $SANDBOX isn't root's alone to write"
assert_contains "$RUN_OUTPUT" "sudo chmod go-w $SANDBOX"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sudo can't safely load pam-reattach from $DOTFILES_PAM_LOCAL_MODULES_DIR: $SANDBOX isn't root's alone to write"
chmod 700 "$SANDBOX"
# shellcheck disable=SC2034 # macos/pam.sh reads it
PAM_ROOT_UID=99999
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "isn't root's alone to write; run sudo chown root"
# shellcheck disable=SC2034 # macos/pam.sh reads it
PAM_ROOT_UID="$(id -u)"

# Homebrew's copy uninstalled: sudo still loads the root copy, so nothing changes, and status is ok
rm -rf "$SANDBOX/brew"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
assert_not_contains "$RUN_OUTPUT" "missing"
assert_not_contains "$RUN_OUTPUT" "pam-reattach isn't installed"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already on"
assert_file_not_contains "$STUB_LOG" "sudo"
# Without Homebrew's copy, an unsafe copy can't be put right: main fails before changing anything
chmod 664 "$MODULE"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "brew install pam-reattach"
assert_file_not_contains "$STUB_LOG" "sudo"
# and status names the install first
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "isn't root's alone to write; run brew install pam-reattach, then just touch-id"
chmod 444 "$MODULE"

# Without pam-reattach: pam_tid alone, and the homebrew step is named as what installs it
reset
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local without pam-reattach"
assert_contains "$RUN_OUTPUT" "homebrew step"
assert_file_not_contains "$STUB_LOG" "sudo install -o"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
assert_contains "$RUN_OUTPUT" "skipped    Touch ID in tmux: pam-reattach isn't installed"

# Installed later: status sees the file is stale, and main copies the module and adds the line
put_reattach
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: $SUDO_LOCAL differs"
assert_exit 0 main
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local after installing pam-reattach"
[ -f "$MODULE" ] || fail "the module wasn't copied"

# Both copies gone: the line names a module that doesn't exist, which status flags, leading with
# the fix that needs no sudo, and main drops the line
rm -rf "$SANDBOX/brew" "$MODULE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads $MODULE, which doesn't exist"
assert_contains "$RUN_OUTPUT" "brew install pam-reattach, then just touch-id"
assert_exit 0 main
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local after uninstalling pam-reattach"

# Any other file is rebuilt from scratch: other modules, comments, and a pam_reattach line after
# pam_tid, with other options, or naming Homebrew's copy all go
reset
put_reattach
export DOTFILES_ASSUME_YES=1
printf '%s\n' "$HEADER" "auth       optional       $SOURCE ignore_ssh" "#auth       sufficient     pam_tid.so" \
    "auth       sufficient     pam_watchid.so" "$TID_LINE" "auth optional $MODULE debug" > "$SUDO_LOCAL"
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

# --- what sudo can't safely load ---
# set_up: pam-reattach installed, and just touch-id run, so sudo_local loads the copy
set_up() {
    reset
    put_reattach
    export DOTFILES_ASSUME_YES=1
    assert_exit 0 main
    : > "$STUB_LOG"
}

# The copy replaced with a link to a file you can write, as some guides suggest: status names it,
# and main puts a real copy in its place
set_up
rm -f "$MODULE"
ln -s "$SOURCE" "$MODULE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE, which sudo loads, is a symlink; re-run just touch-id"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo rm -f $MODULE"
[ ! -L "$MODULE" ] && [ -f "$MODULE" ] || fail "the linked module wasn't replaced with a copy"
assert_eq "reattach 1.0" "$(cat "$SOURCE")" "Homebrew's module, after the link was replaced"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"
# Without Homebrew's module, a link can't be replaced
rm -f "$MODULE"
ln -s "$SANDBOX/elsewhere.so" "$MODULE"
rm -rf "$SANDBOX/brew"
: > "$STUB_LOG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "brew install pam-reattach"
assert_file_not_contains "$STUB_LOG" "sudo"

# The copy's dir a link, or a parent of it: refused, since whoever controls where it points can
# swap it, and main changes nothing
link_dir() {
    local link="$1" target="$2"
    mkdir -p "$(dirname "$link")" "$target"
    cp -pR "$DOTFILES_PAM_LOCAL_MODULES_DIR/." "$target"
    rm -rf "$DOTFILES_PAM_LOCAL_MODULES_DIR"
    ln -s "$target" "$link"
}
linked_dir() {
    set_up
    link_dir "$DOTFILES_PAM_LOCAL_MODULES_DIR" "$SANDBOX/real-pam"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: sudo can't safely load $MODULE: $DOTFILES_PAM_LOCAL_MODULES_DIR is a symlink; remove it with sudo rm $DOTFILES_PAM_LOCAL_MODULES_DIR"
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "$DOTFILES_PAM_LOCAL_MODULES_DIR is a symlink"
    assert_file_not_contains "$STUB_LOG" "sudo"
}
subtest linked_dir
linked_parent() {
    # The copy's dir two levels down, under a parent that's a link
    PAM_LOCAL_MODULES_DIR="$SANDBOX/lib/pam" REATTACH_MODULE="$SANDBOX/lib/pam/pam_reattach.so"
    MODULE="$REATTACH_MODULE"
    reset
    mkdir -p "$SANDBOX/real-lib"
    ln -s "$SANDBOX/real-lib" "$SANDBOX/lib"
    put_reattach
    export DOTFILES_ASSUME_YES=1
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "sudo can't safely load pam-reattach from $PAM_LOCAL_MODULES_DIR: $SANDBOX/lib is a symlink"
    assert_file_not_contains "$STUB_LOG" "sudo"
    [ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written under a linked parent"
}
subtest linked_parent

# An ACL that lets others write the copy, its dir, or a parent: refused, not removed, since
# someone set it on purpose
acl_on() {
    local path="$1"
    set_up
    chmod +a "everyone allow add_file,delete_child" "$path" 2> /dev/null ||
        chmod +a "everyone allow write,append" "$path"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: sudo can't safely load $MODULE: $path has an ACL entry that lets others write it; remove it with sudo chmod -N $path"
    : > "$STUB_LOG"
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "$path has an ACL entry that lets others write it"
    assert_file_not_contains "$STUB_LOG" "sudo"
    chmod -N "$path"
    assert_exit 0 main --status
    assert_not_contains "$RUN_OUTPUT" "missing"
}
acl_on "$MODULE"
acl_on "$DOTFILES_PAM_LOCAL_MODULES_DIR"
acl_on "$SANDBOX"
# An entry that only denies, or only reads, is fine
set_up
chmod +a "everyone deny write,delete" "$MODULE"
chmod +a "everyone allow read,readattr" "$DOTFILES_PAM_LOCAL_MODULES_DIR"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"
chmod -N "$MODULE" "$DOTFILES_PAM_LOCAL_MODULES_DIR"

# pam_reattach.so.2 beside the copy, which OpenPAM loads instead: status reports it, and main
# refuses, and neither deletes it, since setup didn't install it
set_up
echo "old reattach" > "$MODULE.2"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE.2 exists, and OpenPAM loads it instead of the copy; remove it with sudo rm $MODULE.2, then re-run just touch-id"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$MODULE.2 exists, and OpenPAM loads it instead of the copy"
assert_file_not_contains "$STUB_LOG" "sudo"
assert_eq "old reattach" "$(cat "$MODULE.2")" "pam_reattach.so.2"
# a link counts too, even one that points nowhere
rm "$MODULE.2"
ln -s "$SANDBOX/nowhere" "$MODULE.2"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "$MODULE.2 exists"
[ -L "$MODULE.2" ] || fail "the linked pam_reattach.so.2 was removed"
rm "$MODULE.2"

# A copy that's still unsafe after install isn't loaded: main fails before writing sudo_local
unsafe_copy() {
    reset
    put_reattach
    export DOTFILES_ASSUME_YES=1
    install_reattach_module() {
        mkdir -p "$DOTFILES_PAM_LOCAL_MODULES_DIR"
        cp "$SOURCE" "$MODULE"
        chmod 666 "$MODULE"
    }
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "sudo can't safely load $MODULE: $MODULE isn't root's alone to write"
    [ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written though the copy was unsafe"
}
subtest unsafe_copy

# A failed write fails the run
reset
export DOTFILES_ASSUME_YES=1
stub sudo 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't write $SUDO_LOCAL"

# A failed copy fails the run before sudo_local is written, so it never names a missing module
reset
put_reattach
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't install $MODULE"
[ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written though the copy failed"
test_done
