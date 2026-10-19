#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# On Ubuntu, the git step rewrites GitHub's SSH remotes to HTTPS in ~/.gitconfig, adding each
# insteadOf value once, but only once gh's credential helper is set. macOS gets neither value. It
# also covers the gh login: no device login without a terminal, unknown rather than absent when
# GitHub can't be reached, and the token never printed.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
# Logged in to GitHub, with gh's credential helper set
stub gh
load_script git/install.sh
git config --file "$HOME/.gitconfig" credential.https://github.com.helper '!gh auth git-credential'

insteadof() {
    git config --file "$HOME/.gitconfig" --get-all url.https://github.com/.insteadOf || true
}

# --- macOS: nothing added ---
is_macos() { true; }
is_ubuntu() { false; }
assert_exit 0 main
assert_eq "" "$(insteadof)" "insteadOf on macOS"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    GitHub SSH remotes go over HTTPS"

# --- Ubuntu ---
is_macos() { false; }
is_ubuntu() { true; }
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    GitHub SSH remotes go over HTTPS, through gh's credential helper"

# One value already there, from an earlier run or by hand: only the other is added
git config --file "$HOME/.gitconfig" --add url.https://github.com/.insteadOf ssh://git@github.com/
assert_exit 0 main
assert_eq "ssh://git@github.com/
git@github.com:" "$(insteadof)" "insteadOf after the first run"
assert_contains "$RUN_OUTPUT" "GitHub SSH remotes now go over HTTPS"
assert_eq "https://github.com/me/repo.git" "$(git ls-remote --get-url git@github.com:me/repo.git)" "rewritten scp-style URL"
assert_eq "https://github.com/me/repo.git" "$(git ls-remote --get-url ssh://git@github.com/me/repo.git)" "rewritten ssh URL"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         GitHub SSH remotes go over HTTPS"

# A re-run adds nothing
cp "$HOME/.gitconfig" "$SANDBOX/before"
assert_exit 0 main
assert_eq "" "$(cmp "$SANDBOX/before" "$HOME/.gitconfig" 2>&1)" "the re-run's ~/.gitconfig"
assert_contains "$RUN_OUTPUT" "GitHub SSH remotes already go over HTTPS"

# Repository-local settings must not satisfy machine-wide setup checks.
rm "$HOME/.gitconfig"
git init -q "$SANDBOX/local-only"
git -C "$SANDBOX/local-only" config credential.https://github.com.helper '!gh auth git-credential'
for prefix in "${GITHUB_SSH_PREFIXES[@]}"; do
    git -C "$SANDBOX/local-only" config --add "$GITHUB_HTTPS_KEY" "$prefix"
done
cd "$SANDBOX/local-only"
assert_exit 1 gh_credential_helper_set
assert_exit 1 github_over_https
# The rewrite waits for the helper in the user's config
git config --file "$HOME/.gitconfig" credential.https://github.com.helper '!gh auth git-credential'
assert_exit 0 configure_github_https
cd "$HOME"
assert_eq "https://github.com/me/repo.git" "$(git ls-remote --get-url git@github.com:me/repo.git)" "rewrite outside caller's repo"
git config --file "$HOME/.gitconfig" --unset credential.https://github.com.helper
# Included user settings count, including XDG settings when ~/.gitconfig also exists.
git config --file "$HOME/.gitconfig.local" credential.https://github.com.helper '!gh auth git-credential'
assert_exit 0 gh_credential_helper_set
rm "$HOME/.gitconfig.local"

# Assume-yes can automate installs, but an unattended run cannot complete device login.
# No stored credentials: gh auth token fails, and so does gh auth status.
stub gh 'case "$*" in "auth token"* | "auth status"*) exit 1 ;; esac'
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_not_contains "$STUB_LOG" 'gh auth login'
assert_contains "$RUN_OUTPUT" 'Not logged in to GitHub. Run gh auth login --insecure-storage --git-protocol https'
# A terminal can still opt in to login.
# shellcheck disable=SC2329
is_interactive() { true; }
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_contains "$STUB_LOG" 'gh auth login --insecure-storage --git-protocol https'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Logged in to GitHub with gh"

