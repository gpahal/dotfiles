#!/bin/bash
set -euo pipefail

# Sign git commits on this machine with ~/.ssh/id_ed25519, offering to generate it if it's
# missing. Settings go to ~/.gitconfig, which holds per-machine git settings (see
# git/install.sh). Idempotent: safe to re-run.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

KEY="$HOME/.ssh/id_ed25519"
PUB="$KEY.pub"
LOCAL_CONFIG="$HOME/.gitconfig"
ALLOWED_SIGNERS="$HOME/.config/git/allowed_signers"
# The email commits are made as, from the repo's git config. GitHub shows a signed commit as
# Verified only when it matches a verified email on the account.
EMAIL="$(git config --file "$DOTFILES_DIR/git/gitconfig" user.email)"

# Set a key in ~/.gitconfig, saying whether it changed
set_local() {
    if [ "$(git config --file "$LOCAL_CONFIG" --get "$1" || true)" == "$2" ]; then
        echo "  $1 is already $2"
    else
        git config --file "$LOCAL_CONFIG" "$1" "$2"
        echo "  Set $1 = $2"
    fi
}

main() {
    local signer
    if [ $# -gt 0 ]; then
        echo "Usage: bash git/setup-signing.sh (or: just git-signing)"
        echo "Signs git commits on this machine as $EMAIL with $KEY."
        [[ "$1" == "-h" || "$1" == "--help" ]] && return 0
        return 2
    fi

    echo "Signing key:"
    if [ -f "$KEY" ]; then
        echo "  Using $KEY"
    elif confirm "  $KEY doesn't exist. Generate an ed25519 key there?"; then
        mkdir -p "$(dirname "$KEY")"
        chmod 700 "$(dirname "$KEY")"
        ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY"
    else
        echo "  $KEY doesn't exist. Create it with: ssh-keygen -t ed25519 -C $EMAIL" >&2
        return 1
    fi
    if [ ! -f "$PUB" ]; then
        echo "  $PUB is missing. Recreate it with: ssh-keygen -y -f $KEY > $PUB" >&2
        return 1
    fi

    echo "Allowed signers (lets git verify your own signatures):"
    # "<email> namespaces="git" <type> <key>", dropping the public key's comment
    signer="$EMAIL namespaces=\"git\" $(awk '{print $1, $2}' "$PUB")"
    if append_line "$signer" "$ALLOWED_SIGNERS"; then
        echo "  Added $EMAIL to $ALLOWED_SIGNERS"
    else
        echo "  $ALLOWED_SIGNERS already lists this key for $EMAIL"
    fi

    echo "git config ($LOCAL_CONFIG):"
    touch "$LOCAL_CONFIG"
    set_local user.signingkey "$PUB"
    set_local gpg.format ssh
    set_local gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
    set_local commit.gpgsign true

    cat <<EOF

Commits are now signed. To have GitHub show them as Verified, add the key as a signing key:

  gh auth refresh -h github.com -s admin:ssh_signing_key
  gh ssh-key add $PUB --type signing --title "$(scutil --get ComputerName 2>/dev/null || hostname) signing"

or paste $PUB into https://github.com/settings/ssh/new with Key type: Signing Key.
Check a signature with: git log --show-signature -1
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
