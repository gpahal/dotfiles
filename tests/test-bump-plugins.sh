#!/bin/bash
set -euo pipefail

# scripts/bump-plugins.sh, run on a copy of the repo's files with local repos for GitHub.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v git &>/dev/null || skip "git isn't installed"

# The script must never edit the repo's own copies
real_sums() {
    (cd "$REPO_DIR" && cksum vim/vimrc tmux/plugins.lock vim/plug.vim vim/plug.vim.version)
}
REAL_BEFORE="$(real_sums)"

COPY="$SANDBOX/repo"
mkdir -p "$COPY/scripts" "$COPY/vim" "$COPY/tmux"
cp -R "$REPO_DIR/lib" "$COPY/"
cp "$REPO_DIR/scripts/bump-plugins.sh" "$COPY/scripts/"
cp "$REPO_DIR/vim/vimrc" "$REPO_DIR/vim/plug.vim" "$REPO_DIR/vim/plug.vim.version" "$COPY/vim/"
cp "$REPO_DIR/tmux/plugins.lock" "$COPY/tmux/"
VIMRC="$COPY/vim/vimrc"
LOCK="$COPY/tmux/plugins.lock"
PLUG_VIM="$COPY/vim/plug.vim"
PLUG_VERSION="$COPY/vim/plug.vim.version"

# A git url rewrite makes each repo under $REMOTES https://github.com/<repo>
REMOTES="$SANDBOX/remotes"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$REMOTES/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/
# Each commit names its repo, so no two repos share a sha
commit() {
    echo "$1 $2" > "$REMOTES/$1/README"
    git -C "$REMOTES/$1" add README
    git_commit "$REMOTES/$1" -m "$2"
    git -C "$REMOTES/$1" rev-parse HEAD
}
pins() {
    sed -n "s/^ *Plug '\([^']*\)'.*'commit': '\([0-9a-f]\{40\}\)'.*/\1 \2/p" "$VIMRC"
    awk '!/^#/ && NF' "$LOCK"
}
pin_of() {
    pins | awk -v repo="$1" '$1 == repo && !found { print $2; found = 1 }'
}
# Read before the loop, which rewrites the files
start_pins="$(pins)"
while read -r repo old; do
    if [ ! -d "$REMOTES/$repo" ]; then
        git init -q "$REMOTES/$repo"
        new="$(commit "$repo" 1)"
    fi
    # A repo in both files, such as vim-tmux-navigator, has the same pin in each
    for f in "$VIMRC" "$LOCK"; do
        sed "s/$old/$new/" "$f" > "$f.new" && mv "$f.new" "$f"
    done
done <<< "$start_pins"

# curl serves $SANDBOX/plug-<tag>.vim for each tag
git init -q "$REMOTES/junegunn/vim-plug"
commit junegunn/vim-plug 1 > /dev/null
for tag in 0.9.10 0.13.0 "$(cat "$PLUG_VERSION")" nightly; do
    git -C "$REMOTES/junegunn/vim-plug" tag "$tag"
done
stub curl 'out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift ;; *) url="$1" ;; esac
    shift
done
case "$url" in
    https://raw.githubusercontent.com/junegunn/vim-plug/*/plug.vim) ;;
    *) exit 22 ;;
esac
tag="${url#https://raw.githubusercontent.com/junegunn/vim-plug/}"
cp "'"$SANDBOX"'/plug-${tag%/plug.vim}.vim" "$out" 2> /dev/null || exit 22'
# Newer than the repo's, so the tags never match a real one
IFS=. read -r plug_major plug_minor _ < "$PLUG_VERSION"
NEXT="$plug_major.$((plug_minor + 1)).0"
AFTER="$plug_major.$((plug_minor + 2)).0"
release() {
    git -C "$REMOTES/junegunn/vim-plug" tag "$1"
    printf '%s\n' '" vim-plug: Vim plugin manager' "\" release $1" > "$SANDBOX/plug-$1.vim"
}

