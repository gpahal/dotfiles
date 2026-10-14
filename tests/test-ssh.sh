#!/bin/bash
set -euo pipefail

# On macOS the ssh step makes the agent load keys from the keychain: a Host * block with
# AddKeysToAgent and UseKeychain, and a LaunchAgent that runs ssh-add --apple-load-keychain at
# login. It never edits a Host * block you wrote. Ubuntu has no keychain, so it skips both.
# add_block, from ssh/lib/hosts.sh, which ssh/add-host.sh uses, puts a block above the first
# catch-all.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ssh/install.sh
# shellcheck disable=SC2329 # main and status call them
is_macos() { true; }
# shellcheck disable=SC2329
is_ubuntu() { false; }
# launchctl print fails: nothing is loaded
stub launchctl '[ "$1" != print ] || exit 113'

host_star_count() {
    grep -c '^Host \*$' "$SSH_CONFIG" || true
}

# A new config gets a Host * block, once
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Added a Host * block"
assert_eq 1 "$(host_star_count)" "Host * blocks after the first run"
assert_file_contains "$SSH_CONFIG" "  AddKeysToAgent yes"
assert_file_contains "$SSH_CONFIG" "  UseKeychain yes"
assert_eq "Host *" "$(grep '^Host' "$SSH_CONFIG" | tail -1)" "the last Host line"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already loads keys"
assert_eq 1 "$(host_star_count)" "Host * blocks after the second run"

# Your own Host * block without the settings is left alone: the step prints what to add, and
# status reports it missing
printf 'Host *\n  ServerAliveInterval 60\n\nHost github.com\n  User git\n' > "$SSH_CONFIG"
cp "$SSH_CONFIG" "$SANDBOX/before"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "  AddKeysToAgent yes"
assert_contains "$RUN_OUTPUT" "  UseKeychain yes"
assert_exit 0 cmp -s "$SANDBOX/before" "$SSH_CONFIG"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    The Host * block in ~/.ssh/config has AddKeysToAgent and UseKeychain; add AddKeysToAgent yes and UseKeychain yes to it by hand"

# With one setting, it prints only the other
printf 'host * !box\n  usekeychain yes\n' > "$SSH_CONFIG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "  AddKeysToAgent yes"
assert_not_contains "$RUN_OUTPUT" "  UseKeychain yes"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "UseKeychain; add AddKeysToAgent yes to it by hand"

# With both, there's nothing to add
printf 'Host *\n  AddKeysToAgent yes\n  UseKeychain yes\n' > "$SSH_CONFIG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "AddKeysToAgent"
run status
assert_contains "$RUN_OUTPUT" "ok         The Host * block in ~/.ssh/config has AddKeysToAgent and UseKeychain"

# Settings above the first Host or Match line apply to every host, as a Host * block's do, so
# they count, and no block is added
printf 'AddKeysToAgent yes\nUseKeychain yes\n\nHost box\n  User me\n' > "$SSH_CONFIG"
cp "$SSH_CONFIG" "$SANDBOX/before"
assert_eq "" "$(host_star_missing)" "the lines missing with the settings above every Host line"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already loads keys"
assert_exit 0 cmp -s "$SANDBOX/before" "$SSH_CONFIG"
run status
assert_contains "$RUN_OUTPUT" "ok         The Host * block in ~/.ssh/config has AddKeysToAgent and UseKeychain"
# One of them there still leaves the other to add
printf 'UseKeychain yes\nHost box\n  User me\n' > "$SSH_CONFIG"
assert_eq '  AddKeysToAgent yes' "$(host_star_missing)" "the lines missing with UseKeychain above every Host line"

# The LaunchAgent is copied. HOME isn't your real home here, so it isn't loaded into your session.
AGENT="$HOME/Library/LaunchAgents/dotfiles.ssh-add.plist"
: > "$STUB_LOG"
assert_exit 0 main
assert_exit 0 cmp -s "$REPO_DIR/ssh/dotfiles.ssh-add.plist" "$AGENT"
assert_file_not_contains "$STUB_LOG" "launchctl bootstrap"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "ok         ~/Library/LaunchAgents/dotfiles.ssh-add.plist"
assert_contains "$RUN_OUTPUT" "missing    The dotfiles.ssh-add LaunchAgent is loaded"

# In your real home, it's loaded, and a failed load fails the step
home_is_real() { true; }
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