# Stored credentials, but GitHub can't be reached to check them: the login is unknown, not absent,
# so no new login is offered, even with a terminal, and git's helper is still set up. The token
# never shows.
# gh_stub <auth status output>: gh with a stored token, whose auth status fails with that output
gh_stub() {
    stub gh 'case "$*" in
    "auth token"*) echo gho_SECRET ;;
    "auth status"*) printf "%s\n" "github.com" "  X '"$1"'" "  - Token: gho_SECRET" >&2; exit 1 ;;
esac'
}
gh_stub "Timeout trying to log in to github.com account me (keyring)"
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_not_contains "$STUB_LOG" 'gh auth login'
assert_contains "$RUN_OUTPUT" "Couldn't reach GitHub to check the stored login"
assert_not_contains "$RUN_OUTPUT" "gho_SECRET"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "unknown    Logged in to GitHub with gh: credentials are stored, but GitHub couldn't be reached to check them"
assert_not_contains "$RUN_OUTPUT" "gho_SECRET"

# gh says a token is invalid when GitHub can't be reached at all, such as through a proxy that's
# down, so with GitHub unreachable that's unknown too, and no new login is offered
gh_stub "Failed to log in to github.com account me (keyring)\n  - The token in keyring is invalid."
stub curl 'printf 000; exit 7'
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_not_contains "$STUB_LOG" 'gh auth login'
assert_contains "$RUN_OUTPUT" "Couldn't reach GitHub to check the stored login"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "unknown    Logged in to GitHub with gh"

# A stored token GitHub rejects needs a new login, which a terminal is offered
stub curl 'printf 200'
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_contains "$STUB_LOG" 'gh auth login --insecure-storage --git-protocol https'
assert_not_contains "$RUN_OUTPUT" "gho_SECRET"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Logged in to GitHub with gh"

# Another account on github.com with a revoked token doesn't count against the active one, which
# git uses
stub gh 'case "$*" in
    "auth token"*) echo gho_SECRET ;;
    "auth status --active"*) ;;
    "auth status"*) printf "%s\n" "  X Failed to log in to github.com account old (keyring)" "  - The token in keyring is invalid." >&2; exit 1 ;;
esac'
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_not_contains "$STUB_LOG" 'gh auth login'
assert_exit 0 status_github_login
assert_contains "$RUN_OUTPUT" "ok         Logged in to GitHub with gh"
# --quick asks GitHub nothing: stored credentials are unverified
: > "$STUB_LOG"
DOTFILES_STATUS_QUICK=1 assert_exit 0 status_github_login
assert_contains "$RUN_OUTPUT" "unverified Logged in to GitHub with gh: credentials are stored, but checking them was skipped by --quick"
assert_file_not_contains "$STUB_LOG" 'gh auth status'

# The rewrite needs gh's credential helper, or git would have no credentials for GitHub. Without a
# login, main leaves the remotes on SSH and says a re-run after logging in adds the rewrite.
# shellcheck disable=SC2329
is_interactive() { false; }
rm -f "$HOME/.gitconfig"
stub gh 'case "$*" in "auth token"* | "auth status"*) exit 1 ;; esac'
assert_exit 0 main
assert_eq "" "$(insteadof)" "insteadOf without gh's credential helper"
assert_contains "$RUN_OUTPUT" "re-run after gh auth login and gh auth setup-git"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    GitHub SSH remotes go over HTTPS, through gh's credential helper (a re-run after gh auth login and gh auth setup-git adds it)"
# Logged in, with gh auth setup-git setting the helper in this run: the rewrite follows in the same
# run
stub gh 'case "$*" in
    "auth token") echo gho_SECRET ;;
    "auth setup-git") git config --file "$HOME/.gitconfig" credential.https://github.com.helper "!gh auth git-credential" ;;
esac'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Set git to use gh for GitHub credentials"
assert_eq "git@github.com:
ssh://git@github.com/" "$(insteadof)" "insteadOf once gh auth setup-git set the helper"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         GitHub SSH remotes go over HTTPS"
test_done
