#!/bin/bash
# The sourced script calls the OS functions this test replaces.
# shellcheck disable=SC2329
set -euo pipefail

# git/setup-signing.sh signs on Ubuntu with a separate passphrase-less key, since the T3 Code
# service's agents have no ssh-agent or terminal to unlock one. On macOS it keeps ~/.ssh/id_ed25519
# and offers to put it in the agent through the keychain. A re-run changes nothing.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script git/setup-signing.sh
is_macos() { false; }
is_ubuntu() { true; }
unset SSH_AUTH_SOCK
SIGNING="$HOME/.ssh/id_ed25519_signing"
ALLOWED="$HOME/.config/git/allowed_signers"

signingkey() {
    git config --file "$HOME/.gitconfig" --get user.signingkey || true
}

# Without a terminal it won't generate the key, and says how
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "ssh-keygen -t ed25519 -N ''"
[ ! -e "$SIGNING" ] || fail "the key was generated without asking"

# Approved, it generates a key without a passphrase, signs with it, and prints the gh command
export DOTFILES_ASSUME_YES=1
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "gh ssh-key add $SIGNING.pub --type signing"
# --insecure-storage keeps the refreshed token in hosts.yml, out of the keyring
assert_contains "$RUN_OUTPUT" "gh auth refresh -h github.com -s admin:ssh_signing_key --insecure-storage"
assert_exit 0 ssh-keygen -y -P '' -f "$SIGNING"
assert_eq "$SIGNING.pub" "$(signingkey)" "user.signingkey"
assert_file_contains "$ALLOWED" "$(awk '{print $2}' "$SIGNING.pub")"

# A commit signs with no agent and no terminal
git init -q "$SANDBOX/repo"
run git -C "$SANDBOX/repo" -c user.name=Test -c user.email=test@example.com \
    commit -q --allow-empty -m signed
assert_eq 0 "$RUN_STATUS" "signed commit exit status: $RUN_OUTPUT"
run git -C "$SANDBOX/repo" log --show-signature -1
assert_contains "$RUN_OUTPUT" 'Good "git" signature'

# A re-run changes nothing
cp "$HOME/.gitconfig" "$SANDBOX/gitconfig-before"
cp "$ALLOWED" "$SANDBOX/allowed-before"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already lists this key"
assert_not_contains "$RUN_OUTPUT" "  Set "
cmp -s "$SANDBOX/gitconfig-before" "$HOME/.gitconfig" || fail ".gitconfig changed on a re-run"
cmp -s "$SANDBOX/allowed-before" "$ALLOWED" || fail "allowed_signers changed on a re-run"
unset DOTFILES_ASSUME_YES

# macOS signs with ~/.ssh/id_ed25519. The agent doesn't hold it, so without a terminal the step
# prints the ssh-add command that stores its passphrase in the keychain.
is_macos() { true; }
is_ubuntu() { false; }
stub ssh-add 'exit 1'
LOGIN="$HOME/.ssh/id_ed25519"
ssh-keygen -q -t ed25519 -N secret -f "$LOGIN"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "run once: ssh-add --apple-use-keychain $LOGIN"
assert_contains "$RUN_OUTPUT" "gh auth refresh -h github.com -s admin:ssh_signing_key"
assert_not_contains "$RUN_OUTPUT" "--insecure-storage"
assert_file_not_contains "$STUB_LOG" "ssh-add --apple-use-keychain"
assert_eq "$LOGIN.pub" "$(signingkey)" "user.signingkey on macOS"

# Approved, it runs it, and a failure fails the step after the rest is set up
export DOTFILES_ASSUME_YES=1
git config --file "$HOME/.gitconfig" --unset commit.gpgsign
assert_exit 1 main
assert_file_contains "$STUB_LOG" "ssh-add --apple-use-keychain $LOGIN"
assert_eq true "$(git config --file "$HOME/.gitconfig" --get commit.gpgsign)" "commit.gpgsign"
assert_eq true "$(git config --file "$HOME/.gitconfig" --get tag.gpgsign)" "tag.gpgsign"

# The agent already holds it: nothing to load, but the keychain command still prints, since the
# agent holding it doesn't mean the keychain has its passphrase
stub ssh-add '[ "$1" != -l ] || echo "256 $(ssh-keygen -lf "'"$LOGIN.pub"'" | cut -d" " -f2) x (ED25519)"'
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The agent already holds $LOGIN"
assert_contains "$RUN_OUTPUT" "ssh-add --apple-use-keychain $LOGIN"
assert_file_not_contains "$STUB_LOG" "ssh-add --apple-use-keychain"