# A replaced file changes its inode
snapshot() {
    local f
    for f in "$VIMRC" "$LOCK" "$PLUG_VIM" "$PLUG_VERSION"; do
        /bin/ls -i "$f" | awk '{ print $1 }'
        cat "$f"
    done
}
bump() {
    assert_exit "$1" "$BASH" "$COPY/scripts/bump-plugins.sh"
}

before="$(snapshot)"
bump 0
assert_contains "$RUN_OUTPUT" "tpope/vim-sensible: unchanged"
assert_contains "$RUN_OUTPUT" "tmux-plugins/tpm: unchanged"
assert_contains "$RUN_OUTPUT" "vim-plug: unchanged"
assert_eq "$before" "$(snapshot)" "the files when nothing moved"
assert_file_not_contains "$STUB_LOG" curl

old_version="$(cat "$PLUG_VERSION")"
old_nerdtree="$(pin_of preservim/nerdtree)"
old_tpm="$(pin_of tmux-plugins/tpm)"
sensible="$(commit tpope/vim-sensible 2)"
navigator="$(commit christoomey/vim-tmux-navigator 2)"
yank="$(commit tmux-plugins/tmux-yank 2)"
release "$NEXT"
expected_vimrc="$(sed -e "s/$(pin_of tpope/vim-sensible)/$sensible/" \
    -e "s/$(pin_of christoomey/vim-tmux-navigator)/$navigator/" "$VIMRC")"
expected_lock="$(sed -e "s/$(pin_of christoomey/vim-tmux-navigator)/$navigator/" \
    -e "s/$(pin_of tmux-plugins/tmux-yank)/$yank/" "$LOCK")"
bump 0
assert_contains "$RUN_OUTPUT" "https://github.com/tpope/vim-sensible/compare/"
assert_contains "$RUN_OUTPUT" "vim-plug: $old_version -> $NEXT"
assert_eq "$expected_vimrc" "$(cat "$VIMRC")" "vimrc after the bump"
assert_eq "$expected_lock" "$(cat "$LOCK")" "plugins.lock after the bump"
assert_eq "$(cat "$SANDBOX/plug-$NEXT.vim")" "$(cat "$PLUG_VIM")" "plug.vim after the bump"
assert_eq "$NEXT" "$(cat "$PLUG_VERSION")" "plug.vim.version after the bump"
assert_eq "$old_nerdtree" "$(pin_of preservim/nerdtree)" "an unmoved vim pin"
assert_eq "$old_tpm" "$(pin_of tmux-plugins/tpm)" "an unmoved tmux pin"

# A download that isn't vim-plug, such as an error page, keeps plug.vim
rm -rf "$REMOTES/preservim/nerdtree"
surround="$(commit tpope/vim-surround 2)"
git -C "$REMOTES/junegunn/vim-plug" tag "$AFTER"
echo "<html>Not Found</html>" > "$SANDBOX/plug-$AFTER.vim"
bump 1
assert_contains "$RUN_OUTPUT" "Couldn't read preservim/nerdtree's HEAD"
assert_contains "$RUN_OUTPUT" "vim-plug stays at $NEXT"
assert_eq "$old_nerdtree" "$(pin_of preservim/nerdtree)" "the pin whose HEAD couldn't be read"
assert_eq "$surround" "$(pin_of tpope/vim-surround)" "a pin that moved beside a failure"
assert_eq "$(cat "$SANDBOX/plug-$NEXT.vim")" "$(cat "$PLUG_VIM")" "plug.vim after an error page"
assert_eq "$NEXT" "$(cat "$PLUG_VERSION")" "plug.vim.version after an error page"

rm "$SANDBOX/plug-$AFTER.vim"
before="$(snapshot)"
bump 1
assert_contains "$RUN_OUTPUT" "Couldn't download vim-plug $AFTER"
assert_eq "$before" "$(snapshot)" "the files after a failed download"

assert_eq "$REAL_BEFORE" "$(real_sums)" "the repo's own files"
test_done
