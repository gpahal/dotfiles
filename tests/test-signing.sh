#!/bin/bash

# Ubuntu signs with a passphrase-less key, since T3 Code's agents have no ssh-agent or terminal

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

stub scutil 'echo Test-Mac'
load_script git/setup-signing.sh
as_os ubuntu
SIGNING="$HOME/.ssh/id_ed25519_signing"
ALLOWED="$HOME/.config/git/allowed_signers"

signingkey() {
    git config --file "$HOME/.gitconfig" --get user.signingkey || true
}

assert_exit 1 main
[ ! -e "$SIGNING" ] || fail "the key was generated without asking"

answer yes
assert_idempotent main
# --insecure-storage keeps the refreshed token in hosts.yml, out of the keyring
assert_contains "$FIRST_OUTPUT" "gh auth refresh -h github.com -s admin:ssh_signing_key --insecure-storage"
assert_exit 0 ssh-keygen -y -P '' -f "$SIGNING"
assert_eq "$SIGNING.pub" "$(signingkey)" "user.signingkey"
assert_file_contains "$ALLOWED" "$(awk '{print $2}' "$SIGNING.pub")"

git init -q "$SANDBOX/repo"
run git_commit "$SANDBOX/repo" --allow-empty -m signed
assert_eq 0 "$RUN_STATUS" "signed commit exit status: $RUN_OUTPUT"
run git -C "$SANDBOX/repo" log --show-signature -1
assert_contains "$RUN_OUTPUT" 'Good "git" signature'

answer no

# macOS signs with ~/.ssh/id_ed25519 and prints the ssh-add that stores its passphrase in the keychain
as_os macos
stub ssh-add 'exit 1'
LOGIN="$HOME/.ssh/id_ed25519"
ssh-keygen -q -t ed25519 -N secret -f "$LOGIN"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "run once: ssh-add --apple-use-keychain $LOGIN"
assert_contains "$RUN_OUTPUT" "gh auth refresh -h github.com -s admin:ssh_signing_key"
assert_not_contains "$RUN_OUTPUT" "--insecure-storage"
assert_file_not_contains "$STUB_LOG" "ssh-add --apple-use-keychain"
assert_eq "$LOGIN.pub" "$(signingkey)" "user.signingkey on macOS"

answer yes
git config --file "$HOME/.gitconfig" --unset commit.gpgsign
assert_exit 1 main
assert_file_contains "$STUB_LOG" "ssh-add --apple-use-keychain $LOGIN"
assert_eq true "$(git config --file "$HOME/.gitconfig" --get commit.gpgsign)" "commit.gpgsign"
assert_eq true "$(git config --file "$HOME/.gitconfig" --get tag.gpgsign)" "tag.gpgsign"

# The agent holding the key doesn't mean the keychain has its passphrase
stub ssh-add '[ "$1" != -l ] || echo "256 $(ssh-keygen -lf "'"$LOGIN.pub"'" | cut -d" " -f2) x (ED25519)"'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "ssh-add --apple-use-keychain $LOGIN"
assert_file_not_contains "$STUB_LOG" "ssh-add --apple-use-keychain"

as_os ubuntu

# A default signing key with a passphrase: agents can't unlock it, so fail and change nothing
rm -f "$HOME/.gitconfig" "$HOME/.gitconfig.local" "$HOME/.config/git/config" "$SIGNING" "$SIGNING.pub"
ssh-keygen -q -t ed25519 -N secret -f "$SIGNING"
snapshot "$SIGNING"
git config --file "$HOME/.gitconfig" user.signingkey "$SIGNING.pub"
snapshot "$HOME/.gitconfig"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$SIGNING has a passphrase"
assert_unchanged "$SIGNING" "with a passphrase"
assert_unchanged "$HOME/.gitconfig" "with an encrypted signing key"

# git's own email lookup lets ~/.gitconfig.local win over the repo config
rm -f "$HOME/.gitconfig" "$SIGNING" "$SIGNING.pub" "$ALLOWED"
mkdir -p "$HOME/.config/git"
printf '[user]\n    email = repo@example.com\n[include]\n    path = ~/.gitconfig.local\n' > "$HOME/.config/git/config"
git config --file "$HOME/.gitconfig.local" user.email local@example.com
assert_exit 0 main
assert_file_contains "$ALLOWED" "local@example.com namespaces=\"git\""
assert_not_contains "$(cat "$ALLOWED")" "repo@example.com"
rm -f "$HOME/.gitconfig.local" "$HOME/.config/git/config"

rm -f "$SIGNING" "$SIGNING.pub" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub"
stub ssh-keygen 'exit 1'
# bash hashed the real ssh-keygen's path above
hash -r
for os in ubuntu macos; do
    if [ "$os" == ubuntu ]; then
        as_os ubuntu
    else
        as_os macos
    fi
    assert_exit 1 main
done
rm -rf "$HOME/.ssh"
: > "$HOME/.ssh"
stub ssh-keygen 'touch "$6" "$6.pub"'
assert_exit 1 main
assert_file_not_contains "$STUB_LOG" "ssh-keygen"
rm "$HOME/.ssh"
test_done
