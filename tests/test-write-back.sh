#!/bin/bash
set -euo pipefail

# write_back moves a temp file from the same directory into place, so a failed write can't leave
# a settings file cut short. The file keeps its mode, and a symlink stays a symlink. append_line
# adds a line only once, and fails only when it can't write the file.

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

# A symlink is written through, so it still points at its target
mkdir -p "$HOME/real"
printf 'old\n' > "$HOME/real/target.json"
ln -s "$HOME/real/target.json" "$HOME/link.json"
new="$(mktemp)"
printf 'linked\n' > "$new"
assert_exit 0 write_back "$new" "$HOME/link.json"
[ -L "$HOME/link.json" ] || fail "write_back replaced the symlink"
assert_eq linked "$(cat "$HOME/real/target.json")" "symlink target after write_back"

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
    chmod 755 "$HOME/ro"
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
