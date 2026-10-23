#!/bin/bash
set -euo pipefail
# os: macos

# macos/setup-touch-id-sudo.sh: sudo_local and the root-owned pam-reattach copy sudo loads.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
export HOMEBREW_PREFIX="$SANDBOX/brew"
load_script macos/setup-touch-id-sudo.sh
as_os macos

# sudo and what it runs come from the system's dirs, after the stubs
case "$PATH" in
    "$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin:"*) ;;
    *) fail "the system's dirs don't lead PATH: $PATH" ;;
esac

SOURCE="$SANDBOX/brew/lib/pam/pam_reattach.so"
MODULE="$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_reattach.so"
REATTACH_LINE="auth       optional       $MODULE ignore_ssh"

stub_sudo_exec 'args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o | -g) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"' # drops install's -o and -g, which need root

reset() {
    rm -rf "$SANDBOX/brew"
    pam_sandbox
    : > "$STUB_LOG"
    answer no
}

put_reattach() {
    mkdir -p "$(dirname "$SOURCE")"
    echo "${1:-reattach 1.0}" > "$SOURCE"
}

# Not set up, no terminal: main changes nothing and doesn't fail
reset
put_reattach
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: off"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged. Run this step from a terminal to apply them."
[ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written without asking"
[ ! -e "$MODULE" ] || fail "the module was copied without asking"
assert_file_not_contains "$STUB_LOG" "sudo"

answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo install -d -o root -g wheel -m 755 $DOTFILES_PAM_LOCAL_MODULES_DIR"
assert_file_contains "$STUB_LOG" "sudo install -o root -g wheel -m 444 $SOURCE $MODULE.new"
assert_file_contains "$STUB_LOG" "sudo mv -fh $MODULE.new $MODULE"
[ ! -e "$MODULE.new" ] || fail "the copy's temp name was left behind"
assert_eq "reattach 1.0" "$(cat "$MODULE")" "the copy"
assert_eq "-r--r--r--" "$(/bin/ls -l "$MODULE" | cut -c 1-10)" "the copy's mode"
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local"
assert_eq "-r--r--r--" "$(/bin/ls -l "$SUDO_LOCAL" | cut -c 1-10)" "sudo_local's mode"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
assert_not_contains "$RUN_OUTPUT" "pam-reattach isn't installed"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already on"
assert_file_not_contains "$STUB_LOG" "sudo"

# brew upgrade changed Homebrew's module
chmod 644 "$SOURCE"
put_reattach "reattach 1.1"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE, which sudo loads, is older than Homebrew's pam-reattach; re-run just touch-id"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "reattach 1.1" "$(cat "$MODULE")" "the copy after the upgrade"
assert_file_not_contains "$STUB_LOG" "$SUDO_LOCAL"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"

# A copy others can write is reinstalled
chmod 664 "$MODULE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE"
assert_contains "$RUN_OUTPUT" "just touch-id"
assert_exit 0 main
assert_eq "-r--r--r--" "$(/bin/ls -l "$MODULE" | cut -c 1-10)" "the copy's mode after the fix"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"
# A writable dir or parent: main refuses, since it doesn't change them
chmod 775 "$DOTFILES_PAM_LOCAL_MODULES_DIR"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: sudo can't safely load $MODULE: $DOTFILES_PAM_LOCAL_MODULES_DIR isn't root's alone to write; run sudo chown root $DOTFILES_PAM_LOCAL_MODULES_DIR && sudo chmod go-w $DOTFILES_PAM_LOCAL_MODULES_DIR"
: > "$STUB_LOG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Touch ID in tmux: sudo can't safely load $MODULE: $DOTFILES_PAM_LOCAL_MODULES_DIR isn't root's alone to write"
assert_file_not_contains "$STUB_LOG" "sudo"
chmod 755 "$DOTFILES_PAM_LOCAL_MODULES_DIR"
chmod 775 "$SANDBOX"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: sudo can't safely load $MODULE: $SANDBOX isn't root's alone to write"
assert_contains "$RUN_OUTPUT" "sudo chmod go-w $SANDBOX"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Touch ID in tmux: sudo can't safely load $MODULE: $SANDBOX isn't root's alone to write"
chmod 700 "$SANDBOX"
# shellcheck disable=SC2034 # macos/lib/pam.sh reads it
PAM_ROOT_UID=99999
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "isn't root's alone to write; run sudo chown root"
# shellcheck disable=SC2034 # macos/lib/pam.sh reads it
PAM_ROOT_UID="$(id -u)"

# Homebrew's copy uninstalled: sudo still loads the root copy
rm -rf "$SANDBOX/brew"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
assert_not_contains "$RUN_OUTPUT" "missing"
assert_not_contains "$RUN_OUTPUT" "pam-reattach isn't installed"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already on"
assert_file_not_contains "$STUB_LOG" "sudo"
# Without Homebrew's copy, an unsafe copy can't be fixed
chmod 664 "$MODULE"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "brew install pam-reattach"
assert_file_not_contains "$STUB_LOG" "sudo"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "isn't root's alone to write; run brew install pam-reattach, then just touch-id"
chmod 444 "$MODULE"

# Without pam-reattach: pam_tid alone
reset
answer yes
assert_exit 0 main
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local without pam-reattach"
assert_file_not_contains "$STUB_LOG" "sudo install -o"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
assert_contains "$RUN_OUTPUT" "skipped    Touch ID in tmux: pam-reattach isn't installed"

# pam-reattach installed later
put_reattach
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: $SUDO_LOCAL's pam_tid and pam_reattach lines differ from just touch-id's"
assert_exit 0 main
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local after installing pam-reattach"
[ -f "$MODULE" ] || fail "the module wasn't copied"

# Both copies gone: sudo_local names a missing module
rm -rf "$SANDBOX/brew" "$MODULE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $SUDO_LOCAL loads $MODULE, which doesn't exist"
assert_contains "$RUN_OUTPUT" "brew install pam-reattach, then just touch-id"
# The missing module can break sudo itself
assert_contains "$RUN_OUTPUT" "If sudo fails, remove the file without it: osascript -e 'do shell script \"rm $SUDO_LOCAL\" with administrator privileges'"
assert_exit 0 main
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local after uninstalling pam-reattach"

# Your lines are kept. Other pam_tid and pam_reattach lines go, and the repo's go first.
reset
put_reattach
answer yes
WATCHID_LINE="auth       sufficient     pam_watchid.so"
touch "$DOTFILES_PAM_MODULES_DIR/pam_watchid.so.2"
printf '%s\n' "$HEADER" "auth       optional       $SOURCE ignore_ssh" "#auth       sufficient     pam_tid.so" \
    "$WATCHID_LINE" "$TID_LINE" "auth optional $MODULE debug" > "$SUDO_LOCAL"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "lines differ"
assert_exit 0 main
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE
#auth       sufficient     pam_tid.so
$WATCHID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local with your lines"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
# The repo's lines in order, wherever they are and however spaced, are left alone
chmod 644 "$SUDO_LOCAL"
printf '%s\n' "$WATCHID_LINE" "auth optional $MODULE ignore_ssh" "$TID_LINE" > "$SUDO_LOCAL"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         Touch ID for sudo, in $SUDO_LOCAL"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already on"
assert_file_not_contains "$STUB_LOG" "sudo"
# Out of order, they move to the top
printf '%s\n' "$WATCHID_LINE" "$TID_LINE" "$REATTACH_LINE" > "$SUDO_LOCAL"
assert_exit 3 main --status
assert_exit 0 main
assert_eq "$REATTACH_LINE
$TID_LINE
$WATCHID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local with the repo's lines out of order"

# OpenPAM resolves bare names in /usr/lib/pam or /usr/local/lib/pam, with or without .2
reset
mkdir -p "$DOTFILES_PAM_LOCAL_MODULES_DIR"
touch "$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_watchid.so.2"
printf '%s\n' "auth       sufficient     pam_watchid.so" "$TID_LINE" "auth       optional       pam_reattach.so" > "$SUDO_LOCAL"
assert_eq "$DOTFILES_PAM_LOCAL_MODULES_DIR/pam_watchid.so
$DOTFILES_PAM_MODULES_DIR/pam_tid.so
$DOTFILES_PAM_MODULES_DIR/pam_reattach.so" "$(sudo_local_modules)" "where the bare names resolve"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "$DOTFILES_PAM_MODULES_DIR/pam_reattach.so, which doesn't exist"

# --- what sudo can't safely load ---
set_up() {
    reset
    put_reattach
    answer yes
    assert_exit 0 main
    : > "$STUB_LOG"
}

# The copy replaced with a symlink to a user-writable file
set_up
rm -f "$MODULE"
ln -s "$SOURCE" "$MODULE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE, which sudo loads, isn't a root-owned copy of Homebrew's pam-reattach module; re-run just touch-id"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo mv -fh $MODULE.new $MODULE"
[ ! -L "$MODULE" ] && [ -f "$MODULE" ] || fail "the linked module wasn't replaced with a copy"
assert_eq "reattach 1.0" "$(cat "$SOURCE")" "Homebrew's module, after the link was replaced"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"
# Without Homebrew's module the link can't be replaced
rm -f "$MODULE"
echo "elsewhere" > "$SANDBOX/elsewhere.so"
ln -s "$SANDBOX/elsewhere.so" "$MODULE"
rm -rf "$SANDBOX/brew"
: > "$STUB_LOG"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE, which sudo loads, is a symlink; run brew install pam-reattach, then just touch-id"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$MODULE, which sudo loads, is a symlink; run brew install pam-reattach"
assert_file_not_contains "$STUB_LOG" "sudo"
# A dangling link isn't loaded, so it doesn't block Touch ID alone
rm "$SANDBOX/elsewhere.so"
assert_exit 0 main
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local beside a dangling link"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    Touch ID in tmux: pam-reattach isn't installed"
assert_not_contains "$RUN_OUTPUT" "missing"

# A symlinked dir or parent is refused: whoever controls the target can swap the module
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
    # shellcheck disable=SC2034 # macos/lib/pam.sh reads it
    PAM_LOCAL_MODULES_DIR="$SANDBOX/lib/pam" REATTACH_MODULE="$SANDBOX/lib/pam/pam_reattach.so"
    MODULE="$REATTACH_MODULE"
    reset
    mkdir -p "$SANDBOX/real-lib"
    ln -s "$SANDBOX/real-lib" "$SANDBOX/lib"
    put_reattach
    answer yes
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "sudo can't safely load $MODULE: $SANDBOX/lib is a symlink"
    assert_file_not_contains "$STUB_LOG" "sudo"
    [ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written under a linked parent"
}
subtest linked_parent

# A writable ACL is refused, not removed, since someone set it on purpose
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
set_up
chmod +a "everyone deny write,delete" "$MODULE"
chmod +a "everyone allow read,readattr" "$DOTFILES_PAM_LOCAL_MODULES_DIR"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"
chmod -N "$MODULE" "$DOTFILES_PAM_LOCAL_MODULES_DIR"

# OpenPAM loads pam_reattach.so.2 instead of the copy; setup didn't install it, so it isn't deleted
set_up
echo "old reattach" > "$MODULE.2"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE.2 exists, and OpenPAM loads it instead of the copy; remove it with sudo rm $MODULE.2, then re-run just touch-id"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$MODULE.2 exists, and OpenPAM loads it instead of the copy"
assert_file_not_contains "$STUB_LOG" "sudo"
assert_eq "old reattach" "$(cat "$MODULE.2")" "pam_reattach.so.2"
rm "$MODULE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE.2 exists"
assert_exit 1 main
assert_file_not_contains "$STUB_LOG" "sudo"
rm "$MODULE.2"
ln -s "$SANDBOX/nowhere" "$MODULE.2"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "$MODULE.2 exists"
[ -L "$MODULE.2" ] || fail "the linked pam_reattach.so.2 was removed"
rm "$MODULE.2"

unsafe_copy() {
    reset
    put_reattach
    answer yes
    replace_fn install_reattach_module 'mkdir -p "$DOTFILES_PAM_LOCAL_MODULES_DIR"
cp "$SOURCE" "$MODULE"
chmod 666 "$MODULE"'
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "sudo can't safely load $MODULE: $MODULE isn't root's alone to write"
    [ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written though the copy was unsafe"
}
subtest unsafe_copy

reset
answer yes
stub sudo 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't write $SUDO_LOCAL"

# A failed copy stops before sudo_local could name a missing module
reset
put_reattach
answer yes
stub sudo 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't install $MODULE"
[ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written though the copy failed"
test_done
