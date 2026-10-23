#!/bin/bash
set -euo pipefail

# The ssh step: keychain key loading on macOS (Host * block and LaunchAgent), parsed as ssh does.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ssh/install.sh
as_os macos
stub launchctl '[ "$1" != print ] || exit 113'
# Your real home isn't the sandbox's
stub dscl 'echo "NFSHomeDirectory: /Users/me"'

host_star_count() {
    grep -c '^Host \*$' "$SSH_CONFIG" || true
}

assert_exit 0 main
assert_eq 1 "$(host_star_count)" "Host * blocks after the first run"
# Non-Apple ssh rejects UseKeychain without IgnoreUnknown above it
if ssh_bin="$(command -v ssh)"; then
    assert_exit 0 "$ssh_bin" -F "$SSH_CONFIG" -G example.com
fi
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already loads keys"
assert_eq 1 "$(host_star_count)" "Host * blocks after the second run"

# A user's Host * block is never edited
printf 'Host *\n  ServerAliveInterval 60\n\nHost github.com\n  User git\n' > "$SSH_CONFIG"
snapshot "$SSH_CONFIG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "$(printf '    IgnoreUnknown UseKeychain\n    AddKeysToAgent yes\n    UseKeychain yes')"
assert_unchanged "$SSH_CONFIG" "with your Host * block"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The Host * block in ~/.ssh/config has IgnoreUnknown UseKeychain, AddKeysToAgent, and UseKeychain; add IgnoreUnknown UseKeychain and AddKeysToAgent yes and UseKeychain yes to the top of it by hand"

# ssh reads in order: IgnoreUnknown must precede UseKeychain
printf 'Host *\n  UseKeychain yes\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n' > "$SSH_CONFIG"
assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing with UseKeychain first"
# ssh keeps only the first IgnoreUnknown that applies
printf 'Host *\n  IgnoreUnknown ControlPersistX\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing after another IgnoreUnknown"
# A commented-out line doesn't count
printf 'Host *\n  # IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing with IgnoreUnknown commented out"

# Only Host * alone counts as global, however it's written
printf 'Host * !box\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_eq "$(printf '  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes')" "$(host_star_missing)" \
    "the lines missing after Host * !box"
printf 'Host=*\n  IgnoreUnknown=UseKeychain\n  AddKeysToAgent yes\n  UseKeychain=yes\n' > "$SSH_CONFIG"
assert_eq "" "$(host_star_missing)" "the lines missing after Host=*"
printf 'host *\n  ignoreunknown foo,usekeychain\n  addkeystoagent yes\n  usekeychain yes\n' > "$SSH_CONFIG"
assert_eq "" "$(host_star_missing)" "the lines missing after host *"

# A UseKeychain above Host * needs IgnoreUnknown at the top of the file
printf 'Host github.com\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_exit 0 main
assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing after a UseKeychain above Host *"
ignore_unknown_at_top || fail "a UseKeychain above Host * didn't call for IgnoreUnknown at the top"
assert_exit 0 main
assert_eq 1 "$(host_star_count)" "Host * blocks after a UseKeychain above Host *"

# Settings above the first Host or Match line apply to every host
printf 'IgnoreUnknown UseKeychain\nAddKeysToAgent yes\nUseKeychain yes\n\nHost box\n  User me\n' > "$SSH_CONFIG"
snapshot "$SSH_CONFIG"
assert_eq "" "$(host_star_missing)" "the lines missing with the settings above every Host line"
assert_exit 0 main
assert_unchanged "$SSH_CONFIG" "with the settings above every Host line"

# A sandbox HOME isn't the real one, so the agent isn't loaded
AGENT="$HOME/Library/LaunchAgents/dotfiles.ssh-add.plist"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "launchctl bootstrap"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The dotfiles.ssh-add LaunchAgent is loaded"

replace_fn home_is_real 'return 0'
stub launchctl 'case "$1" in print) exit 113 ;; bootstrap) exit 5 ;; esac'
assert_exit 1 main
assert_file_contains "$STUB_LOG" "launchctl bootstrap gui/$(id -u) $AGENT"
stub launchctl 'case "$1" in
    print) [ -e "'"$SANDBOX"'/loaded" ] ;;
    bootstrap) touch "'"$SANDBOX"'/loaded" ;;
esac'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Loaded the dotfiles.ssh-add LaunchAgent"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         The dotfiles.ssh-add LaunchAgent is loaded"

# A Match line with * isn't a Host * block
printf 'Match host *.corp.example exec "true"\n  User me\n' > "$SSH_CONFIG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Added a Host * block"
assert_eq 1 "$(host_star_count)" "Host * blocks after a Match line with *"

: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already loaded"
assert_file_not_contains "$STUB_LOG" "launchctl bootstrap"

# A failed copy fails even when the agent is already loaded
copy_failure() {
    replace_fn copy_file 'return 1'
    install_ssh_add_agent || return 1
}
assert_exit 1 copy_failure

as_os ubuntu
rm -rf "$HOME/.ssh" "$HOME/Library"
: > "$STUB_LOG"
assert_exit 0 main
[ ! -e "$SSH_CONFIG" ] || fail "Ubuntu got $SSH_CONFIG: $(cat "$SSH_CONFIG")"
[ ! -e "$AGENT" ] || fail "Ubuntu got the LaunchAgent"
assert_file_not_contains "$STUB_LOG" "launchctl"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    A Host * block that loads keys from the keychain: macOS only"
assert_contains "$RUN_OUTPUT" "skipped    The dotfiles.ssh-add LaunchAgent: macOS only"
assert_contains "$RUN_OUTPUT" "ok         Only you can read ~/.ssh (mode 700)"
printf 'Host box\n  User me\n' > "$SSH_CONFIG"
snapshot "$SSH_CONFIG"
assert_exit 0 main
assert_unchanged "$SSH_CONFIG" "on Ubuntu"
assert_eq 600 "$(file_mode "$SSH_CONFIG")" "the config's mode"
# Too open a mode is fixed; a symlink is judged by its target
for case in "755 $HOME/.ssh 700" "644 $SSH_CONFIG 600"; do
    read -r bad path mode <<< "$case"
    label="Only you can read ~${path#"$HOME"} (mode $mode)"
    chmod "$bad" "$path"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    $label"
    assert_exit 0 main
    assert_exit 0 main --status
    mv "$path" "$SANDBOX/real"
    ln -s "$SANDBOX/real" "$path"
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         $label"
    rm "$path"
    mv "$SANDBOX/real" "$path"
done
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "/.ssh and its config are already private"

# An unwritable config fails; main runs it under ||, which turns set -e off inside it
add_host_star_checked() {
    add_host_star || return 1
}
for content in '' 'Host box\n  User me\n'; do
    rm -f "$SSH_CONFIG"
    # shellcheck disable=SC2059 # the content holds \n
    printf "$content" > "$SSH_CONFIG"
    if as_unwritable "$SSH_CONFIG" add_host_star_checked; then
        assert_not_contains "$RUN_OUTPUT" "Added"
    fi
done
test_done
