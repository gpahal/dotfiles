#!/bin/bash
set -euo pipefail

# write_back moves a temp file from the same directory into place, so a failed write can't leave
# a settings file cut short. The file keeps its mode, and a symlink stays a symlink while its
# target is replaced the same way. json_merge starts a missing, empty, or whitespace-only file from
# {}, and fails on one it can't read, leaving it as it is. append_line adds a line only once, and
# fails only when it can't write the file.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

file="$HOME/settings.json"
printf 'old\n' > "$file"
chmod 640 "$file"
before="$(/bin/ls -i "$file")"
new="$(mktemp)"
printf 'new\n' > "$new"
assert_exit 0 write_back "$new" "$file"
assert_eq new "$(cat "$file")" "file after write_back"
[ "$before" != "$(/bin/ls -i "$file")" ] || fail "write_back wrote through the file instead of moving a new one into place"
assert_eq "-rw-r-----" "$(/bin/ls -l "$file" | cut -c1-10)" "mode after write_back"
[ ! -e "$new" ] || fail "write_back left the temp file"
assert_eq "settings.json" "$(/bin/ls -A "$HOME")" "files in the directory after write_back"

# A new file gets the usual mode
umask 022
new="$(mktemp)"
printf 'fresh\n' > "$new"
assert_exit 0 write_back "$new" "$HOME/fresh.json"
assert_eq "-rw-r--r--" "$(/bin/ls -l "$HOME/fresh.json" | cut -c1-10)" "mode of a new file"

# A symlink stays a link, and its target is replaced whole in its own directory, keeping its mode.
# The relative link goes through another link, to check readlink -f follows the chain.
mkdir -p "$HOME/real"
printf 'old\n' > "$HOME/real/target.json"
chmod 640 "$HOME/real/target.json"
ln -s "$HOME/real/target.json" "$HOME/link.json"
ln -s link.json "$HOME/relative-link.json"
for link in link.json relative-link.json; do
    inode="$(/bin/ls -i "$HOME/real/target.json" | awk '{print $1}')"
    new="$(mktemp)"
    printf 'linked through %s\n' "$link" > "$new"
    assert_exit 0 write_back "$new" "$HOME/$link"
    [ -L "$HOME/$link" ] || fail "write_back replaced the symlink $link"
    assert_eq "linked through $link" "$(cat "$HOME/real/target.json")" "symlink target after write_back through $link"
    assert_eq "-rw-r-----" "$(/bin/ls -l "$HOME/real/target.json" | cut -c1-10)" "symlink target's mode after write_back through $link"
    [ "$inode" != "$(/bin/ls -i "$HOME/real/target.json" | awk '{print $1}')" ] ||
        fail "write_back wrote through $link instead of replacing its target"
    assert_eq target.json "$(/bin/ls -A "$HOME/real")" "files beside the symlink target after write_back through $link"
    [ ! -e "$new" ] || fail "write_back through $link left the temp file"
done

# A write that fails leaves the file as it was and keeps the new contents
if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$HOME/ro"
    printf 'old\n' > "$HOME/ro/settings.json"
    chmod 555 "$HOME/ro"
    new="$(mktemp)"
    printf 'new\n' > "$new"
    assert_exit 1 write_back "$new" "$HOME/ro/settings.json"
    assert_eq old "$(cat "$HOME/ro/settings.json")" "file after a failed write_back"
    assert_contains "$RUN_OUTPUT" "The new contents are in $new"
    [ -e "$new" ] || fail "a failed write_back removed the new contents"
    # The same through a symlink to a file in that directory
    ln -s "$HOME/ro/settings.json" "$HOME/ro-link.json"
    assert_exit 1 write_back "$new" "$HOME/ro-link.json"
    [ -L "$HOME/ro-link.json" ] || fail "a failed write_back replaced the symlink"
    assert_eq old "$(cat "$HOME/ro/settings.json")" "symlink target after a failed write_back"
    assert_contains "$RUN_OUTPUT" "The new contents are in $new"
    [ -e "$new" ] || fail "a failed write_back through a symlink removed the new contents"
    chmod 755 "$HOME/ro"
fi

# json_merge starts a missing, empty, or whitespace-only file from {}
if command -v jq &>/dev/null; then
    for start in missing empty blank; do
        json="$HOME/json/$start.json"
        mkdir -p "$HOME/json"
        case "$start" in
            empty) : > "$json" ;;
            blank) printf ' \n\t\n' > "$json" ;;
        esac
        assert_exit 0 json_merge "$json" '.added = 1'
        assert_eq '{"added":1}' "$(jq -c . "$json")" "json_merge on a $start file"
    done
    # A file it can't read fails, and stays as it is, before any backup
    if [ "$(id -u)" -ne 0 ]; then
        json="$HOME/json/locked.json"
        printf '{"existing":"keep me"}\n' > "$json"
        cp "$json" "$HOME/locked-before"
        chmod 000 "$json"
        assert_exit 1 json_merge "$json" '.added = 1'
        chmod 644 "$json"
        assert_contains "$RUN_OUTPUT" "Couldn't read $json, so it was left as it is."
        assert_exit 0 cmp -s "$json" "$HOME/locked-before"
        [ ! -e "$json.bak" ] || fail "json_merge backed up a file it couldn't read"
    fi
    # So does a dangling symlink, which stays a link
    ln -s "$HOME/json/nowhere.json" "$HOME/json/dangling.json"
    assert_exit 1 json_merge "$HOME/json/dangling.json" '.added = 1'
    [ -L "$HOME/json/dangling.json" ] || fail "json_merge replaced a dangling symlink"
    [ ! -e "$HOME/json/nowhere.json" ] || fail "json_merge wrote through a dangling symlink"
else
    skip_rest "jq isn't installed, so json_merge isn't tested"
fi

# file_mode reads the mode on either OS even when a test overrides is_macos, as
# test-t3-service.sh does, without stat printing an error
chmod 640 "$file"
for wrong_os in true false; do
    eval "is_macos() { $wrong_os; }"
    assert_exit 0 file_mode "$file"
    assert_eq 640 "$RUN_OUTPUT" "file_mode with is_macos $wrong_os"
done

# append_line adds a line once, even one grep would read as an option
lines="$HOME/lines"
for line in '-e x' '--' 'plain'; do
    assert_exit 0 append_line "$line" "$lines"
    assert_exit 0 append_line "$line" "$lines"
    assert_exit 0 has_line "$line" "$lines"
done
assert_eq "$(printf '%s\n' '-e x' '--' plain)" "$(cat "$lines")" "file after appending each line twice"
# It fails only when the file can't be written
mkdir "$HOME/dir"
assert_exit 1 append_line x "$HOME/dir"
test_done
