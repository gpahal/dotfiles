#!/bin/bash
set -euo pipefail

# Sign git commits and tags on this machine with an SSH key, offering to generate it if it's
# missing. tag.gpgsign signs every tag, so a plain git tag makes a signed annotated tag and asks for
# a message. Make a lightweight tag with git tag --no-sign.
# macOS signs with ~/.ssh/id_ed25519 and offers to load it into the agent from the keychain.
# Ubuntu signs with a separate key without a passphrase, ~/.ssh/id_ed25519_signing, since the
# T3 Code service's agents have no ssh-agent or terminal to unlock one. Settings go to
# ~/.gitconfig, which holds per-machine git settings (see git/install.sh). Idempotent: safe to
# re-run.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/config.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

LOGIN_KEY="$HOME/.ssh/id_ed25519"
SIGNING_KEY="$HOME/.ssh/id_ed25519_signing"
LOCAL_CONFIG="$HOME/.gitconfig"
ALLOWED_SIGNERS="${XDG_CONFIG_HOME:-$HOME/.config}/git/allowed_signers"
# The email commits are made as, set by main. GitHub shows a signed commit as Verified only when
# it matches a verified email on the account.
EMAIL=""
# The key to sign with, set by choose_key, and its public half
KEY=""
PUB=""
# The user.signingkey value choose_key replaces, if any. Its key stays in allowed_signers, so
# commits it signed still verify.
REPLACED=""

# Print a key's value as git reads it outside a repo, following includes (see git_user_config)
global_get() {
    { git_user_config --get "$1" || true; } 2>/dev/null | tail -n 1
}

# Print the email commits are made as: user.email as git reads it, so ~/.gitconfig.local's wins
# over the repo config's, or the repo config's before the git step has installed it
commit_email() {
    local email
    email="$(global_get user.email)"
    if [ -z "$email" ]; then
        email="$(git --git-dir=/dev/null config --file "$DOTFILES_DIR/git/gitconfig" user.email)"
    fi
    printf '%s\n' "$email"
}

# Set a key in ~/.gitconfig, saying whether it changed. git config --file still looks for a repo,
# and dies inside a broken checkout, such as a copied worktree whose .git points nowhere, so each
# call names no git dir.
set_local() {
    if [ "$(git --git-dir=/dev/null config --file "$LOCAL_CONFIG" --get "$1" || true)" == "$2" ]; then
        echo "  $1 is already $2"
    else
        git --git-dir=/dev/null config --file "$LOCAL_CONFIG" "$1" "$2"
        echo "  Set $1 = $2"
    fi
}

# Succeeds when a private key opens without a passphrase
no_passphrase() {
    ssh-keygen -y -P '' -f "$1" &>/dev/null
}

# Print the private key file a user.signingkey value names: a path to the private or public key,
# maybe starting with ~. Prints nothing for a key given inline ("key::..." or "ssh-...").
private_key_of() {
    case "$1" in
        key::* | ssh-*) return 0 ;;
    esac
    local path="${1/#\~/$HOME}"
    echo "${path%.pub}"
}

# Print "<type> <key>" for a user.signingkey value: a key given inline, or the public key beside a
# key file. Prints nothing when that isn't a valid public key.
public_key_of() {
    local line
    case "$1" in
        key::*) line="${1#key::}" ;;
        ssh-*) line="$1" ;;
        *) line="$(cat "$(private_key_of "$1").pub" 2>/dev/null || true)" ;;
    esac
    line="$(printf '%s\n' "$line" | awk 'NR == 1 {print $1, $2}')"
    if [ -n "$line" ] && printf '%s\n' "$line" | ssh-keygen -lf - &>/dev/null; then
        printf '%s\n' "$line"
    fi
}

# Add "<email> namespaces="git" <type> <key>" to allowed_signers, saying whether it was there.
# Fails when it can't be written.
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

