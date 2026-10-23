#!/bin/bash

# write_back, json_merge, append_line, install_root_file, write_root_file, and the root-file item
# helpers: atomic replacement, json_merge's backups and bad input, and root files' modes and groups.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script lib/common.sh
load_script lib/system.sh

# read -p prints no question without a terminal, so confirm echoes it
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
        snapshot "$json"
        chmod 000 "$json"
        assert_exit 1 json_merge "$json" '.added = 1'
        chmod 644 "$json"
        assert_unchanged "$json" "though it couldn't be read"
        [ ! -e "$json.bak" ] || fail "json_merge backed up a file it couldn't read"
    fi
    ln -s "$HOME/json/nowhere.json" "$HOME/json/dangling.json"
    assert_exit 1 json_merge "$HOME/json/dangling.json" '.added = 1'
    [ -L "$HOME/json/dangling.json" ] || fail "json_merge replaced a dangling symlink"
    [ ! -e "$HOME/json/nowhere.json" ] || fail "json_merge wrote through a dangling symlink"

    # A failed backup: the .bak is taken and the dir is read-only
    edited="$HOME/ro-json/edited.json"
    mkdir -p "$HOME/ro-json"
    printf '"my edit"\n' > "$edited"
    printf 'older\n' > "$edited.bak"
    chmod 555 "$HOME/ro-json"
    export DOTFILES_BACKUP=yes
    assert_exit 1 json_merge "$edited" '"merged"'
    unset DOTFILES_BACKUP
    chmod 755 "$HOME/ro-json"
    assert_eq '"my edit"' "$(cat "$edited")" "file after a failed backup"

    # A failing or multi-value filter makes no backup, since jq runs before maybe_backup
    answer stdin
    settings="$HOME/badfilter/settings.json"
    mkdir -p "$HOME/badfilter"
    printf '{"mine": 1}\n' > "$settings"
    for filter in 'error("bad")' '.a, .b'; do
        assert_exit 1 json_merge "$settings" "$filter" <<< y
        assert_eq "settings.json" "$(/bin/ls "$HOME/badfilter")" "files after json_merge $filter"
        assert_eq '{"mine": 1}' "$(cat "$settings")" "settings after json_merge $filter"
    done
    for bad in '{"a": 0}
{"a": 1}' '{"a": 1,}'; do
        printf '%s\n' "$bad" > "$settings"
        ! json_applied "$settings" '.a = 1' || fail "json_applied passed $bad"
        assert_exit 1 json_merge "$settings" '.a = 1' <<< y
        assert_eq "settings.json" "$(/bin/ls "$HOME/badfilter")" "files after json_merge on $bad"
        assert_eq "$bad" "$(cat "$settings")" "settings after json_merge on $bad"
    done
    printf '{"mine": 1}\n' > "$settings"
    assert_exit 0 json_merge "$settings" '.a = 1' <<< y
    assert_eq '{"mine": 1}' "$(cat "$settings.bak")" "backup after json_merge"
    assert_eq 1 "$(jq .a "$settings")" "settings after json_merge"
    # json_applied puts its comparison on its own line, after a trailing comment
    assert_exit 0 json_applied "$settings" '.a = 1
# a comment on the last line'
    assert_exit 1 json_applied "$settings" '.a = 2
# a comment on the last line'
    rm "$settings.bak"
    printf '{"a":1,  "mine":1}\n' > "$settings"
    assert_exit 0 json_merge "$settings" '.a = 1' <<< y
    assert_eq "settings.json" "$(/bin/ls "$HOME/badfilter")" "files after json_merge with nothing to change"
    assert_eq '{"a":1,  "mine":1}' "$(cat "$settings")" "settings after json_merge with nothing to change"
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
snapshot "$dest"
printf 'three\n' > "$src"
for cmd in install mv; do
    stub "$cmd" 'exit 1'
    assert_exit 1 install_root_file "$src" "$dest"
    rm "$STUB_DIR/$cmd"
    assert_unchanged "$dest" "after a failed $cmd"
    assert_eq 640 "$(file_mode "$dest")" "mode after a failed $cmd"
    assert_eq 10-example.conf "$(/bin/ls -A "$dir")" "files after a failed $cmd"
done
stub mv 'exit 1'
assert_exit 1 write_root_file "$dest" "five"
rm "$STUB_DIR/mv"
assert_unchanged "$dest" "after a failed write_root_file"
assert_eq 10-example.conf "$(/bin/ls -A "$dir")" "files after a failed write_root_file"

