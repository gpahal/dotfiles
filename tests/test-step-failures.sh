#!/bin/bash
# The steps' functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# A step that didn't do its job fails, after doing what else it can; a declined confirm doesn't, and
# neither does a run with nothing to do. Covers macos, zsh, and ghostty, with stubs for defaults,
# chsh, and snap. test-macos-shortcuts.sh and test-macos-activity-monitor.sh cover the macos step's
# re-run.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# --- macos ---
# A defaults that keeps each value in a file, printing bools as 1 or 0 the way defaults read
# does. A write to a domain listed in $SANDBOX/defaults-fail fails.
DEFAULTS_DIR="$SANDBOX/defaults"
mkdir -p "$DEFAULTS_DIR"
: > "$SANDBOX/defaults-fail"
stub defaults 'file="'"$DEFAULTS_DIR"'/$2.$3"
case "$1" in
    read) [ -f "$file" ] && cat "$file" ;;
    write)
        ! grep -qxF "$2" "'"$SANDBOX"'/defaults-fail" || exit 1
        value="$5"
        [ "$4" != -bool ] || { [ "$5" == true ] && value=1 || value=0; }
        printf "%s\n" "$value" > "$file"
        ;;
esac'
stub killall
# test-macos-hostname.sh covers the hostname
stub scutil 'echo Garvits-MacBook-Pro'
# Activity Monitor isn't running, so the step writes its setting
stub pgrep 'exit 1'
fail_defaults() {
    printf '%s\n' "$@" > "$SANDBOX/defaults-fail"
}

load_script macos/install.sh
is_macos() { true; }
# test-macos-shortcuts.sh covers the shortcuts the step turns off
hotkey_off() { true; }

# A failed write fails the step, after the other writes and the restarts
fail_defaults com.apple.finder
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't set com.apple.finder AppleShowAllFiles"
assert_contains "$RUN_OUTPUT" "Set com.apple.dock autohide to true"
assert_file_contains "$STUB_LOG" "killall Dock"

