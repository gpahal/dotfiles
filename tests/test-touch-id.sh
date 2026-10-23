#!/bin/bash
set -euo pipefail
# os: macos

# macos/setup-touch-id-sudo.sh: sudo_local and the root-owned pam-reattach copy sudo loads.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# PAM dirs for macos/lib/pam.sh, fresh: a sudo that includes sudo_local and macOS's pam_tid.so.2.
# Sets SUDO_LOCAL, HEADER and TID_LINE, the lines the Touch ID script writes, and makes "root-owned"
# mean owned by you. Call it after load_script.
pam_sandbox() {
    rm -rf "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR" "$DOTFILES_PAM_LOCAL_MODULES_DIR"
    mkdir -p "$DOTFILES_PAM_DIR" "$DOTFILES_PAM_MODULES_DIR"
    printf '%s\n' "# sudo: auth account password session" "auth       include        sudo_local" \
        "auth       required       pam_opendirectory.so" > "$DOTFILES_PAM_DIR/sudo"
    # OpenPAM finds macOS's .so.2 modules by bare name
    touch "$DOTFILES_PAM_MODULES_DIR/pam_tid.so.2"
    # shellcheck disable=SC2034 # tests and macos/lib/pam.sh read them
    PAM_ROOT_UID="$(id -u)" SUDO_LOCAL="$DOTFILES_PAM_DIR/sudo_local" \
        HEADER="# sudo_local: local config file which survives system update and is included for sudo" \
        TID_LINE="auth       sufficient     pam_tid.so"
}

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
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: $SUDO_LOCAL differs from what just touch-id writes"
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

# The repo owns sudo_local: a run replaces your lines
reset
put_reattach
answer yes
touch "$DOTFILES_PAM_MODULES_DIR/pam_watchid.so.2"
printf '%s\n' "$HEADER" "auth       sufficient     pam_watchid.so" "$REATTACH_LINE" "$TID_LINE" > "$SUDO_LOCAL"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Touch ID for sudo: $SUDO_LOCAL differs from what just touch-id writes; run it to replace the file"
assert_exit 0 main
assert_eq "$HEADER
$REATTACH_LINE
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local with your lines replaced"

# --- what sudo can't safely load ---
set_up() {
    reset
    put_reattach
    answer yes
    assert_exit 0 main
    : > "$STUB_LOG"
}

# A copy others could swap, which main replaces: <case>
for unsafe in writable symlink; do
    set_up
    rm -f "$MODULE"
    case "$unsafe" in
        writable) cp "$SOURCE" "$MODULE" && chmod 664 "$MODULE" ;;
        symlink) ln -s "$SOURCE" "$MODULE" ;;
    esac
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $MODULE, which sudo loads, isn't a root-owned copy of Homebrew's pam-reattach module; re-run just touch-id"
    assert_exit 0 main
    assert_file_contains "$STUB_LOG" "sudo mv -fh $MODULE.new $MODULE"
    [ ! -L "$MODULE" ] && [ -f "$MODULE" ] || fail "the $unsafe module wasn't replaced with a copy"
    assert_eq "-r--r--r--" "$(/bin/ls -l "$MODULE" | cut -c 1-10)" "the copy's mode after replacing the $unsafe one"
    assert_eq "reattach 1.0" "$(cat "$SOURCE")" "Homebrew's module, after replacing the $unsafe copy"
done

# What main can't fix, and so refuses with no sudo: <case>
DIR="$DOTFILES_PAM_LOCAL_MODULES_DIR"
for unsafe in dir-writable dir-owner dir-symlink dir-acl module-acl no-homebrew module-2-link module-2; do
    set_up
    path="$DIR" reason=""
    case "$unsafe" in
        dir-writable)
            chmod 775 "$DIR"
            reason="isn't root's alone to write; run sudo chown root $DIR && sudo chmod go-w $DIR"
            ;;
        dir-owner)
            # shellcheck disable=SC2034 # macos/lib/pam.sh reads it; reset restores it
            PAM_ROOT_UID=99999
            reason="isn't root's alone to write; run sudo chown root $DIR"
            ;;
        dir-symlink)
            mv "$DIR" "$SANDBOX/real-pam"
            ln -s "$SANDBOX/real-pam" "$DIR"
            reason="is a symlink; remove it with sudo rm $DIR"
            ;;
        dir-acl | module-acl)
            [ "$unsafe" == dir-acl ] || path="$MODULE"
            chmod +a "everyone allow add_file,delete_child" "$path" 2> /dev/null ||
                chmod +a "everyone allow write,append" "$path"
            reason="has an ACL entry that lets others write it; remove it with sudo chmod -N $path"
            ;;
        no-homebrew)
            # Without Homebrew's copy, an unsafe copy can't be fixed
            rm -rf "$SANDBOX/brew"
            chmod 664 "$MODULE"
            ;;
        module-2-link)
            # Refused even dangling
            ln -s "$SANDBOX/nowhere" "$MODULE.2"
            ;;
        module-2)
            # OpenPAM loads it instead of the copy; setup didn't install it, so it isn't deleted
            echo "old reattach" > "$MODULE.2"
            ;;
    esac
    message="sudo can't safely load $MODULE: $path $reason"
    case "$unsafe" in
        no-homebrew) message="$MODULE, which sudo loads, isn't root's alone to write; run brew install pam-reattach, then just touch-id" ;;
        module-2 | module-2-link) message="$MODULE.2 exists, and OpenPAM loads it instead of the copy; remove it with sudo rm $MODULE.2, then re-run just touch-id" ;;
    esac
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Touch ID in tmux: $message"
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "Touch ID in tmux: $message"
    assert_file_not_contains "$STUB_LOG" "sudo"
    [ "$unsafe" != module-2-link ] || [ -L "$MODULE.2" ] || fail "the linked pam_reattach.so.2 was removed"
done
assert_eq "old reattach" "$(cat "$MODULE.2")" "pam_reattach.so.2"

# An ACL entry that denies, or only lets others read, is harmless
set_up
chmod +a "everyone deny write,delete" "$MODULE"
chmod +a "everyone allow read,readattr" "$DIR"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"
chmod -N "$MODULE" "$DIR"

# A dangling module link isn't loaded, so it doesn't block Touch ID alone
set_up
rm -rf "$SANDBOX/brew" "$MODULE"
ln -s "$SANDBOX/nowhere" "$MODULE"
assert_exit 0 main
assert_eq "$HEADER
$TID_LINE" "$(cat "$SUDO_LOCAL")" "sudo_local beside a dangling link"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    Touch ID in tmux: pam-reattach isn't installed"
assert_not_contains "$RUN_OUTPUT" "missing"

# A copy that fails, or that others could swap after install, stops before sudo_local could name it
copy_fails() {
    reset
    put_reattach
    answer yes
    case "$1" in
        unsafe)
            replace_fn install_reattach_module 'mkdir -p "$DOTFILES_PAM_LOCAL_MODULES_DIR"
cp "$SOURCE" "$MODULE"
chmod 666 "$MODULE"'
            message="sudo can't safely load $MODULE: $MODULE isn't root's alone to write"
            ;;
        failed)
            stub sudo 'exit 1'
            message="Couldn't install $MODULE"
            ;;
    esac
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "$message"
    [ ! -e "$SUDO_LOCAL" ] || fail "sudo_local was written though the copy $1"
}
# failed last: its sudo stub outlives the subtest
for case_name in unsafe failed; do
    subtest copy_fails "$case_name"
done
test_done
