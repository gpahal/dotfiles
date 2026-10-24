#!/bin/bash
set -euo pipefail

# Copy the git config, ignore file, and git wt, and offer a GitHub login with gh.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=lib/config.sh
source "$DOTFILES_DIR/git/lib/config.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

REPO_CONFIG="$DOTFILES_DIR/git/gitconfig"
XDG_GIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/git"

# Any answer counts; curl reads the same proxy variables gh does
github_reachable() {
    local code
    code="$(http_status https://api.github.com/)"
    [ -n "$code" ] && [ "$code" != 000 ]
}

# Prints ok, absent, invalid, or unknown. gh calls a token invalid when GitHub is unreachable too,
# so reachability is checked apart. Output can hold the token, so it's never printed.
github_auth_state() {
    local output
    if ! gh auth token --hostname github.com &>/dev/null; then
        echo absent
    elif output="$(gh auth status --active --hostname github.com 2>&1)"; then
        echo ok
    elif grep -q "token in .* is invalid" <<< "$output" && github_reachable; then
        echo invalid
    else
        echo unknown
    fi
}

# Asking GitHub can take 10 s
status_github_login() {
    if status_for_alerts; then
        if gh auth token --hostname github.com &>/dev/null; then
            status_item unverified "Logged in to GitHub with gh: credentials are stored, but checking them was skipped by --for-alerts"
        else
            status_item missing "Logged in to GitHub with gh"
        fi
        return 0
    fi
    case "$(github_auth_state)" in
        ok) status_item ok "Logged in to GitHub with gh" ;;
        unknown) status_item unknown "Logged in to GitHub with gh: credentials are stored, but GitHub couldn't be reached to check them" ;;
        *) status_item missing "Logged in to GitHub with gh" ;;
    esac
}

# Checks the first helper git tries: helpers run in config order and an empty value clears the list
gh_credential_helper_set() {
    git_user_config --get-regexp '^credential\.(https://github\.com\.)?helper$' 2>/dev/null |
        awk '{ i = index($0, " "); v = i ? substr($0, i + 1) : "" }
            v == "" { first = ""; next }
            first == "" { first = v }
            END { exit first !~ /gh auth git-credential/ }'
}

setup_github_auth() {
    # Ubuntu's keyring is missing or locked over SSH, and a locked one stalls every gh command
    local login=(gh auth login)
    if is_ubuntu; then
        login+=(--insecure-storage --git-protocol https)
    fi
    local state
    state="$(github_auth_state)"
    if [ "$state" == unknown ]; then
        echo "  Couldn't reach GitHub to check the stored login, so it's kept. Check it with gh auth status."
    elif [ "$state" != ok ]; then
        # A device login needs a person, even under DOTFILES_ASSUME_YES
        if ! is_interactive || ! confirm "  Log in to GitHub with gh now?"; then
            echo "  Not logged in to GitHub. Run ${login[*]}, then gh auth setup-git."
            return 0
        fi
        if ! "${login[@]}"; then
            echo "  Couldn't log in to GitHub. Run ${login[*]}, then gh auth setup-git." >&2
            return 1
        fi
    fi
    if gh_credential_helper_set; then
        echo "  git already uses gh for GitHub credentials"
    else
        if ! gh auth setup-git; then
            echo "  gh auth setup-git failed. Run it again." >&2
            return 1
        fi
        echo "  Set git to use gh for GitHub credentials"
    fi
}

# Ubuntu only (so ~/.gitconfig, not the shared repo config): SSH sessions and agents there have
# no ssh-agent, so git uses gh's token over HTTPS
GITHUB_HTTPS_KEY=url.https://github.com/.insteadOf
GITHUB_SSH_PREFIXES=(git@github.com: ssh://git@github.com/)

github_https_missing() {
    local current prefix
    current="$(git_user_config --get-all "$GITHUB_HTTPS_KEY" 2>/dev/null || true)"
    for prefix in "${GITHUB_SSH_PREFIXES[@]}"; do
        grep -qxF "$prefix" <<< "$current" || printf '%s\n' "$prefix"
    done
}

github_over_https() {
    [ -z "$(github_https_missing)" ]
}

GITHUB_HTTPS_HINT="a re-run after gh auth login and gh auth setup-git adds it"

# Only once gh's credential helper is set, or working SSH remotes would lose credentials
configure_github_https() {
    local prefix missing
    is_ubuntu || return 0
    missing="$(github_https_missing)"
    if [ -z "$missing" ]; then
        echo "  GitHub SSH remotes already go over HTTPS"
        return 0
    fi
    if ! gh_credential_helper_set; then
        echo "  GitHub SSH remotes stay on SSH, since git doesn't use gh for GitHub credentials yet;"
        echo "  $GITHUB_HTTPS_HINT."
        return 0
    fi
    while IFS= read -r prefix; do
        git_file "$USER_GITCONFIG" --add "$GITHUB_HTTPS_KEY" "$prefix" || return 1
    done <<< "$missing"
    echo "  GitHub SSH remotes now go over HTTPS, through gh's credential helper"
}

git_files() {
    local status=0
    "$1" "$REPO_CONFIG" "$XDG_GIT_DIR/config" || status=1
    "$1" "$DOTFILES_DIR/git/ignore" "$XDG_GIT_DIR/ignore" || status=1
    "$1" "$DOTFILES_DIR/git/fsmonitor" "$XDG_GIT_DIR/fsmonitor" || status=1
    "$1" "$DOTFILES_DIR/git/bin/git-wt" "$HOME/.local/bin/git-wt" || status=1
    return "$status"
}

user_gitconfig_exists() {
    [ -e "$USER_GITCONFIG" ]
}

# Without it, git config --global writes to ~/.config/git/config, which the next run overwrites
create_user_gitconfig() {
    touch "$USER_GITCONFIG"
}

git_items() {
    items_reset
    item "A ~/.gitconfig for per-machine settings" "Create ~/.gitconfig" \
        user_gitconfig_exists create_user_gitconfig
}

status() {
    git_files status_file
    git_items
    items_status
    if status_require_cmd gh "GitHub login"; then
        status_github_login
        status_check "git uses gh for GitHub credentials" gh_credential_helper_set
    fi
    if ! is_ubuntu; then
        status_item skipped "GitHub SSH remotes go over HTTPS: Ubuntu only"
    elif github_over_https; then
        status_item ok "GitHub SSH remotes go over HTTPS, through gh's credential helper"
    elif gh_credential_helper_set; then
        status_item missing "GitHub SSH remotes go over HTTPS, through gh's credential helper"
    else
        status_item missing "GitHub SSH remotes go over HTTPS, through gh's credential helper ($GITHUB_HTTPS_HINT)"
    fi
}

apply() {
    require_cmd gh || return 1
    local status=0
    echo "Copying git config..."
    git_files copy_file || status=1
    git_items
    items_apply || status=1
    setup_github_auth || status=1
    configure_github_https || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
