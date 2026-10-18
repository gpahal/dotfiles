# shellcheck shell=bash
# Reading git config for the git step. git/install.sh and git/setup-signing.sh source this file.
# It only defines functions.

# Run git config on one file, e.g. git_file ~/.gitconfig --get user.email. git config --file still
# looks for a repo, and dies inside a broken checkout, such as a copied worktree whose .git points
# nowhere, so it names no git dir. That also stops gitdir and onbranch conditional includes from
# reading settings for just the caller's repo as global ones.
git_file() {
    local file="$1"
    shift
    GIT_COMMON_DIR=/dev/null git --git-dir=/dev/null --work-tree=/ config --file "$file" "$@"
}

# Read user config in Git's precedence order without the caller's repository-local settings.
# --global alone omits the XDG file once ~/.gitconfig exists.
git_user_config() {
    local file result=1 code
    for file in "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" "$HOME/.gitconfig"; do
        [ -f "$file" ] || continue
        if git_file "$file" --includes "$@"; then
            result=0
        else
            code=$?
            [ "$code" -eq 1 ] || return "$code"
        fi
    done
    return "$result"
}
