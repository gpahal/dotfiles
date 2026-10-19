# shellcheck shell=bash

# Per-machine settings; git reads it after the repo's ~/.config/git/config
USER_GITCONFIG="$HOME/.gitconfig"

# No git dir: git config --file still looks for a repo, dies in a broken checkout, and would apply
# gitdir/onbranch includes for the caller's repo.
git_file() {
    local file="$1"
    shift
    GIT_COMMON_DIR=/dev/null git --git-dir=/dev/null --work-tree=/ config --file "$file" "$@"
}

# Not --global, which skips the XDG file once ~/.gitconfig exists
git_user_config() {
    local file result=1 code
    for file in "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" "$USER_GITCONFIG"; do
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
