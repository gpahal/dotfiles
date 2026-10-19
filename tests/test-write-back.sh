#!/bin/bash
set -euo pipefail

# write_back, json_merge, append_line, install_root_file, and write_root_file: atomic replacement.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh
load_script lib/system.sh

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

new="$(mktemp)"
printf 'replacement\n' > "$new"
stub cp 'for last; do :; done; printf part > "$last"; exit 1'
assert_exit 1 write_back "$new" "$file"
rm -f "$STUB_DIR/cp"
assert_eq new "$(cat "$file")" "file after a partial copy"
assert_eq replacement "$(cat "$new")" "new contents after a partial copy"
assert_eq settings.json "$(/bin/ls -A "$HOME")" "files after a partial copy"
rm "$new"

# Unlike copy_file, write_back honors the umask
umask 077
new="$(mktemp)"
printf 'fresh\n' > "$new"
assert_exit 0 write_back "$new" "$HOME/fresh.json"
assert_eq 600 "$(file_mode "$HOME/fresh.json")" "mode of a new file"
umask 022

# relative-link.json chains through link.json, so readlink -f must follow both
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

ln -s "$HOME/real/nowhere.json" "$HOME/dangling.json"
new="$(mktemp)"
printf 'new\n' > "$new"
assert_exit 1 write_back "$new" "$HOME/dangling.json"
assert_contains "$RUN_OUTPUT" "Couldn't write $HOME/dangling.json. The new contents are in $new."
[ -L "$HOME/dangling.json" ] || fail "write_back replaced a dangling symlink"
[ ! -e "$HOME/real/nowhere.json" ] || fail "write_back wrote through a dangling symlink"
[ -e "$new" ] || fail "a failed write_back through a dangling symlink removed the new contents"
rm -f "$new" "$HOME/dangling.json"

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
    chmod 755 "$HOME/ro"
    # A read-only file stays, as with cp, though its directory would let a rename replace it
    printf 'old\n' > "$HOME/locked.conf"
    chmod 444 "$HOME/locked.conf"
    ln -s locked.conf "$HOME/locked-link.conf"
    for name in locked.conf locked-link.conf; do
        new="$(mktemp)"
        printf 'new\n' > "$new"
        assert_exit 1 write_back "$new" "$HOME/$name"
        assert_eq old "$(cat "$HOME/locked.conf")" "read-only file after write_back to $name"
        assert_eq 444 "$(file_mode "$HOME/locked.conf")" "read-only file's mode after write_back to $name"
        assert_contains "$RUN_OUTPUT" "$HOME/$name is read-only, so left it unchanged. The new contents are in $new."
        [ -e "$new" ] || fail "a write_back to read-only $name removed the new contents"
    done
    [ -L "$HOME/locked-link.conf" ] || fail "a write_back replaced the symlink to a read-only file"
fi

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
    ln -s "$HOME/json/nowhere.json" "$HOME/json/dangling.json"
    assert_exit 1 json_merge "$HOME/json/dangling.json" '.added = 1'
    [ -L "$HOME/json/dangling.json" ] || fail "json_merge replaced a dangling symlink"
    [ ! -e "$HOME/json/nowhere.json" ] || fail "json_merge wrote through a dangling symlink"
else
    skip_rest "jq isn't installed, so json_merge isn't tested"
fi

# Lines grep would read as options
lines="$HOME/lines"
for line in '-e x' '--' 'plain'; do
    assert_exit 0 append_line "$line" "$lines"
    assert_exit 0 append_line "$line" "$lines"
    assert_exit 0 has_line "$line" "$lines"
done
assert_eq "$(printf '%s\n' '-e x' '--' plain)" "$(cat "$lines")" "file after appending each line twice"
mkdir "$HOME/dir"
assert_exit 1 append_line x "$HOME/dir"

stub_sudo_exec
dir="$SANDBOX/etc/example.d"
dest="$dir/10-example.conf"
src="$SANDBOX/src"
printf 'one\n' > "$src"
assert_exit 0 install_root_file "$src" "$dest"
assert_eq one "$(cat "$dest")" "a new root file"
assert_eq 644 "$(file_mode "$dest")" "mode of a new root file"
assert_eq one "$(cat "$src")" "the source after install_root_file"
chmod 640 "$dest"
inode="$(/bin/ls -i "$dest" | awk '{print $1}')"
printf 'two\n' > "$src"
assert_exit 0 install_root_file "$src" "$dest"
assert_eq two "$(cat "$dest")" "a replaced root file"
assert_eq 640 "$(file_mode "$dest")" "mode of a replaced root file"
[ "$inode" != "$(/bin/ls -i "$dest" | awk '{print $1}')" ] || fail "install_root_file wrote through the file"
assert_eq 10-example.conf "$(/bin/ls -A "$dir")" "files beside a replaced root file"
cp -p "$dest" "$SANDBOX/before"
printf 'three\n' > "$src"
for cmd in install mv; do
    stub "$cmd" 'exit 1'
    assert_exit 1 install_root_file "$src" "$dest"
    rm "$STUB_DIR/$cmd"
    assert_exit 0 cmp -s "$dest" "$SANDBOX/before"
    assert_eq 640 "$(file_mode "$dest")" "mode after a failed $cmd"
    assert_eq 10-example.conf "$(/bin/ls -A "$dir")" "files after a failed $cmd"
done
assert_exit 0 write_root_file "$dest" "four"
assert_eq "four" "$(cat "$dest")" "write_root_file's content"
assert_eq 5 "$(wc -c < "$dest" | tr -d ' ')" "write_root_file's size"
stub mv 'exit 1'
assert_exit 1 write_root_file "$dest" "five"
rm "$STUB_DIR/mv"
assert_eq four "$(cat "$dest")" "the file after a failed write_root_file"
assert_eq 10-example.conf "$(/bin/ls -A "$dir")" "files after a failed write_root_file"
test_done
