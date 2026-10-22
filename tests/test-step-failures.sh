#!/bin/bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

# --- macos ---
# A write to a domain listed in $SANDBOX/defaults-fail fails
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
stub scutil 'echo Garvits-MacBook-Pro'
stub pgrep 'exit 1'
fail_defaults() {
    printf '%s\n' "$@" > "$SANDBOX/defaults-fail"
}

load_script macos/install.sh
as_os macos
replace_fn hotkey_off true
# test-macos-security.sh covers these sudo items
replace_fn firewall_on true
replace_fn stealth_mode_on true
replace_fn app_store_auto_updates true

fail_defaults com.apple.finder
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't set com.apple.finder AppleShowAllFiles"
assert_contains "$RUN_OUTPUT" "Set com.apple.dock autohide to true"
assert_file_contains "$STUB_LOG" "killall Dock"

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
stub_sudo_cacheable
assert_exit 1 sudo -n touch "$SANDBOX/by-sudo"
[ ! -e "$SANDBOX/by-sudo" ] || fail "sudo -n ran touch without cached credentials"
cache_sudo yes
assert_exit 0 sudo -n touch "$SANDBOX/by-sudo"
[ -e "$SANDBOX/by-sudo" ] || fail "the sudo stub didn't run touch"
assert_exit 1 sudo install -m 0644 /dev/null /usr/lib/dotfiles-test/by-sudo
assert_contains "$RUN_OUTPUT" "refused: /usr/lib/dotfiles-test/by-sudo is outside the sandbox"
assert_exit 1 sudo env DEST=/etc/by-sudo true
assert_contains "$RUN_OUTPUT" "refused: DEST=/etc/by-sudo is outside the sandbox"
cache_sudo no
stub chsh
load_script zsh/install.sh
replace_fn current_login_shell 'echo /bin/bash'
replace_fn login_zsh_path 'echo "$SANDBOX/bin/zsh"'

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Login shell left as /bin/bash"
assert_file_contains "$HOME/.zshrc" "source \$HOME/.zsh/main.zsh"

: > "$STUB_LOG"
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "chsh -s $SANDBOX/bin/zsh"
assert_file_not_contains "$STUB_LOG" "sudo -n chsh"

: > "$STUB_LOG"
cache_sudo yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo -n chsh -s $SANDBOX/bin/zsh $(id -un)"

stub chsh 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run manually: chsh -s $SANDBOX/bin/zsh"
cache_sudo no
stub chsh
unset DOTFILES_ASSUME_YES

replace_fn current_login_shell 'echo /bin/zsh'
replace_fn login_zsh_path 'echo /bin/zsh'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "zsh is already the login shell."
run status
assert_contains "$RUN_OUTPUT" "ok         /bin/zsh as the login shell"

# As Ubuntu's /bin/zsh is /usr/bin/zsh
mkdir -p "$SANDBOX/usr/bin"
touch "$SANDBOX/usr/bin/zsh"
ln -s usr/bin "$SANDBOX/merged-bin"
replace_fn current_login_shell 'echo "$SANDBOX/merged-bin/zsh"'
replace_fn login_zsh_path 'echo "$SANDBOX/usr/bin/zsh"'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "zsh is already the login shell."
replace_fn login_zsh_path 'echo /bin/zsh'

replace_fn current_login_shell 'echo /opt/homebrew/bin/zsh'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    /bin/zsh as the login shell: it's /opt/homebrew/bin/zsh"

# --- ghostty ---
stub pkill 'exit 1'
load_script ghostty/install.sh
as_os ubuntu

# A missing prerequisite fails the step before it changes anything
hide snap
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "snap isn't installed. Install it with: sudo apt install snapd"
[ ! -e "$GHOSTTY_DIR/config.ghostty" ] || fail "the ghostty config was copied without snapd"
run status
assert_contains "$RUN_OUTPUT" "unknown    Ghostty snap: snap isn't installed"

stub snap 'exit 1'
rm -f "$GHOSTTY_DIR/config.ghostty"
export DOTFILES_ASSUME_YES=1
assert_exit 1 main
assert_file_contains "$STUB_LOG" "sudo snap install ghostty --classic"
assert_eq "" "$(cmp "$REPO_DIR/ghostty/config.ghostty" "$GHOSTTY_DIR/config.ghostty" 2>&1)" "ghostty config copied"
unset DOTFILES_ASSUME_YES

# --- one file that can't be copied ---
if [ "$(id -u)" -ne 0 ]; then
    stub chsh
    load_script zsh/install.sh
    replace_fn current_login_shell 'echo /bin/zsh'
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
