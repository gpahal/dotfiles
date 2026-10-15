#!/bin/bash
set -euo pipefail

# scripts/bump-plugins.sh moves each vim and tmux plugin's pin to its default branch's HEAD, says
# which pins moved, with a link to review each, and which didn't, and replaces the vendored
# vim-plug when a newer release is out. A repo whose HEAD it can't read fails the script and keeps
# its pin. It runs on a copy of the repo's files, with git's ls-remote and curl stubbed.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

REPO="$SANDBOX/repo"
for file in scripts/bump-plugins.sh lib/common.sh vim/vimrc vim/plug.vim vim/plug.vim.version tmux/plugins.lock; do
    mkdir -p "$REPO/$(dirname "$file")"
    cp "$REPO_DIR/$file" "$REPO/$file"
done
VIMRC="$REPO/vim/vimrc"
LOCK="$REPO/tmux/plugins.lock"
NEW=1111111111111111111111111111111111111111

# Print a vim plugin's pin in the copy's vimrc, or a tmux plugin's in its plugins.lock
vim_pin() {
    sed -n "s/^ *Plug '${1//\//\\/}'.*'commit': '\([0-9a-f]*\)'.*/\1/p" "$VIMRC"
}
tmux_pin() {
    awk -v r="$1" '$1 == r { print $2 }' "$LOCK"
}

# Upstream, vim-surround and tmux-yank have moved to $NEW, fzf.vim's HEAD can't be read, and every
# other plugin is still at its pin. vim-plug has a newer release, 99.0.0.
: > "$SANDBOX/heads"
while read -r repo sha; do
    echo "https://github.com/$repo $sha" >> "$SANDBOX/heads"
done < <(sed -n "s/^ *Plug '\([^']*\)'.*'commit': '\([0-9a-f]*\)'.*/\1 \2/p" "$VIMRC"; grep -v '^#' "$LOCK")
sed -i.bak -e "s|^\(https://github.com/tpope/vim-surround\) .*|\1 $NEW|" \
    -e "s|^\(https://github.com/tmux-plugins/tmux-yank\) .*|\1 $NEW|" \
    -e "/^https:\/\/github.com\/junegunn\/fzf.vim /d" "$SANDBOX/heads"
stub git 'url="${!#}"
case "$*" in
    "ls-remote --tags --refs https://github.com/junegunn/vim-plug")
        printf "%s\trefs/tags/%s\n" a 0.9.0 b 99.0.0 c 0.14.0 ;;
    "ls-remote "*" HEAD")
        sha="$(awk -v u="${@: -2:1}" '"'"'$1 == u { print $2 }'"'"' "'"$SANDBOX"'/heads")"
        [ -n "$sha" ] || { echo "fatal: could not read from remote repository" >&2; exit 128; }
        printf "%s\tHEAD\n" "$sha" ;;
    *) exit 1 ;;
esac'
stub curl 'while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; *) url="$1" ;; esac; shift; done
printf "%s\n" "\" vim-plug: Vim plugin manager" "\" from $url" > "$out"'

old_surround="$(vim_pin tpope/vim-surround)"
old_yank="$(tmux_pin tmux-plugins/tmux-yank)"
old_fzf="$(vim_pin junegunn/fzf.vim)"
old_sensible="$(vim_pin tpope/vim-sensible)"
old_tag="$(cat "$REPO/vim/plug.vim.version")"
assert_exit 1 bash "$REPO/scripts/bump-plugins.sh"

# Moved pins are rewritten, with a link to review the change
assert_eq "$NEW" "$(vim_pin tpope/vim-surround)" "vim-surround's pin"
assert_eq "$NEW" "$(tmux_pin tmux-plugins/tmux-yank)" "tmux-yank's pin"
assert_contains "$RUN_OUTPUT" "https://github.com/tpope/vim-surround/compare/$old_surround...$NEW"
assert_contains "$RUN_OUTPUT" "https://github.com/tmux-plugins/tmux-yank/compare/$old_yank...$NEW"
# Pins still at HEAD say so
assert_eq "$old_sensible" "$(vim_pin tpope/vim-sensible)" "vim-sensible's pin"
assert_contains "$RUN_OUTPUT" "tpope/vim-sensible: unchanged"
# A HEAD it can't read keeps the pin and fails the script
assert_eq "$old_fzf" "$(vim_pin junegunn/fzf.vim)" "fzf.vim's pin"
assert_contains "$RUN_OUTPUT" "Couldn't read junegunn/fzf.vim's HEAD"
# The rest of each file is as it was
assert_eq "$(sed -e "s/$old_surround/$NEW/" "$REPO_DIR/vim/vimrc")" "$(cat "$VIMRC")" "the vimrc, apart from the moved pin"
assert_eq "$(sed -e "s/$old_yank/$NEW/" "$REPO_DIR/tmux/plugins.lock")" "$(cat "$LOCK")" "plugins.lock, apart from the moved pin"

# vim-plug's newer release replaces the vendored one, from that release's tag
assert_eq 99.0.0 "$(cat "$REPO/vim/plug.vim.version")" "the vendored vim-plug's version"
assert_file_contains "$REPO/vim/plug.vim" "https://raw.githubusercontent.com/junegunn/vim-plug/99.0.0/plug.vim"
assert_contains "$RUN_OUTPUT" "https://github.com/junegunn/vim-plug/compare/$old_tag...99.0.0"
assert_contains "$RUN_OUTPUT" "just bump-plugins"
assert_eq "" "$(ls -A "$HOME")" "what the script left in HOME"

# Once every HEAD can be read, the script succeeds, and a second run changes nothing
echo "https://github.com/junegunn/fzf.vim $old_fzf" >> "$SANDBOX/heads"
assert_exit 0 bash "$REPO/scripts/bump-plugins.sh"
cp -R "$REPO" "$SANDBOX/before"
assert_exit 0 bash "$REPO/scripts/bump-plugins.sh"
assert_contains "$RUN_OUTPUT" "vim-plug: unchanged"
assert_not_contains "$RUN_OUTPUT" "compare/"
diff -r "$SANDBOX/before" "$REPO" > /dev/null || fail "a second run changed the files"

# --help prints the usage and changes nothing; other arguments fail
assert_exit 0 bash "$REPO/scripts/bump-plugins.sh" --help
assert_contains "$RUN_OUTPUT" "Usage"
assert_exit 2 bash "$REPO/scripts/bump-plugins.sh" extra
test_done
