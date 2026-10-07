#!/bin/bash
set -euo pipefail

# Install the git config, global ignore file, and git-cleanup, and log in to GitHub with gh.
#
# The repo config goes to ~/.config/git/config. ~/.gitconfig, which git reads after it, holds
# what tools write there: gh's credential helper and, from git/setup-signing.sh, commit signing.
# The repo config includes ~/.gitconfig.local for any other per-machine settings.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

REPO_CONFIG="$DOTFILES_DIR/git/gitconfig"
XDG_GIT_DIR="$HOME/.config/git"
LOCAL_CONFIG="$HOME/.gitconfig"

setup_github_auth() {
    if ! command -v gh &>/dev/null; then
        echo "  gh not installed; skipping GitHub login."
        return 0
    fi
    if ! gh auth status &>/dev/null; then
        if ! confirm "  Log in to GitHub with gh now?"; then
            echo "  Not logged in to GitHub. Run gh auth login, then gh auth setup-git."
            return 0
        fi
        gh auth login
    fi
    if git config --file "$LOCAL_CONFIG" --get-all credential.https://github.com.helper &>/dev/null; then
        echo "  git already uses gh for GitHub credentials"
    else
        gh auth setup-git
        echo "  Set git to use gh for GitHub credentials"
    fi
}

main() {
    echo "Copying git config..."
    copy_file "$REPO_CONFIG" "$XDG_GIT_DIR/config"
    copy_file "$DOTFILES_DIR/git/ignore" "$XDG_GIT_DIR/ignore"
    copy_file "$DOTFILES_DIR/git/bin/git-cleanup" "$HOME/.local/bin/git-cleanup"
    chmod 755 "$HOME/.local/bin/git-cleanup"
    # git config --global writes to ~/.config/git/config when ~/.gitconfig doesn't exist, and
    # the next run would overwrite that. Make sure per-machine settings land in ~/.gitconfig.
    touch "$LOCAL_CONFIG"
    setup_github_auth
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
