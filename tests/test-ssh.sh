#!/bin/bash
set -euo pipefail

# The ssh step: keychain key loading on macOS (Host * block and LaunchAgent), parsed as ssh does.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ssh/install.sh
as_os macos
stub launchctl '[ "$1" != print ] || exit 113'

host_star_count() {
    grep -c '^Host \*$' "$SSH_CONFIG" || true
}

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Added a Host * block"
assert_eq 1 "$(host_star_count)" "Host * blocks after the first run"
assert_eq "$(printf 'Host *\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes')" \
    "$(cat "$SSH_CONFIG")" "the config after the first run"
# Non-Apple ssh rejects UseKeychain without IgnoreUnknown above it
if ssh_bin="$(command -v ssh)"; then
    assert_exit 0 "$ssh_bin" -F "$SSH_CONFIG" -G example.com
fi
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already loads keys"
assert_eq 1 "$(host_star_count)" "Host * blocks after the second run"

# A user's Host * block is never edited
printf 'Host *\n  ServerAliveInterval 60\n\nHost github.com\n  User git\n' > "$SSH_CONFIG"
cp "$SSH_CONFIG" "$SANDBOX/before"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "$(printf '    IgnoreUnknown UseKeychain\n    AddKeysToAgent yes\n    UseKeychain yes')"
assert_exit 0 cmp -s "$SANDBOX/before" "$SSH_CONFIG"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    The Host * block in ~/.ssh/config has IgnoreUnknown UseKeychain, AddKeysToAgent, and UseKeychain; add IgnoreUnknown UseKeychain and AddKeysToAgent yes and UseKeychain yes to the top of it by hand"

printf 'host *\n  ignoreunknown foo,usekeychain\n  usekeychain yes\n' > "$SSH_CONFIG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "  AddKeysToAgent yes"
assert_not_contains "$RUN_OUTPUT" "UseKeychain"
printf 'Host *\n  AddKeysToAgent yes\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing without IgnoreUnknown"
# ssh reads in order: IgnoreUnknown must precede UseKeychain and name it
for config in 'Host *\n  UseKeychain yes\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n' \
    'Host box\n  UseKeychain yes\nHost *\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n' \
    'Host *\n  IgnoreUnknown UseKeychainX\n  AddKeysToAgent yes\n  UseKeychain yes\n' \
    'Host *\n  # IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n'; do
    # shellcheck disable=SC2059 # the config holds \n
    printf "$config" > "$SSH_CONFIG"
    assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing with: $config"
done

# ssh keeps only the first IgnoreUnknown that applies
printf 'Host *\n  IgnoreUnknown ControlPersistX\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing after another IgnoreUnknown"
config='IgnoreUnknown ControlPersistX\nHost *\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n'
# shellcheck disable=SC2059 # the config holds \n
printf "$config" > "$SSH_CONFIG"
assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing after a global IgnoreUnknown"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "$(printf '  line, so add this line at the top of %s:\n    IgnoreUnknown UseKeychain' "$SSH_CONFIG")"
assert_not_contains "$RUN_OUTPUT" "to the top of it"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "UseKeychain; add IgnoreUnknown UseKeychain at the top of the file by hand"

# A UseKeychain above Host * needs IgnoreUnknown at the top of the file
printf 'Host github.com\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Added a Host * block"
assert_contains "$RUN_OUTPUT" "$(printf '  line, so add this line at the top of %s:\n    IgnoreUnknown UseKeychain' "$SSH_CONFIG")"
assert_eq '  IgnoreUnknown UseKeychain' "$(host_star_missing)" "the lines missing after a UseKeychain above Host *"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "to the top of it"
assert_contains "$RUN_OUTPUT" "at the top of $SSH_CONFIG:"
assert_eq 1 "$(host_star_count)" "Host * blocks after a UseKeychain above Host *"
printf 'Host github.com\n  UseKeychain yes\nHost *\n  User me\n' > "$SSH_CONFIG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "$(printf 'add these lines to the top of it:\n    AddKeysToAgent yes\n    UseKeychain yes\n')"
assert_contains "$RUN_OUTPUT" "at the top of $SSH_CONFIG:"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "UseKeychain; add AddKeysToAgent yes and UseKeychain yes to the top of it and IgnoreUnknown UseKeychain at the top of the file by hand"
printf 'IgnoreUnknown UseKeychain\n' | cat - "$SSH_CONFIG" > "$SANDBOX/config"
printf '  AddKeysToAgent yes\n  UseKeychain yes\n' >> "$SANDBOX/config"
mv "$SANDBOX/config" "$SSH_CONFIG"
assert_eq "" "$(host_star_missing)" "the lines missing after following the advice"
run status_host_star
assert_contains "$RUN_OUTPUT" "ok         The Host * block"
if [ -n "${ssh_bin:-}" ]; then
    assert_exit 0 "$ssh_bin" -F "$SSH_CONFIG" -G example.com
fi

# Settings above the first Host or Match line apply to every host
printf 'IgnoreUnknown UseKeychain\nAddKeysToAgent yes\nUseKeychain yes\n\nHost box\n  User me\n' > "$SSH_CONFIG"
cp "$SSH_CONFIG" "$SANDBOX/before"
assert_eq "" "$(host_star_missing)" "the lines missing with the settings above every Host line"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already loads keys"
assert_exit 0 cmp -s "$SANDBOX/before" "$SSH_CONFIG"
run status
assert_contains "$RUN_OUTPUT" "ok         The Host * block in ~/.ssh/config has IgnoreUnknown UseKeychain, AddKeysToAgent, and UseKeychain"
printf 'IgnoreUnknown UseKeychain\nUseKeychain yes\nHost box\n  User me\n' > "$SSH_CONFIG"
assert_eq '  AddKeysToAgent yes' "$(host_star_missing)" "the lines missing with UseKeychain above every Host line"

