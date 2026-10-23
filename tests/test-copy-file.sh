#!/bin/bash
set -euo pipefail

# copy_file, status_file, and backup_file: replacing installed configs, their modes, and backup names.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

src="$SANDBOX/repo/config.yml"
# A path with spaces, like lazygit's config on macOS
dest="$HOME/Library/Application Support/tool/config.yml"
mkdir -p "$SANDBOX/repo"

# read -p prints no question without a terminal, so confirm echoes it
fake_terminal() {
    replace_fn is_interactive true
    replace_fn confirm 'local reply; echo "$1"; read -r reply; [ "$reply" == y ]'
}

printf 'hello\n' > "$src"
assert_exit 0 copy_file "$src" "$dest"
assert_eq "hello" "$(cat "$dest")" "installed file"
inode="$(/bin/ls -i "$dest" | awk '{print $1}')"
assert_exit 0 copy_file "$src" "$dest"
assert_eq "$inode" "$(/bin/ls -i "$dest" | awk '{print $1}')" "inode after a second copy"

# A repo update or hand edit is replaced without a question or backup, even with --backup
fake_terminal
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
assert_eq "" "$(find "$HOME/modes" -name '*.bak*')" "backups of an executable that lost its bit"

# Same-second backups get -2, -3 names; a version already backed up reuses its file
# shellcheck disable=SC2329 # backup_path calls it
date() { echo 20260101-000000; }
f="$HOME/same-second"
echo v0 > "$f.bak"
for v in v1 v2 v3; do
    echo "$v" > "$f"
    backup_file "$f" > /dev/null
done
assert_eq "v1" "$(cat "$f.bak.20260101-000000")" "first same-second backup"
assert_eq "v2" "$(cat "$f.bak.20260101-000000-2")" "second same-second backup"
assert_eq "v3" "$(cat "$f.bak.20260101-000000-3")" "third same-second backup"
assert_eq "v0" "$(cat "$f.bak")" "the .bak"
echo v2 > "$f"
assert_exit 0 backup_file "$f"
[ ! -e "$f.bak.20260101-000000-4" ] || fail "backup_file made a new copy of a version already backed up"
echo v4 > "$f"
backup_file "$f" "$f.bak" > /dev/null
assert_eq "v0" "$(cat "$f.bak")" "the .bak after backing up to it by name"
assert_eq "v4" "$(cat "$f.bak.20260101-000000-4")" "backup given a taken name"
unset -f date
test_done
