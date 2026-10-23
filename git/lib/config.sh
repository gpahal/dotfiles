# shellcheck shell=bash

# Per-machine settings; git reads it after the repo's ~/.config/git/config
# shellcheck disable=SC2034 # the git step and git/setup-signing.sh read it
USER_GITCONFIG="$HOME/.gitconfig"

# No git dir: git config --file still looks for a repo, dies in a broken checkout, and would apply
# gitdir/onbranch includes for the caller's repo.
git_file() {
    local file="$1"
    shift
    GIT_COMMON_DIR=/dev/null git --git-dir=/dev/null --work-tree=/ config --file "$file" "$@"
}

# Not --global, which skips the XDG file once ~/.gitconfig exists. No git dir, so neither the
# caller's repo config nor its gitdir/onbranch includes apply, and a broken checkout doesn't fail it.
git_user_config() {
    GIT_CONFIG_NOSYSTEM=1 GIT_COMMON_DIR=/dev/null git --git-dir=/dev/null config "$@"
}