# A Match line that mentions * isn't a Host * block, so the block is still added
printf 'Match host *.corp.example exec "true"\n  User me\n' > "$SSH_CONFIG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Added a Host * block"
assert_eq 1 "$(host_star_count)" "Host * blocks after a Match line with *"

# Already loaded, it isn't loaded again
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already loaded"
assert_file_not_contains "$STUB_LOG" "launchctl bootstrap"

# A failed copy must fail even when launchctl reports an already loaded agent.
copy_failure() {
    # shellcheck disable=SC2329
    copy_file() { return 1; }
    install_ssh_add_agent || return 1
}
assert_exit 1 copy_failure

# Ubuntu gets no Host * block and no LaunchAgent, and an existing config keeps its lines
# shellcheck disable=SC2329 # main and status call them
is_macos() { false; }
# shellcheck disable=SC2329
is_ubuntu() { true; }
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
# Readable by others, ~/.ssh is reported, and the step fixes it
chmod 755 "$HOME/.ssh"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Only you can read ~/.ssh (mode 700)"
assert_exit 0 main
assert_exit 0 status
# A symlinked ~/.ssh is judged by the directory it points to
mv "$HOME/.ssh" "$SANDBOX/ssh-real"
ln -s "$SANDBOX/ssh-real" "$HOME/.ssh"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Only you can read ~/.ssh (mode 700)"
rm "$HOME/.ssh"
mv "$SANDBOX/ssh-real" "$HOME/.ssh"

# A Host line counts when it lists the pattern itself, before any comment, and case matters
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
# A commented-out setting in the Host * block, which ssh ignores, doesn't count
printf 'Host *\n  AddKeysToAgent yes\n  #UseKeychain yes\n' > "$SSH_CONFIG"
assert_eq '  UseKeychain yes' "$(host_star_missing)" "the lines missing with UseKeychain commented out"

# add_block puts a block above the first catch-all, and its comment, so the catch-all doesn't win
# over it. tests/test-ssh-add-host.sh checks what ssh itself resolves.
line_of() { grep -nxF "$1" "$SSH_CONFIG" | head -n 1 | cut -d: -f1; }
printf 'Host other\n  User other\n\n# Defaults\nHost *\n  AddKeysToAgent no\n' > "$SSH_CONFIG"
assert_exit 0 add_block "Host box"
[ "$(line_of "Host box")" -lt "$(line_of "# Defaults")" ] ||
    fail "the block went after Host *: $(cat "$SSH_CONFIG")"

# A config add_block can't replace: it fails, and the new contents stay where it says they are
if [ "$(id -u)" -ne 0 ]; then
    printf 'Host other\n  User me\n' > "$SSH_CONFIG"
    chmod 500 "$HOME/.ssh"
    assert_exit 1 add_block "Host box"
    chmod 700 "$HOME/.ssh"
    kept="$(sed -n 's/.*The new contents are in \(.*\)\.$/\1/p' <<< "$RUN_OUTPUT")"
    [ -n "$kept" ] && [ -f "$kept" ] || fail "the new contents a failed write named are gone: '$kept'"
    [ -z "$kept" ] || assert_file_contains "$kept" "Host box"
fi

# catch_all_line reads lines without their comments, and counts a Match all after canonical or
# final. A comment right above the catch-all goes with it.
for line in "Match canonical all" "Match final all" "Match all # defaults" "Match = all" \
    'Match "final" all' "Host * # every host"; do
    printf 'Host other\n  User other\n\n# defaults\n%s\n  AddKeysToAgent no\n' "$line" > "$SSH_CONFIG"
    assert_eq 4 "$(catch_all_line)" "the catch-all's line with: $line"
done
for line in "Match all host other" "Match canonical" "# Match all" "Host other # *"; do
    printf 'Host other\n  User other\n\n%s\n  AddKeysToAgent no\n' "$line" > "$SSH_CONFIG"
    assert_eq "" "$(catch_all_line)" "the catch-all's line with: $line"
done

# A failed Host * block doesn't stop the rest under set -e, which run turns on, and fails the step
is_macos() { true; }
is_ubuntu() { false; }
rm "$SSH_CONFIG"
add_host_star() { return 1; }
install_ssh_add_agent() { echo "LaunchAgent installed"; }
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "LaunchAgent installed"
test_done
