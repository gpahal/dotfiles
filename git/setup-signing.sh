#!/bin/bash
set -euo pipefail

# Sign git commits and tags on this machine with an SSH key, offering to generate it if it's
# missing. Ubuntu uses a passphrase-less key, since the T3 Code service has no ssh-agent.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/config.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

LOGIN_KEY="$HOME/.ssh/id_ed25519"
SIGNING_KEY="$HOME/.ssh/id_ed25519_signing"
ALLOWED_SIGNERS="${XDG_CONFIG_HOME:-$HOME/.config}/git/allowed_signers"
# Set by main
EMAIL=""
KEY=""
PUB=""

global_get() {
    { git_user_config --get "$1" || true; } 2>/dev/null | tail -n 1
}

# Falls back to the repo config before the git step has installed it
commit_email() {
    local email
    email="$(global_get user.email)"
    if [ -z "$email" ]; then
        email="$(git_file "$DOTFILES_DIR/git/gitconfig" user.email)"
    fi
    printf '%s\n' "$email"
}

set_local() {
    if [ "$(git_file "$USER_GITCONFIG" --get "$1" || true)" == "$2" ]; then
        echo "  $1 is already $2"
    else
        git_file "$USER_GITCONFIG" "$1" "$2"
        echo "  Set $1 = $2"
    fi
}

no_passphrase() {
    ssh-keygen -y -P '' -f "$1" &>/dev/null
}

allow_signer() {
    local line="$EMAIL namespaces=\"git\" $1"
    if has_line "$line" "$ALLOWED_SIGNERS"; then
        echo "  $ALLOWED_SIGNERS already lists $2 for $EMAIL"
    elif append_line "$line" "$ALLOWED_SIGNERS"; then
        echo "  Added $2 for $EMAIL to $ALLOWED_SIGNERS"
    else
        echo "  Couldn't add $2 for $EMAIL to $ALLOWED_SIGNERS" >&2
        return 1
    fi
}

generate_key() {
    local how="ssh-keygen -t ed25519 -C $EMAIL -f $KEY"
    if [ "$KEY" == "$SIGNING_KEY" ]; then
        how="ssh-keygen -t ed25519 -N '' -C \"$EMAIL signing\" -f $KEY"
        echo "  $KEY doesn't exist. It gets no passphrase, since agents in"
        echo "  the T3 Code service have no ssh-agent or terminal to unlock one. Add it to GitHub only"
        echo "  as a signing key: GitHub doesn't accept a signing key for logging in."
        if ! confirm "  Generate it?"; then
            echo "  Create it with: $how" >&2
            return 1
        fi
    elif ! confirm "  $KEY doesn't exist. Generate an ed25519 key there?"; then
        echo "  $KEY doesn't exist. Create it with: $how" >&2
        return 1
    fi
    # main calls this under ||, which turns set -e off here
    mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")" || return 1
    if [ "$KEY" == "$SIGNING_KEY" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "$EMAIL signing" -f "$KEY" || return 1
        echo "  Generated $KEY"
    else
        ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY" || return 1
    fi
}

# Without the key in the agent, git asks for the passphrase, which agents can't answer. The ssh
# step's LaunchAgent reloads it from the keychain at login.
load_into_agent() {
    local fingerprint
    fingerprint="$(ssh-keygen -lf "$PUB" | awk '{print $2}')" || true
    # An empty one would match any line of the agent's list
    if [ -z "$fingerprint" ]; then
        echo "  Can't read the key's fingerprint from $PUB." >&2
        return 1
    fi
    if ssh-add -l 2>/dev/null | grep -qF "$fingerprint"; then
        echo "  The agent already holds $KEY"
        echo "  Agent residency doesn't prove Keychain storage. To restore it after login, run once: ssh-add --apple-use-keychain $KEY"
        return 0
    fi
    if ! confirm "  Store $KEY's passphrase in the keychain and load it into the agent, so commits sign without asking for it?"; then
        echo "  To sign without a passphrase prompt, run once: ssh-add --apple-use-keychain $KEY"
        return 0
    fi
    if ! ssh-add --apple-use-keychain "$KEY"; then
        echo "  Couldn't load $KEY into the agent. Run: ssh-add --apple-use-keychain $KEY" >&2
        return 1
    fi
}

main() {
    local refresh incomplete=false
    EMAIL="$(commit_email)"
    if [ $# -gt 0 ]; then
        echo "Usage: bash git/setup-signing.sh (or: just git-signing)"
        echo "Signs git commits and tags on this machine as $EMAIL with $LOGIN_KEY on macOS, and"
        echo "with $SIGNING_KEY, which has no passphrase, on Ubuntu."
        [[ "$1" == "-h" || "$1" == "--help" ]] && return 0
        return 2
    fi

    require_cmd ssh-keygen || return 1
    echo "Signing key:"
    if is_ubuntu; then
        KEY="$SIGNING_KEY"
    else
        KEY="$LOGIN_KEY"
    fi
    PUB="$KEY.pub"
    if [ -f "$KEY" ]; then
        if [ "$KEY" == "$SIGNING_KEY" ] && ! no_passphrase "$KEY"; then
            echo "  $KEY has a passphrase, or can't be read here, so agents in the T3 Code service," >&2
            echo "  which have no ssh-agent or terminal to unlock it, couldn't sign. Nothing changed." >&2
            echo "  Remove its passphrase with: ssh-keygen -p -f $KEY (enter an empty new one)," >&2
            echo "  or move it aside to have a new key generated, then re-run." >&2
            return 1
        fi
        echo "  Using $KEY"
    else
        generate_key || return 1
    fi
    if [ ! -f "$PUB" ]; then
        echo "  $PUB is missing. Recreate it with: ssh-keygen -y -f $KEY > $PUB" >&2
        return 1
    fi
    if is_macos; then
        load_into_agent || incomplete=true
    fi

    echo "Allowed signers (lets git verify your own signatures):"
    allow_signer "$(awk '{print $1, $2}' "$PUB")" "this key" || incomplete=true

    echo "git config ($USER_GITCONFIG):"
    touch "$USER_GITCONFIG"
    set_local user.signingkey "$PUB"
    set_local gpg.format ssh
    set_local gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
    set_local commit.gpgsign true
    set_local tag.gpgsign true

    # Without --insecure-storage, Ubuntu's token can move into a keyring SSH sessions can't unlock
    refresh="gh auth refresh -h github.com -s admin:ssh_signing_key"
    if is_ubuntu; then
        refresh+=" --insecure-storage"
    fi
    cat <<EOF

Commits and tags are now signed. To have GitHub show them as Verified, add the key as a signing key:

  $refresh
  gh ssh-key add $PUB --type signing --title "$(scutil --get ComputerName 2>/dev/null || hostname) signing"

or paste $PUB into https://github.com/settings/ssh/new with Key type: Signing Key.
Check a signature with: git log --show-signature -1
EOF
    ! "$incomplete"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
