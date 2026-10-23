#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions
set -euo pipefail

# The git step's GitHub over HTTPS through gh's credential helper, and its GitHub login check.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
# DOTFILES_ASSUME_YES and DOTFILES_SSH_KEY_ONLY count only in a VM
stub systemd-detect-virt
stub gh
load_script git/install.sh
git config --file "$HOME/.gitconfig" credential.https://github.com.helper '!gh auth git-credential'

insteadof() {
    git config --file "$HOME/.gitconfig" --get-all url.https://github.com/.insteadOf || true
}

as_os macos
assert_exit 0 main
assert_eq "" "$(insteadof)" "insteadOf on macOS"
assert_exit 0 main --status

as_os ubuntu
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    GitHub SSH remotes go over HTTPS"

git config --file "$HOME/.gitconfig" --add url.https://github.com/.insteadOf ssh://git@github.com/
assert_exit 0 main
assert_eq "ssh://git@github.com/
git@github.com:" "$(insteadof)" "insteadOf after the first run"
assert_eq "https://github.com/me/repo.git" "$(git ls-remote --get-url git@github.com:me/repo.git)" "rewritten scp-style URL"
assert_eq "https://github.com/me/repo.git" "$(git ls-remote --get-url ssh://git@github.com/me/repo.git)" "rewritten ssh URL"
assert_exit 0 main --status

snapshot "$HOME/.gitconfig"
assert_exit 0 main
assert_unchanged "$HOME/.gitconfig" "on a re-run"

# Repo-local settings mustn't satisfy the machine-wide checks
rm "$HOME/.gitconfig"
git init -q "$SANDBOX/local-only"
git -C "$SANDBOX/local-only" config credential.https://github.com.helper '!gh auth git-credential'
for prefix in "${GITHUB_SSH_PREFIXES[@]}"; do
    git -C "$SANDBOX/local-only" config --add "$GITHUB_HTTPS_KEY" "$prefix"
done
cd "$SANDBOX/local-only"
assert_exit 1 gh_credential_helper_set
assert_exit 1 github_over_https
git config --file "$HOME/.gitconfig" credential.https://github.com.helper '!gh auth git-credential'
assert_exit 0 configure_github_https
cd "$HOME"
[ -n "$(insteadof)" ] || fail "the rewrite went to the caller's repo, not ~/.gitconfig"
git config --file "$HOME/.gitconfig" --unset credential.https://github.com.helper
# Included user settings count
git config --file "$HOME/.gitconfig.local" credential.https://github.com.helper '!gh auth git-credential'
assert_exit 0 gh_credential_helper_set
rm "$HOME/.gitconfig.local"

# An unattended run can't complete a device login, even with assume-yes
stub gh 'case "$*" in "auth token"* | "auth status"*) exit 1 ;; esac'
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_not_contains "$STUB_LOG" 'gh auth login'
replace_fn is_interactive 'return 0'
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_contains "$STUB_LOG" 'gh auth login --insecure-storage --git-protocol https'
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Logged in to GitHub with gh"

# Stored credentials but GitHub unreachable: unknown, not absent, so no new login is offered
stub gh 'case "$*" in
    "auth token"*) echo gho_SECRET ;;
    "auth status"*) printf "%s\n" "github.com" "  X Timeout trying to log in to github.com account me (keyring)" "  - Token: gho_SECRET" >&2; exit 1 ;;
esac'
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 setup_github_auth
assert_file_not_contains "$STUB_LOG" 'gh auth login'
assert_not_contains "$RUN_OUTPUT" "gho_SECRET"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "unknown    Logged in to GitHub with gh"
assert_not_contains "$RUN_OUTPUT" "gho_SECRET"

: > "$STUB_LOG"
DOTFILES_STATUS_QUICK=1 assert_exit 0 status_github_login
assert_contains "$RUN_OUTPUT" "unverified Logged in to GitHub with gh"
assert_file_not_contains "$STUB_LOG" 'gh auth status'

# The rewrite needs gh's credential helper, or git would have no GitHub credentials
replace_fn is_interactive 'return 1'
rm -f "$HOME/.gitconfig"
stub gh 'case "$*" in "auth token"* | "auth status"*) exit 1 ;; esac'
assert_exit 0 main
assert_eq "" "$(insteadof)" "insteadOf without gh's credential helper"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    GitHub SSH remotes go over HTTPS"
# gh auth setup-git sets the helper in this run, so the rewrite follows
stub gh 'case "$*" in
    "auth token") echo gho_SECRET ;;
    "auth setup-git") git config --file "$HOME/.gitconfig" credential.https://github.com.helper "!gh auth git-credential" ;;
esac'
assert_exit 0 main
assert_eq "git@github.com:
ssh://git@github.com/" "$(insteadof)" "insteadOf once gh auth setup-git set the helper"
assert_exit 0 main --status
test_done