# A .pub that ssh-keygen can't read gives no fingerprint, which grep would find in any agent
# listing. The step says so rather than claim the agent holds the key.
cp "$LOGIN.pub" "$SANDBOX/login-pub"
cp "$ALLOWED" "$SANDBOX/allowed-before-corrupt"
echo corrupt > "$LOGIN.pub"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Can't read the key's fingerprint from $LOGIN.pub."
assert_not_contains "$RUN_OUTPUT" "The agent already holds"
cp "$SANDBOX/login-pub" "$LOGIN.pub"
cp "$SANDBOX/allowed-before-corrupt" "$ALLOWED"

# allowed_signers can't be written: the step says so and fails, rather than claim it lists the key
rm "$ALLOWED"
: > "$ALLOWED"
chmod a-w "$ALLOWED"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't add this key for"
assert_not_contains "$RUN_OUTPUT" "already lists"
chmod u+w "$ALLOWED"

is_macos() { false; }
is_ubuntu() { true; }

# An existing default signing key with a passphrase: agents can't unlock it, so the step fails
# before it reports signing ready, and leaves the key and config as they were, even on a yes. That
# holds whether user.signingkey is unset or already names the key, either half.
rm -f "$HOME/.gitconfig" "$HOME/.gitconfig.local" "$HOME/.config/git/config" "$SIGNING" "$SIGNING.pub"
ssh-keygen -q -t ed25519 -N secret -f "$SIGNING"
cp "$SIGNING" "$SANDBOX/signing-before"
for value in "" "$SIGNING.pub" "$SIGNING"; do
    rm -f "$HOME/.gitconfig"
    [ -z "$value" ] || git config --file "$HOME/.gitconfig" user.signingkey "$value"
    cp "$HOME/.gitconfig" "$SANDBOX/gitconfig-before" 2>/dev/null || : > "$SANDBOX/gitconfig-before"
    DOTFILES_ASSUME_YES=1 assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "$SIGNING has a passphrase"
    assert_contains "$RUN_OUTPUT" "ssh-keygen -p -f $SIGNING"
    assert_not_contains "$RUN_OUTPUT" "Commits and tags are now signed"
    cmp -s "$SANDBOX/signing-before" "$SIGNING" || fail "the encrypted signing key changed (user.signingkey '$value')"
    touch "$HOME/.gitconfig"
    cmp -s "$SANDBOX/gitconfig-before" "$HOME/.gitconfig" ||
        fail "the git config changed with an encrypted signing key (user.signingkey '$value')"
done

# The email comes from git's own lookup, so ~/.gitconfig.local's, which the repo config includes,
# wins over the repo config's
rm -f "$HOME/.gitconfig" "$SIGNING" "$SIGNING.pub" "$ALLOWED"
mkdir -p "$HOME/.config/git"
printf '[user]\n    email = repo@example.com\n[include]\n    path = ~/.gitconfig.local\n' > "$HOME/.config/git/config"
git config --file "$HOME/.gitconfig.local" user.email local@example.com
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_file_contains "$ALLOWED" "local@example.com namespaces=\"git\""
assert_not_contains "$(cat "$ALLOWED")" "repo@example.com"
rm -f "$HOME/.gitconfig.local" "$HOME/.config/git/config"

# Without ssh-keygen it fails before changing anything
rm -f "$HOME/.gitconfig"
(
    hide ssh-keygen
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "ssh-keygen isn't installed"
    [ ! -e "$HOME/.gitconfig" ] || fail "the git config was written without ssh-keygen"
    exit "$TEST_FAILURES"
) || TEST_FAILURES=$((TEST_FAILURES + $?))

# From inside a checkout whose .git file points at a missing dir, as a copied worktree's does,
# ~/.gitconfig is still read and written
mkdir -p "$SANDBOX/broken"
echo "gitdir: $SANDBOX/missing" > "$SANDBOX/broken/.git"
rm -f "$HOME/.gitconfig"
cd "$SANDBOX/broken"
assert_exit 0 set_local tag.gpgsign true
assert_contains "$RUN_OUTPUT" "Set tag.gpgsign = true"
assert_exit 0 set_local tag.gpgsign true
assert_contains "$RUN_OUTPUT" "tag.gpgsign is already true"
cd "$HOME"
test_done
