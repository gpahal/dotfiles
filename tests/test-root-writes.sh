#!/bin/bash
set -euo pipefail

# install_root_file and write_root_file replace a root-owned file by moving a temp file from the
# same directory into place, so a failed write leaves the old file whole and no temp file behind.
# The file keeps its mode unless one is given, and a new one gets 644. sudo runs the command.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh
stub sudo 'exec env "$@"'

dir="$SANDBOX/etc/example.d"
dest="$dir/10-example.conf"
src="$SANDBOX/src"

# A new file, in a directory that doesn't exist yet
printf 'one\n' > "$src"
assert_exit 0 install_root_file "$src" "$dest"
assert_eq one "$(cat "$dest")" "a new file"
assert_eq 644 "$(file_mode "$dest")" "mode of a new file"
assert_eq one "$(cat "$src")" "the source after install_root_file"

# An existing file keeps its mode, and is replaced, not written through
chmod 640 "$dest"
inode="$(/bin/ls -i "$dest" | awk '{print $1}')"
printf 'two\n' > "$src"
assert_exit 0 install_root_file "$src" "$dest"
assert_eq two "$(cat "$dest")" "a replaced file"
assert_eq 640 "$(file_mode "$dest")" "mode of a replaced file"
[ "$inode" != "$(/bin/ls -i "$dest" | awk '{print $1}')" ] || fail "install_root_file wrote through the file"
assert_eq 10-example.conf "$(/bin/ls -A "$dir")" "files beside a replaced file"

# A given mode wins
assert_exit 0 install_root_file "$src" "$dest" 0600
assert_eq 600 "$(file_mode "$dest")" "a given mode"

# A failed install or mv leaves the file as it was, and no temp file
chmod 644 "$dest"
cp -p "$dest" "$SANDBOX/before"
printf 'three\n' > "$src"
for cmd in install mv; do
    stub "$cmd" 'exit 1'
    assert_exit 1 install_root_file "$src" "$dest"
    rm "$STUB_DIR/$cmd"
    assert_exit 0 cmp -s "$dest" "$SANDBOX/before"
    assert_eq 644 "$(file_mode "$dest")" "mode after a failed $cmd"
    assert_eq 10-example.conf "$(/bin/ls -A "$dir")" "files after a failed $cmd"
done

# write_root_file writes the content with a newline, through the same path
assert_exit 0 write_root_file "$dest" "four"
assert_eq "four" "$(cat "$dest")" "write_root_file's content"
assert_eq 5 "$(wc -c < "$dest" | tr -d ' ')" "write_root_file's size"
stub mv 'exit 1'
assert_exit 1 write_root_file "$dest" "five"
rm "$STUB_DIR/mv"
assert_eq four "$(cat "$dest")" "the file after a failed write_root_file"
assert_eq 10-example.conf "$(/bin/ls -A "$dir")" "files after a failed write_root_file"
test_done