# A sandbox HOME isn't the real one, so the agent isn't loaded
AGENT="$HOME/Library/LaunchAgents/dotfiles.ssh-add.plist"
: > "$STUB_LOG"
assert_exit 0 main
assert_exit 0 cmp -s "$REPO_DIR/ssh/dotfiles.ssh-add.plist" "$AGENT"
assert_file_not_contains "$STUB_LOG" "launchctl bootstrap"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.ssh-add.plist"
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
assert_exit 0 status
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
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    A Host * block that loads keys from the keychain: macOS only"
assert_contains "$RUN_OUTPUT" "skipped    The dotfiles.ssh-add LaunchAgent: macOS only"
assert_contains "$RUN_OUTPUT" "ok         Only you can read ~/.ssh (mode 700)"
printf 'Host box\n  User me\n' > "$SSH_CONFIG"
cp "$SSH_CONFIG" "$SANDBOX/before"
assert_exit 0 main
assert_exit 0 cmp -s "$SANDBOX/before" "$SSH_CONFIG"
assert_eq 600 "$(file_mode "$SSH_CONFIG")" "the config's mode"
chmod 755 "$HOME/.ssh"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Only you can read ~/.ssh (mode 700)"
assert_exit 0 main
assert_exit 0 status
chmod 644 "$SSH_CONFIG"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Only you can read ~/.ssh/config (mode 600)"
assert_exit 0 main
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Only you can read ~/.ssh/config (mode 600)"
# Symlinks are judged by their targets
mv "$HOME/.ssh" "$SANDBOX/ssh-real"
ln -s "$SANDBOX/ssh-real" "$HOME/.ssh"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Only you can read ~/.ssh (mode 700)"
rm "$HOME/.ssh"
mv "$SANDBOX/ssh-real" "$HOME/.ssh"
mv "$SSH_CONFIG" "$SANDBOX/ssh-config"
ln -s "$SANDBOX/ssh-config" "$SSH_CONFIG"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Only you can read ~/.ssh/config (mode 600)"
rm "$SSH_CONFIG"
mv "$SANDBOX/ssh-config" "$SSH_CONFIG"

host_line_case() {
    printf '%s\n' "$1" > "$SSH_CONFIG"
    assert_exit "$3" host_line "$2"
    [ "$RUN_STATUS" == "$3" ] || echo "    for: $1" >&2
}
host_line_case 'Host box other' other 0
host_line_case '  host * !bastion' '*' 0
host_line_case 'Host boxer' box 1
host_line_case 'Host Box' box 1
host_line_case 'Host other # box' box 1
host_line_case 'Match host box' box 1
printf 'Host other # *\n  AddKeysToAgent yes\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_contains "$(host_star_missing)" 'AddKeysToAgent yes'
assert_contains "$(host_star_missing)" 'UseKeychain yes'
printf 'Host *\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  #UseKeychain yes\n' > "$SSH_CONFIG"
assert_eq '  UseKeychain yes' "$(host_star_missing)" "the lines missing with UseKeychain commented out"

# A comment right above the catch-all goes with it
for line in "Match canonical all" "Match final all" "Match all # defaults" "Match = all" \
    'Match "final" all' "Host * # every host"; do
    printf 'Host other\n  User other\n\n# defaults\n%s\n  AddKeysToAgent no\n' "$line" > "$SSH_CONFIG"
    assert_eq 4 "$(catch_all_line)" "the catch-all's line with: $line"
done
for line in "Match all host other" "Match canonical" "# Match all" "Host other # *"; do
    printf 'Host other\n  User other\n\n%s\n  AddKeysToAgent no\n' "$line" > "$SSH_CONFIG"
    assert_eq "" "$(catch_all_line)" "the catch-all's line with: $line"
done

# Only Host * alone counts as global
for line in 'Host = box' 'Host * !box'; do
    printf '%s\n  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes\n' "$line" > "$SSH_CONFIG"
    assert_eq "$(printf '  IgnoreUnknown UseKeychain\n  AddKeysToAgent yes\n  UseKeychain yes')" \
        "$(host_star_missing)" "the lines missing after: $line"
done
for line in 'Host=*' 'host *'; do
    printf '%s\n  IgnoreUnknown=UseKeychain\n  AddKeysToAgent yes\n  UseKeychain=yes\n' "$line" > "$SSH_CONFIG"
    assert_eq "" "$(host_star_missing)" "the lines missing after: $line"
done
printf 'Host * !bastion\n  AddKeysToAgent yes\n' > "$SSH_CONFIG"
assert_exit 0 add_host_star
assert_contains "$RUN_OUTPUT" "Added a Host * block"
assert_eq 1 "$(host_star_count)" "Host * blocks after Host * !bastion"
run status_host_star
assert_contains "$RUN_OUTPUT" "ok         The Host * block in ~/.ssh/config has IgnoreUnknown UseKeychain, AddKeysToAgent, and UseKeychain"

# An unwritable config fails; main runs it under ||, which turns set -e off inside it
add_host_star_checked() {
    add_host_star || return 1
}
if [ "$(id -u)" -ne 0 ]; then
    for content in '' 'Host box\n  User me\n'; do
        rm -f "$SSH_CONFIG"
        # shellcheck disable=SC2059 # the content holds \n
        printf "$content" > "$SSH_CONFIG"
        chmod 444 "$SSH_CONFIG"
        assert_exit 1 add_host_star_checked
        assert_not_contains "$RUN_OUTPUT" "Added"
        chmod 600 "$SSH_CONFIG"
    done
fi
test_done