# Set KEY to the key to sign with. Both OSes first ask to replace a gpg.format other than ssh, such
# as openpgp, or a gpg.ssh.program, as 1Password's op-ssh-sign setup sets, and fail when you keep
# it. macOS uses ~/.ssh/id_ed25519, and asks the same about a user.signingkey that names another
# key. Ubuntu uses the signing key, unless user.signingkey already names a key without a
# passphrase, or one with a passphrase that you chose to keep. It fails when you keep a key given
# inline, which leaves nothing to set up.
choose_key() {
    local current old program format
    REPLACED=""
    current="$(global_get user.signingkey)"
    program="$(global_get gpg.ssh.program)"
    format="$(global_get gpg.format)"
    if ! is_ubuntu; then
        KEY="$LOGIN_KEY"
        if { [ -z "$current" ] || [ "$(private_key_of "$current")" == "$LOGIN_KEY" ]; } &&
            [ -z "$program" ] && { [ -z "$format" ] || [ "$format" == ssh ]; }; then
            return 0
        fi
        echo "  Signing is already set up another way:"
        [ -z "$current" ] || echo "    user.signingkey = $current"
        [ -z "$format" ] || [ "$format" == ssh ] || echo "    gpg.format = $format"
        [ -z "$program" ] || echo "    gpg.ssh.program = $program"
        if confirm "  Replace it, signing with $LOGIN_KEY through ssh-keygen?"; then
            REPLACED="$current"
            return 0
        fi
        echo "  Kept the existing signing config. Nothing changed."
        return 1
    fi
    KEY="$SIGNING_KEY"
    if [ -n "$program" ] || { [ -n "$format" ] && [ "$format" != ssh ]; }; then
        echo "  Signing is already set up another way:"
        [ -z "$program" ] || echo "    gpg.ssh.program = $program"
        [ -z "$format" ] || echo "    gpg.format = $format"
        if ! confirm "  Replace it with SSH signing through ssh-keygen?"; then
            echo "  Kept the existing signing config. Nothing changed."
            return 1
        fi
    fi
    old="$(private_key_of "$current")"
    if [ -z "$current" ] || [ "$old" == "$SIGNING_KEY" ]; then
        return 0
    fi
    if [ -n "$old" ] && no_passphrase "$old"; then
        echo "  user.signingkey is $current, whose key has no passphrase"
        KEY="$old"
        return 0
    fi
    echo "  user.signingkey is $current. Its key has a passphrase, or can't be read here, and"
    echo "  agents in the T3 Code service have no ssh-agent or terminal to unlock it, so their"
    echo "  commits would fail to sign."
    if confirm "  Switch to a separate signing key without a passphrase, $SIGNING_KEY? $ALLOWED_SIGNERS keeps the old key, so its signatures still check."; then
        REPLACED="$current"
        return 0
    fi
    echo "  Kept user.signingkey = $current."
    if [ -z "$old" ]; then
        return 1
    fi
    KEY="$old"
}

# Offer to generate KEY. The Ubuntu signing key gets no passphrase, so say why first.
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
    mkdir -p "$(dirname "$KEY")"
    chmod 700 "$(dirname "$KEY")"
    if [ "$KEY" == "$SIGNING_KEY" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "$EMAIL signing" -f "$KEY"
        echo "  Generated $KEY"
    else
        ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY"
    fi
}

# macOS: git signs through the agent when it holds the key, and otherwise asks for the
# passphrase, which agents such as T3 Code's can't answer. Offer to store the passphrase in the
# keychain and load the key. The ssh step's LaunchAgent reloads it from the keychain at login.
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
    local old refresh incomplete=false
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
    choose_key || return 0
    PUB="$KEY.pub"
    if [ -f "$KEY" ]; then
        # The Ubuntu signing key must open without a passphrase. One kept on purpose, through
        # user.signingkey, isn't KEY's default, so it's left to you.
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
    # Dropping the public key's comment
    allow_signer "$(awk '{print $1, $2}' "$PUB")" "this key" || incomplete=true
    if [ -n "$REPLACED" ]; then
        old="$(public_key_of "$REPLACED")"
        if [ -n "$old" ]; then
            allow_signer "$old" "the old key" || incomplete=true
        else
            echo "  Couldn't read the old key, $REPLACED, so $ALLOWED_SIGNERS doesn't list it"
        fi
    fi

    echo "git config ($LOCAL_CONFIG):"
    touch "$LOCAL_CONFIG"
    set_local user.signingkey "$PUB"
    set_local gpg.format ssh
    set_local gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
    set_local commit.gpgsign true
    set_local tag.gpgsign true
    # A program such as op-ssh-sign can't sign with a key file. choose_key asked before this.
    if git --git-dir=/dev/null config --file "$LOCAL_CONFIG" --get gpg.ssh.program &>/dev/null; then
        git --git-dir=/dev/null config --file "$LOCAL_CONFIG" --unset-all gpg.ssh.program
        echo "  Unset gpg.ssh.program"
    fi
    if [ -n "$(global_get gpg.ssh.program)" ]; then
        echo "  gpg.ssh.program is still set in another file, so signing may fail. Find it with:" >&2
        echo "  git config --show-origin --get-all gpg.ssh.program" >&2
        incomplete=true
    fi

    # On Ubuntu, gh auth refresh without --insecure-storage can move the token from hosts.yml into
    # the keyring, which SSH sessions and the T3 Code service can't unlock
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
