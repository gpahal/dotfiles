#!/bin/bash
# The sourced script calls the OS functions this test replaces.
# shellcheck disable=SC2329
set -euo pipefail

# git/setup-signing.sh signs on Ubuntu with a separate passphrase-less key, since the T3 Code
# service's agents have no ssh-agent or terminal to unlock one. On macOS it keeps ~/.ssh/id_ed25519
# and offers to put it in the agent through the keychain. Both ask before replacing signing set up
# another way, such as 1Password's op-ssh-sign.

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

# user.signingkey names a key with a passphrase. Without a terminal it's kept.
unset DOTFILES_ASSUME_YES
rm -f "$SIGNING" "$SIGNING.pub" "$ALLOWED"
OLD="$HOME/.ssh/id_ed25519"
ssh-keygen -q -t ed25519 -N secret -f "$OLD"
# shellcheck disable=SC2088 # git config holds the ~ as typed
git config --file "$HOME/.gitconfig" user.signingkey "~/.ssh/id_ed25519.pub"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Kept user.signingkey = ~/.ssh/id_ed25519.pub"
[ ! -e "$SIGNING" ] || fail "the signing key was generated without asking"
assert_file_contains "$ALLOWED" "$(awk '{print $2}' "$OLD.pub")"

# Approved, it switches to the signing key, and allowed_signers keeps the old key, even when it
# didn't list it before. A re-run adds neither again.
export DOTFILES_ASSUME_YES=1
rm "$ALLOWED"
assert_exit 0 main
assert_eq "$SIGNING.pub" "$(signingkey)" "user.signingkey after switching"
assert_file_contains "$ALLOWED" "$(awk '{print $2}' "$OLD.pub")"
assert_file_contains "$ALLOWED" "$(awk '{print $2}' "$SIGNING.pub")"
assert_file_contains "$ALLOWED" "namespaces=\"git\" $(awk '{print $1, $2}' "$OLD.pub")"
assert_exit 0 main
assert_eq 2 "$(wc -l < "$ALLOWED" | tr -d ' ')" "allowed_signers lines after a re-run"

# A key without a passphrase is kept without asking
unset DOTFILES_ASSUME_YES
OWN="$HOME/.ssh/id_own"
ssh-keygen -q -t ed25519 -N '' -f "$OWN"
git config --file "$HOME/.gitconfig" user.signingkey "$OWN.pub"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "whose key has no passphrase"
assert_eq "$OWN.pub" "$(signingkey)" "user.signingkey with a key without a passphrase"
assert_contains "$RUN_OUTPUT" "gh ssh-key add $OWN.pub --type signing"

# On macOS, user.signingkey names another key and gpg.ssh.program is 1Password's, so signing is
# set up another way. Without a terminal the step changes nothing.
is_macos() { true; }
is_ubuntu() { false; }
stub ssh-add 'exit 1'
git config --file "$HOME/.gitconfig" user.signingkey "key::ssh-ed25519 AAAA op"
git config --file "$HOME/.gitconfig" gpg.ssh.program /Applications/1Password.app/Contents/MacOS/op-ssh-sign
cp "$HOME/.gitconfig" "$SANDBOX/gitconfig-op"
cp "$ALLOWED" "$SANDBOX/allowed-op"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign"
assert_contains "$RUN_OUTPUT" "Kept the existing signing config. Nothing changed."
cmp -s "$SANDBOX/gitconfig-op" "$HOME/.gitconfig" || fail ".gitconfig changed without asking"
cmp -s "$SANDBOX/allowed-op" "$ALLOWED" || fail "allowed_signers changed without asking"

# Approved, it signs with ~/.ssh/id_ed25519 and unsets gpg.ssh.program. It exits 1 because the
# stubbed ssh-add fails.
DOTFILES_ASSUME_YES=1 assert_exit 1 main
assert_eq "$OLD.pub" "$(signingkey)" "user.signingkey after replacing 1Password's"
# The old inline key isn't a valid key, so allowed_signers doesn't get it
assert_eq "" "$(grep -E ' AAAA( |$)' "$ALLOWED" || true)" "the invalid old key in allowed_signers"
assert_eq "" "$(git config --file "$HOME/.gitconfig" --get gpg.ssh.program || true)" "gpg.ssh.program"

# The same key, written with ~, isn't another key: nothing to ask
# shellcheck disable=SC2088 # git config holds the ~ as typed
git config --file "$HOME/.gitconfig" user.signingkey "~/.ssh/id_ed25519.pub"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Signing is already set up another way"
git config --file "$HOME/.gitconfig" user.signingkey "$OLD.pub"

# gpg.ssh.program set in a file the step doesn't write, ~/.gitconfig.local: replacing can't remove
# it, so the step says where to look and fails
git config --file "$HOME/.gitconfig" include.path "$HOME/.gitconfig.local"
git config --file "$HOME/.gitconfig.local" gpg.ssh.program op-ssh-sign
DOTFILES_ASSUME_YES=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "gpg.ssh.program is still set in another file"
git config --file "$HOME/.gitconfig" --unset include.path
rm "$HOME/.gitconfig.local"