# The group is set in the install that writes the file, so a failed chgrp can't leave it root:root
dest="$SANDBOX/etc/nut/upsd.users"
assert_exit 0 write_root_file "$dest" "secret" 0640 nut
assert_eq secret "$(cat "$dest")" "file write_root_file wrote"
assert_eq 640 "$(file_mode "$dest")" "mode write_root_file set"
assert_file_contains "$STUB_LOG" "sudo install -m 0640 -g nut "
: > "$STUB_LOG"
printf 'other\n' > "$SANDBOX/src"
assert_exit 0 install_root_file "$SANDBOX/src" "$dest" "" nut
assert_eq other "$(cat "$dest")" "file install_root_file wrote"
assert_eq 640 "$(file_mode "$dest")" "mode install_root_file kept"
assert_file_contains "$STUB_LOG" "sudo install -m 640 -g nut "

# install would move the new file into a directory destination
for kind in dir link; do
    dest="$SANDBOX/etc/sleep.conf.d/10-$kind.conf"
    if [ "$kind" == dir ]; then
        mkdir -p "$dest"
    else
        mkdir -p "$SANDBOX/etc/real-dir"
        ln -s "$SANDBOX/etc/real-dir" "$dest"
    fi
    assert_exit 1 write_root_file "$dest" "x"
    assert_eq "" "$(/bin/ls -A "$dest/")" "files in a $kind destination"
done

# stat reads 777 for the link, so the target's own mode must be kept
target="$SANDBOX/etc/real/target.conf"
link="$SANDBOX/etc/linked.conf"
mkdir -p "$(dirname "$target")"
printf 'old\n' > "$target"
chmod 640 "$target"
ln -s "$target" "$link"
assert_exit 0 write_root_file "$link" "new"
[ -L "$link" ] || fail "install_root_file replaced the symlink"
assert_eq new "$(cat "$target")" "symlink target after write_root_file"
assert_eq 640 "$(file_mode "$target")" "symlink target's mode after write_root_file"
assert_eq target.conf "$(/bin/ls -A "$(dirname "$target")")" "files beside the symlink target"
ln -s "$SANDBOX/etc/nowhere.conf" "$SANDBOX/etc/dangling.conf"
assert_exit 1 write_root_file "$SANDBOX/etc/dangling.conf" "new"
[ -L "$SANDBOX/etc/dangling.conf" ] || fail "install_root_file replaced a dangling symlink"
[ ! -e "$SANDBOX/etc/nowhere.conf" ] || fail "write_root_file wrote through a dangling symlink"

# A new directory gets 755 under any umask, so the users hooks run as can read it
(
    umask 077
    write_root_file "$SANDBOX/usr/local/lib/dotfiles/ntfy.sh" "lib" > /dev/null
)
assert_eq 755 "$(file_mode "$SANDBOX/usr/local/lib/dotfiles")" "mode of a new directory"
mkdir -p "$SANDBOX/etc/private"
chmod 750 "$SANDBOX/etc/private"
assert_exit 0 write_root_file "$SANDBOX/etc/private/file" "x"
assert_eq 750 "$(file_mode "$SANDBOX/etc/private")" "mode of an existing directory"
# --- write_root_content takes variable names, so it works as an item's fix ---
CONF="$SANDBOX/etc/apt/apt.conf.d/50 two words"
CONF_CONTENT='Unattended-Upgrade::Origins-Pattern { "origin=Docker"; };
// a second line'
conf_written() { file_is "$CONF" "$CONF_CONTENT"; }
items_reset
item --sudo "conf" "Write conf" conf_written "write_root_content CONF CONF_CONTENT 0640"
assert_exit 0 items_apply
assert_eq "$CONF_CONTENT" "$(cat "$CONF")" "the content write_root_content wrote"
assert_eq 640 "$(file_mode "$CONF")" "the mode write_root_content gave"
assert_exit 0 items_ok

# --- root_copy_current and install_root_copy: a hook must be executable, whatever the repo's mode ---
src="$SANDBOX/hook-src"
hook="$SANDBOX/etc/run.d/50hook"
echo "echo hi" > "$src"
chmod 644 "$src"
! root_copy_current "$src" "$hook" 0755 || fail "a missing hook counts as current"
assert_exit 0 install_root_copy "$src" "$hook" 0755
assert_exit 0 root_copy_current "$src" "$hook" 0755
assert_eq 755 "$(file_mode "$hook")" "the hook's mode"
chmod 644 "$hook"
assert_exit 1 root_copy_current "$src" "$hook" 0755
assert_exit 0 root_copy_current "$src" "$hook" 0644
test_done
