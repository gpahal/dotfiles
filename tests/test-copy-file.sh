#!/bin/bash

# copy_file, status_file, and maybe_backup: replacing installed configs, their modes, and backup names.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script lib/common.sh

src="$SANDBOX/repo/config.yml"
# A path with spaces, like lazygit's config on macOS
dest="$HOME/Library/Application Support/tool/config.yml"
mkdir -p "$SANDBOX/repo"

# read -p prints no question without a terminal, so confirm echoes it
printf 'hello\n' > "$src"
assert_exit 0 copy_file "$src" "$dest"
assert_eq "hello" "$(cat "$dest")" "installed file"
inode="$(/bin/ls -i "$dest" | awk '{print $1}')"
assert_exit 0 copy_file "$src" "$dest"
assert_eq "$inode" "$(/bin/ls -i "$dest" | awk '{print $1}')" "inode after a second copy"

# A repo update or hand edit is replaced without a question or backup, even with --backup
answer stdin
for change in repo edit; do
    if [ "$change" == repo ]; then
        printf 'hello2\n' > "$src"
    else
        printf 'my edit\n' > "$dest"
    fi
    export DOTFILES_BACKUP=yes
    assert_exit 0 copy_file "$src" "$dest" <<< y
    unset DOTFILES_BACKUP
    assert_not_contains "$RUN_OUTPUT" "?" "copy after a $change change"
    assert_eq "hello2" "$(cat "$dest")" "file after a $change change"
    assert_eq "config.yml" "$(/bin/ls -A "$(dirname "$dest")")" "files after a $change change"
done
assert_eq "" "$(/bin/ls -A "$HOME/.local/state/dotfiles" 2>/dev/null)" "state files after copies"
load_script lib/common.sh

src2="$SANDBOX/repo/vimrc"
dest2="$HOME/.vimrc"
printf 'v1\n' > "$src2"
assert_exit 0 copy_file "$src2" "$dest2"
assert_exit 0 status_file "$src2" "$dest2"
assert_eq "  ok         ~/.vimrc" "$RUN_OUTPUT" "status of a matching file"
printf 'edit\n' > "$dest2"
assert_exit 0 status_file "$src2" "$dest2"
assert_eq "  missing    ~/.vimrc differs from the repo's $src2" "$RUN_OUTPUT" "status of a differing file"
assert_eq "edit" "$(cat "$dest2")" "file after status_file"
rm -f "$dest2"
assert_exit 0 status_file "$src2" "$dest2"
assert_eq "  missing    ~/.vimrc" "$RUN_OUTPUT" "status of a missing file"

printf '#!/bin/sh\n' > "$SANDBOX/repo/cmd"
chmod 755 "$SANDBOX/repo/cmd"
mkdir -p "$HOME/.local/bin"
cp "$SANDBOX/repo/cmd" "$HOME/.local/bin/cmd"
chmod 644 "$HOME/.local/bin/cmd"
assert_exit 0 status_file "$SANDBOX/repo/cmd" "$HOME/.local/bin/cmd"
assert_eq "  missing    ~/.local/bin/cmd isn't executable" "$RUN_OUTPUT" "status of a non-executable command"
chmod 755 "$HOME/.local/bin/cmd"
assert_exit 0 status_file "$SANDBOX/repo/cmd" "$HOME/.local/bin/cmd"
assert_eq "  ok         ~/.local/bin/cmd" "$RUN_OUTPUT" "status of an executable command"

# Under ||, where set -e is off
ro="$HOME/read-only"
mkdir -p "$ro"
chmod 555 "$ro"
copy_file_or_7() {
    copy_file "$@" || return 7
}
copy_or_7() {
    copy_file_or_7 "$src" "$ro/config.yml"
}
assert_exit 7 copy_or_7
chmod 755 "$ro"

# Through a symlink, the target is replaced and keeps its mode, and the link stays
mkdir -p "$HOME/real"
printf 'old\n' > "$HOME/real/linked.yml"
chmod 600 "$HOME/real/linked.yml"
ln -s real/linked.yml "$HOME/linked.yml"
assert_exit 0 copy_file "$src" "$HOME/linked.yml"
[ -L "$HOME/linked.yml" ] || fail "copy_file replaced the symlink"
assert_eq hello2 "$(cat "$HOME/real/linked.yml")" "symlink target after copy_file"
assert_eq 600 "$(file_mode "$HOME/real/linked.yml")" "symlink target's mode after copy_file"
assert_eq linked.yml "$(/bin/ls -A "$HOME/real")" "files beside the symlink target after copy_file"

# mv would move the copy into a directory
mkdir -p "$HOME/dir.yml"
assert_exit 1 copy_file "$src" "$HOME/dir.yml"
assert_eq "" "$(/bin/ls -A "$HOME/dir.yml")" "files in a directory destination"

if [ "$(id -u)" -ne 0 ]; then
    printf 'old\n' > "$HOME/locked.yml"
    chmod 444 "$HOME/locked.yml"
    assert_exit 1 copy_file "$src" "$HOME/locked.yml"
    assert_contains "$RUN_OUTPUT" "$HOME/locked.yml is read-only, so left it unchanged."
    assert_eq old "$(cat "$HOME/locked.yml")" "read-only file after copy_file"
fi

(
    umask 077
    copy_file "$src" "$HOME/modes/plain" > /dev/null
    copy_file "$SANDBOX/repo/cmd" "$HOME/modes/cmd" > /dev/null
)
assert_eq 644 "$(file_mode "$HOME/modes/plain")" "mode of a new file"
assert_eq 755 "$(file_mode "$HOME/modes/cmd")" "mode of a new executable"
chmod 644 "$HOME/modes/cmd"
assert_exit 0 copy_file "$SANDBOX/repo/cmd" "$HOME/modes/cmd"
assert_eq 755 "$(file_mode "$HOME/modes/cmd")" "mode of an executable that lost its bit"
# A replaced file keeps a mode set by hand
chmod 600 "$HOME/modes/plain"
printf 'changed\n' >> "$HOME/modes/plain"
assert_exit 0 copy_file "$src" "$HOME/modes/plain"
assert_eq 600 "$(file_mode "$HOME/modes/plain")" "mode of a replaced file"
assert_eq "" "$(find "$HOME/modes" -name '*.bak*')" "backups of an executable that lost its bit"

# Same-second backups get -2, -3 names; a version already backed up reuses its file
# shellcheck disable=SC2329 # maybe_backup calls it
date() { echo 20260101-000000; }
f="$HOME/same-second"
echo v0 > "$f.bak"
export DOTFILES_BACKUP=yes
for v in v1 v2 v3; do
    echo "$v" > "$f"
    maybe_backup "$f" > /dev/null
done
assert_eq "v1" "$(cat "$f.bak.20260101-000000")" "first same-second backup"
assert_eq "v2" "$(cat "$f.bak.20260101-000000-2")" "second same-second backup"
assert_eq "v3" "$(cat "$f.bak.20260101-000000-3")" "third same-second backup"
assert_eq "v0" "$(cat "$f.bak")" "the .bak"
echo v2 > "$f"
assert_exit 0 maybe_backup "$f"
assert_eq "  $f is already backed up to $f.bak.20260101-000000-2" "$RUN_OUTPUT" "backing up a version already backed up"
[ ! -e "$f.bak.20260101-000000-4" ] || fail "maybe_backup made a new copy of a version already backed up"
echo v0 > "$f"
assert_exit 0 maybe_backup "$f"
assert_eq "" "$RUN_OUTPUT" "backing up a version the .bak holds"
unset DOTFILES_BACKUP
unset -f date
test_done