# macOS signs with ~/.ssh/id_ed25519. The agent doesn't hold it, so without a terminal the step
# prints the ssh-add command that stores its passphrase in the keychain.
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "run once: ssh-add --apple-use-keychain $OLD"
assert_contains "$RUN_OUTPUT" "gh auth refresh -h github.com -s admin:ssh_signing_key"
assert_not_contains "$RUN_OUTPUT" "--insecure-storage"
assert_file_not_contains "$STUB_LOG" "ssh-add --apple-use-keychain"
assert_eq "$OLD.pub" "$(signingkey)" "user.signingkey on macOS"

# Approved, it runs it, and a failure fails the step after the rest is set up
export DOTFILES_ASSUME_YES=1
git config --file "$HOME/.gitconfig" --unset commit.gpgsign
assert_exit 1 main
assert_file_contains "$STUB_LOG" "ssh-add --apple-use-keychain $OLD"
assert_eq true "$(git config --file "$HOME/.gitconfig" --get commit.gpgsign)" "commit.gpgsign"
assert_eq true "$(git config --file "$HOME/.gitconfig" --get tag.gpgsign)" "tag.gpgsign"

# The agent already holds it: nothing to load, but the keychain command still prints, since the
# agent holding it doesn't mean the keychain has its passphrase
stub ssh-add '[ "$1" != -l ] || echo "256 $(ssh-keygen -lf "'"$OLD.pub"'" | cut -d" " -f2) x (ED25519)"'
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The agent already holds $OLD"
assert_contains "$RUN_OUTPUT" "ssh-add --apple-use-keychain $OLD"
assert_file_not_contains "$STUB_LOG" "ssh-add --apple-use-keychain"

# A .pub that ssh-keygen can't read gives no fingerprint, which grep would find in any agent
# listing. The step says so rather than claim the agent holds the key.
cp "$OLD.pub" "$SANDBOX/old-pub"
cp "$ALLOWED" "$SANDBOX/allowed-before-corrupt"
echo corrupt > "$OLD.pub"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Can't read the key's fingerprint from $OLD.pub."
assert_not_contains "$RUN_OUTPUT" "The agent already holds"
cp "$SANDBOX/old-pub" "$OLD.pub"
cp "$SANDBOX/allowed-before-corrupt" "$ALLOWED"

# user.signingkey set in ~/.gitconfig.local, which the repo config includes, is another key too.
# Approved, allowed_signers keeps it.
unset DOTFILES_ASSUME_YES
OTHER="$HOME/.ssh/id_other"
ssh-keygen -q -t ed25519 -N '' -f "$OTHER"
mkdir -p "$HOME/.config/git"
git config --file "$HOME/.config/git/config" include.path "$HOME/.gitconfig.local"
git config --file "$HOME/.gitconfig.local" user.signingkey "$OTHER.pub"
git config --file "$HOME/.gitconfig" --unset user.signingkey
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "user.signingkey = $OTHER.pub"
assert_contains "$RUN_OUTPUT" "Kept the existing signing config. Nothing changed."
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_eq "$OLD.pub" "$(git config --global --includes --get user.signingkey)" "user.signingkey after replacing ~/.gitconfig.local's"
assert_file_contains "$ALLOWED" "$(awk '{print $2}' "$OTHER.pub")"
rm "$HOME/.gitconfig.local" "$HOME/.config/git/config"

# gpg.format set to openpgp is signing set up another way
git config --file "$HOME/.gitconfig" gpg.format openpgp
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "gpg.format = openpgp"
assert_contains "$RUN_OUTPUT" "Kept the existing signing config. Nothing changed."
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_eq ssh "$(git config --file "$HOME/.gitconfig" --get gpg.format)" "gpg.format after replacing openpgp"

# allowed_signers can't be written: the step says so and fails, rather than claim it lists the key
rm "$ALLOWED"
: > "$ALLOWED"
chmod a-w "$ALLOWED"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't add this key for"
assert_not_contains "$RUN_OUTPUT" "already lists"
chmod u+w "$ALLOWED"

# Ubuntu also honors XDG includes and asks before changing alternate signing programs.
is_macos() { false; }
is_ubuntu() { true; }
mkdir -p "$HOME/.config/git"
git config --file "$HOME/.config/git/config" include.path "$HOME/.gitconfig.local"
git config --file "$HOME/.gitconfig.local" user.signingkey "$OWN.pub"
git config --file "$HOME/.gitconfig" --unset user.signingkey
assert_exit 0 main
assert_eq "$OWN.pub" "$(signingkey)" "Ubuntu's included signer"
git config --file "$HOME/.gitconfig" gpg.ssh.program /missing/op-ssh-sign
cp "$HOME/.gitconfig" "$SANDBOX/ubuntu-signer-before"
assert_exit 0 main
cmp -s "$SANDBOX/ubuntu-signer-before" "$HOME/.gitconfig" || fail "Ubuntu changed the signer without asking"
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_eq "" "$(global_get gpg.ssh.program)" "Ubuntu's alternate signer"
assert_exit 0 git -C "$SANDBOX/repo" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m signed-again
# An included signer cannot be removed from ~/.gitconfig: report it instead of claiming success.
git config --file "$HOME/.gitconfig.local" gpg.ssh.program /missing/op-ssh-sign
DOTFILES_ASSUME_YES=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "gpg.ssh.program is still set in another file"

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
