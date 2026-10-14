# shellcheck shell=bash
# Reading git config for the git step. git/install.sh and git/setup-signing.sh source this file.
# It only defines functions.

# Read user config in Git's precedence order without the caller's repository-local settings.
# --global alone omits the XDG file once ~/.gitconfig exists.
git_user_config() {
    local file result=1 code
    for file in "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" "$HOME/.gitconfig"; do
        [ -f "$file" ] || continue
        # An explicit non-repository path also prevents gitdir/onbranch conditional includes
        # from treating settings for just the caller's repo as global defaults.
        if GIT_COMMON_DIR=/dev/null git --git-dir=/dev/null --work-tree=/ config --file "$file" --includes "$@"; then
            result=0
        else
            code=$?
            [ "$code" -eq 1 ] || return "$code"
        fi
    done
    return "$result"
}