# A sandboxed app's default that can't be written is a manual step, not a failure
rm -f "$DEFAULTS_DIR"/*
fail_defaults com.apple.TextEdit
mkdir -p "$HOME/Library/Containers/com.apple.TextEdit"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Full Disk Access"
assert_contains "$RUN_OUTPUT" "com.apple.TextEdit RichText"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "already set"
assert_contains "$RUN_OUTPUT" "com.apple.TextEdit RichText"
fail_defaults
rm -rf "$HOME/Library/Containers/com.apple.TextEdit"

# --- zsh ---
# The account's login shell is bash. The step reads it and the zsh to switch to from the system,
# so those two functions are replaced. sudo -n true, which sudo_cached runs, succeeds only with
# SUDO_CACHED set.
# shellcheck disable=SC2016 # expanded by the stub
stub_sudo_exec '[ "$*" != "-n true" ] || [ -n "${SUDO_CACHED:-}" ] || exit 1'
# It runs a command on the sandbox's files, and refuses one on a path outside it, as an argument
# or a value, so a system path the test missed can't be written to
assert_exit 0 sudo -n touch "$SANDBOX/by-sudo"
[ -e "$SANDBOX/by-sudo" ] || fail "the sudo stub didn't run touch"
assert_exit 1 sudo install -m 0644 /dev/null /usr/lib/dotfiles-test/by-sudo
assert_contains "$RUN_OUTPUT" "refused: /usr/lib/dotfiles-test/by-sudo is outside the sandbox"
assert_exit 1 sudo env DEST=/etc/by-sudo true
assert_contains "$RUN_OUTPUT" "refused: DEST=/etc/by-sudo is outside the sandbox"
stub chsh
load_script zsh/install.sh
current_login_shell() { echo /bin/bash; }
login_zsh_path() { echo "$SANDBOX/bin/zsh"; }

# Declined: the files are set up, the login shell isn't, and the step succeeds
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Login shell left as /bin/bash"
assert_file_contains "$HOME/.zshrc" "source \$HOME/.zsh/main.zsh"

# Applied: chsh switches to it
: > "$STUB_LOG"
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "chsh -s $SANDBOX/bin/zsh"
assert_file_not_contains "$STUB_LOG" "sudo -n chsh"

# With sudo cached, chsh runs through sudo -n, so it needs no password
: > "$STUB_LOG"
export SUDO_CACHED=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo -n chsh -s $SANDBOX/bin/zsh $(id -un)"

# A failed chsh fails the step, and prints the command to run
stub chsh 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run manually: chsh -s $SANDBOX/bin/zsh"
unset SUDO_CACHED
stub chsh
unset DOTFILES_ASSUME_YES

# Already the system zsh: nothing to do
current_login_shell() { echo /bin/zsh; }
login_zsh_path() { echo /bin/zsh; }
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "zsh is already the login shell."
run status
assert_contains "$RUN_OUTPUT" "ok         /bin/zsh as the login shell"

# A path to the same file counts, as Ubuntu's /bin/zsh does for /usr/bin/zsh
mkdir -p "$SANDBOX/usr/bin"
touch "$SANDBOX/usr/bin/zsh"
ln -s usr/bin "$SANDBOX/merged-bin"
current_login_shell() { echo "$SANDBOX/merged-bin/zsh"; }
login_zsh_path() { echo "$SANDBOX/usr/bin/zsh"; }
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "zsh is already the login shell."
login_zsh_path() { echo /bin/zsh; }

# Another zsh, such as Homebrew's, isn't the system one, so status reports it
current_login_shell() { echo /opt/homebrew/bin/zsh; }
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    /bin/zsh as the login shell: it's /opt/homebrew/bin/zsh"

# --- ghostty ---
# On Ubuntu. pkill is stubbed, so no running Ghostty gets a signal.
stub pkill 'exit 1'
load_script ghostty/install.sh
is_ubuntu() { true; }
is_macos() { false; }

# No snap command: the config is still copied, and the step fails
hide snap
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sudo apt-get install snapd"
assert_eq "" "$(cmp "$REPO_DIR/ghostty/config.ghostty" "$GHOSTTY_DIR/config.ghostty" 2>&1)" "ghostty config copied"

# A failed install fails the step, after copying the config
stub snap 'exit 1'
rm -f "$GHOSTTY_DIR/config.ghostty"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_file_contains "$STUB_LOG" "sudo snap install ghostty --classic"
assert_eq "" "$(cmp "$REPO_DIR/ghostty/config.ghostty" "$GHOSTTY_DIR/config.ghostty" 2>&1)" "ghostty config copied"
unset DOTFILES_ASSUME_YES

# --- one file that can't be copied ---
# The step carries on with the other files and the rest of its work, then fails. Here one
# destination is a read-only file that differs, so cp can't replace it.
if [ "$(id -u)" -ne 0 ]; then
    stub chsh
    load_script zsh/install.sh
    current_login_shell() { echo /bin/zsh; }
    rm -rf "$HOME/.zsh" "$HOME/.zshrc" "$HOME/.config/starship.toml"
    mkdir -p "$HOME/.zsh"
    printf 'mine\n' > "$HOME/.zsh/aliases.zsh"
    chmod 444 "$HOME/.zsh/aliases.zsh"
    assert_exit 1 main
    assert_eq "" "$(cmp "$REPO_DIR/zsh/main.zsh" "$HOME/.zsh/main.zsh" 2>&1)" "main.zsh after a failed copy"
    [ -f "$HOME/.config/starship.toml" ] || fail "the zsh step stopped before starship.toml"
    assert_file_contains "$HOME/.zshrc" "source \$HOME/.zsh/main.zsh"
    chmod 644 "$HOME/.zsh/aliases.zsh"
fi
test_done
