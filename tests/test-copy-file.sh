#!/bin/bash
set -euo pipefail

# copy_file and copy_file_ask record what they install, replace unedited files silently, and back
# up files edited by hand. status_file tells the two kinds of difference apart.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

HELLO_SHA=5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
record="$HOME/.local/state/dotfiles/installed-files"
src="$SANDBOX/repo/config.yml"
# A path with spaces, like lazygit's config on macOS
dest="$HOME/Library/Application Support/tool/config.yml"
mkdir -p "$SANDBOX/repo"

# Act as if stdin were a terminal, answered from the test's stdin. read -p prints no question
# without a terminal, so confirm prints it. load_script lib/common.sh puts the real ones back.
# shellcheck disable=SC2329 # copy_file calls them
fake_terminal() {
    is_interactive() { true; }
    confirm() {
        local reply
        echo "$1"
        read -r reply
        [ "$reply" == y ]
    }
}

# First install: copied and recorded
printf 'hello\n' > "$src"
assert_exit 0 copy_file "$src" "$dest"
assert_contains "$RUN_OUTPUT" "Copied"
assert_eq "hello" "$(cat "$dest")" "installed file"
assert_eq "$HELLO_SHA  $dest" "$(cat "$record")" "record after first install"
assert_eq "$HELLO_SHA" "$(recorded_sha256 "$dest")" "recorded_sha256"

# Unchanged: nothing copied, backed up, or rewritten
# mv gives the record a new inode, so an unchanged inode means it wasn't rewritten
before="$(/bin/ls -i "$record")"
assert_exit 0 copy_file "$src" "$dest"
assert_contains "$RUN_OUTPUT" "already up to date"
assert_not_contains "$RUN_OUTPUT" "Copied"
assert_eq "$before" "$(/bin/ls -i "$record")" "record's inode after an unchanged run"
[ ! -e "$dest.bak" ] || fail "an unchanged run made a backup"

# A second file gets its own line, and recording one file keeps the other's
src2="$SANDBOX/repo/vimrc"
dest2="$HOME/.vimrc"
printf 'hello\n' > "$src2"
assert_exit 0 copy_file "$src2" "$dest2"
assert_eq 2 "$(wc -l < "$record" | tr -d ' ')" "lines in the record"
assert_file_contains "$record" "$HELLO_SHA  $dest"
assert_file_contains "$record" "$HELLO_SHA  $dest2"

# Repo update: the installed file is what setup put there, so it's replaced with no backup
printf 'hello2\n' > "$src"
assert_exit 0 copy_file "$src" "$dest"
assert_contains "$RUN_OUTPUT" "Copied"
assert_not_contains "$RUN_OUTPUT" "Back"
assert_eq "hello2" "$(cat "$dest")" "file after a repo update"
[ ! -e "$dest.bak" ] || fail "a repo update made a backup"
assert_eq "$(file_sha256 "$src")" "$(recorded_sha256 "$dest")" "record after a repo update"
assert_eq "$HELLO_SHA" "$(recorded_sha256 "$dest2")" "the other file's record after a repo update"

# Hand edit, no terminal: backed up to .bak automatically, then replaced
printf 'my edit\n' > "$dest"
assert_exit 0 copy_file "$src" "$dest"
assert_contains "$RUN_OUTPUT" "Backed up $dest to $dest.bak"
assert_eq "my edit" "$(cat "$dest.bak")" ".bak after a hand edit"
assert_eq "hello2" "$(cat "$dest")" "file after a hand edit"

# Hand edit again, with a .bak that holds an older edit: a timestamped backup, the .bak kept
printf 'second edit\n' > "$dest"
assert_exit 0 copy_file "$src" "$dest"
assert_eq "my edit" "$(cat "$dest.bak")" "stale .bak"
stamped="$(find "$(dirname "$dest")" -name 'config.yml.bak.*')"
case "${stamped##*/}" in
    config.yml.bak.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) fail "no timestamped backup, found '$stamped'" ;;
esac
[ -z "$stamped" ] || assert_eq "second edit" "$(cat "$stamped")" "timestamped backup"
assert_contains "$RUN_OUTPUT" "Backed up $dest to $stamped"

# A .bak that already matches the edit is reused
rm -f "$stamped"
printf 'my edit\n' > "$dest"
assert_exit 0 copy_file "$src" "$dest"
assert_eq "" "$(find "$(dirname "$dest")" -name 'config.yml.bak.*')" "timestamped backups when .bak matches"

# No record yet: a differing file counts as edited
printf 'mine\n' > "$HOME/.zshrc-like"
printf 'repo\n' > "$SANDBOX/repo/zshrc-like"
assert_exit 0 copy_file "$SANDBOX/repo/zshrc-like" "$HOME/.zshrc-like"
assert_eq "mine" "$(cat "$HOME/.zshrc-like.bak")" "backup of an unrecorded file"

# --no-backup (DOTFILES_BACKUP=no): replaced with no backup
printf 'edit\n' > "$dest2"
export DOTFILES_BACKUP=no
assert_exit 0 copy_file "$src2" "$dest2"
unset DOTFILES_BACKUP
[ ! -e "$dest2.bak" ] || fail "--no-backup made a backup"
assert_eq "hello" "$(cat "$dest2")" "file after --no-backup"

# A terminal asks; DOTFILES_BACKUP=yes doesn't
fake_terminal
printf 'edit\n' > "$dest2"
assert_exit 0 copy_file "$src2" "$dest2" <<< n
assert_contains "$RUN_OUTPUT" "$dest2 was changed since setup installed it, and will be replaced. Back it up to $dest2.bak first?"
[ ! -e "$dest2.bak" ] || fail "answering no made a backup"
printf 'edit\n' > "$dest2"
assert_exit 0 copy_file "$src2" "$dest2" <<< y
assert_eq "edit" "$(cat "$dest2.bak")" ".bak after answering yes"
# With an older, different .bak, the question names the path the backup goes to
printf 'edit 2\n' > "$dest2"
assert_exit 0 copy_file "$src2" "$dest2" <<< y
assert_contains "$RUN_OUTPUT" "Back it up to $dest2.bak."
bak2="$(sed -n 's/.*Back it up to \(.*\) first?.*/\1/p' <<< "$RUN_OUTPUT")"
assert_eq "edit 2" "$(cat "$bak2")" "the backup at the path the question named"
rm -f "$dest2.bak" "$bak2"
printf 'edit\n' > "$dest2"
export DOTFILES_BACKUP=yes
assert_exit 0 copy_file "$src2" "$dest2" < /dev/null
unset DOTFILES_BACKUP
assert_not_contains "$RUN_OUTPUT" "Back it up"
assert_eq "edit" "$(cat "$dest2.bak")" ".bak after --backup"
# Put the real is_interactive and confirm back
load_script lib/common.sh

# copy_file_ask: a file setup installed and nobody edited is replaced without asking
zsrc="$SANDBOX/repo/settings.json"
zdest="$HOME/.config/zed/settings.json"
printf 'hello\n' > "$zsrc"
assert_exit 0 copy_file_ask "$zsrc" "$zdest"
assert_eq "$HELLO_SHA" "$(recorded_sha256 "$zdest")" "copy_file_ask's record after first install"
printf 'hello2\n' > "$zsrc"
assert_exit 0 copy_file_ask "$zsrc" "$zdest"
assert_contains "$RUN_OUTPUT" "Copied"
assert_eq "hello2" "$(cat "$zdest")" "copy_file_ask after a repo update"
assert_eq "$(file_sha256 "$zsrc")" "$(recorded_sha256 "$zdest")" "copy_file_ask's record after a repo update"
[ ! -e "$zdest.bak" ] || fail "copy_file_ask backed up an unedited file"

# An edited one is left alone without a terminal
printf 'my edit\n' > "$zdest"
assert_exit 0 copy_file_ask "$zsrc" "$zdest"
assert_contains "$RUN_OUTPUT" "Left $zdest unchanged"
assert_eq "my edit" "$(cat "$zdest")" "edited file copy_file_ask left alone"

# With a terminal, it asks once: yes replaces it and backs it up
fake_terminal
assert_exit 0 copy_file_ask "$zsrc" "$zdest" <<< y
assert_contains "$RUN_OUTPUT" "Replace it?"
assert_not_contains "$RUN_OUTPUT" "Back it up"
assert_eq "hello2" "$(cat "$zdest")" "copy_file_ask after answering yes"
assert_eq "my edit" "$(cat "$zdest.bak")" "copy_file_ask's backup"
assert_eq "$(file_sha256 "$zsrc")" "$(recorded_sha256 "$zdest")" "copy_file_ask's record after replacing an edit"
# With --no-backup, yes replaces it with no backup
rm -f "$zdest.bak"
printf 'another edit\n' > "$zdest"
export DOTFILES_BACKUP=no
assert_exit 0 copy_file_ask "$zsrc" "$zdest" <<< y
unset DOTFILES_BACKUP
assert_eq "hello2" "$(cat "$zdest")" "copy_file_ask after yes with --no-backup"
[ ! -e "$zdest.bak" ] || fail "copy_file_ask backed up with --no-backup"
load_script lib/common.sh

# status_file tells a newer repo version from a hand edit
printf 'unrecorded\n' > "$HOME/unrecorded-config"
record_before="$(cat "$INSTALLED_FILES")"
assert_exit 0 status_file "$src2" "$HOME/unrecorded-config" "merge by hand"
assert_contains "$RUN_OUTPUT" "differs, and setup has no record of installing it; merge by hand"
assert_not_contains "$RUN_OUTPUT" "was edited"
assert_eq "$record_before" "$(cat "$INSTALLED_FILES")" "status leaves installation records unchanged"
printf 'v1\n' > "$src2"
assert_exit 0 copy_file "$src2" "$dest2"
assert_exit 0 status_file "$src2" "$dest2"
assert_contains "$RUN_OUTPUT" "ok         ~/.vimrc"
printf 'v2\n' > "$src2"
assert_exit 0 status_file "$src2" "$dest2" "merge by hand"
assert_contains "$RUN_OUTPUT" "missing    ~/.vimrc differs from $src2: the repo has a newer version"
assert_not_contains "$RUN_OUTPUT" "merge by hand"
printf 'edit\n' > "$dest2"
assert_exit 0 status_file "$src2" "$dest2" "merge by hand"
assert_contains "$RUN_OUTPUT" "missing    ~/.vimrc was edited since setup installed it; merge by hand"
rm -f "$dest2"
assert_exit 0 status_file "$src2" "$dest2"
assert_eq "  missing    ~/.vimrc" "$RUN_OUTPUT" "status of a missing file"

# A command whose copy matches but lost its executable bit can't run
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

# The vim step end to end, in a fresh HOME and a copy of the repo whose vimrc the test edits
export HOME="$SANDBOX/home2"
mkdir -p "$HOME" "$SANDBOX/repo2"
cp -R "$REPO_DIR/lib" "$REPO_DIR/vim" "$SANDBOX/repo2/"
vim_step="$SANDBOX/repo2/vim/install.sh"
# No record, so a different ~/.vimrc is backed up without a terminal
printf 'old vimrc\n' > "$HOME/.vimrc"
assert_exit 0 "$BASH" "$vim_step"
assert_eq "old vimrc" "$(cat "$HOME/.vimrc.bak")" "backup on the first run"
assert_file_contains "$HOME/.local/state/dotfiles/installed-files" "  $HOME/.vimrc"
# A second run changes nothing
assert_exit 0 "$BASH" "$vim_step"
assert_contains "$RUN_OUTPUT" "already up to date"
assert_not_contains "$RUN_OUTPUT" "Copied"
assert_not_contains "$RUN_OUTPUT" "Backed up"
# A repo update replaces it with no backup
rm "$HOME/.vimrc.bak"
printf '" a repo change\n' >> "$SANDBOX/repo2/vim/vimrc"
assert_exit 3 "$BASH" "$vim_step" --status
assert_contains "$RUN_OUTPUT" "the repo has a newer version"
assert_exit 0 "$BASH" "$vim_step"
assert_contains "$RUN_OUTPUT" "Copied"
[ ! -e "$HOME/.vimrc.bak" ] || fail "the vim step backed up after a repo update"
# A hand edit is backed up, unless --no-backup says not to
printf '" my edit\n' >> "$HOME/.vimrc"
assert_exit 3 "$BASH" "$vim_step" --status
assert_contains "$RUN_OUTPUT" "was edited since setup installed it"
assert_exit 0 "$BASH" "$vim_step" --no-backup
[ ! -e "$HOME/.vimrc.bak" ] || fail "the vim step backed up with --no-backup"
printf '" my edit\n' >> "$HOME/.vimrc"
assert_exit 0 "$BASH" "$vim_step"
assert_file_contains "$HOME/.vimrc.bak" '" my edit'

# A backup that fails leaves the file as it is and fails, saying nothing was backed up: here the
# .bak holds another file, and the file's directory is read-only, so no new backup can be made
load_script lib/common.sh
edited="$HOME/ro/edited.yml"
mkdir -p "$HOME/ro"
printf 'repo\n' > "$SANDBOX/repo/edited.yml"
for copy in copy_file maybe_backup; do
    chmod 755 "$HOME/ro"
    # JSON, so json_merge's jq succeeds and it goes on to back the file up
    printf '"my edit"\n' > "$edited"
    printf 'older\n' > "$edited.bak"
    chmod 555 "$HOME/ro"
    if [ "$copy" == copy_file ]; then
        assert_exit 1 copy_file "$SANDBOX/repo/edited.yml" "$edited"
    else
        export DOTFILES_BACKUP=yes
        assert_exit 1 json_merge "$edited" '.'
        unset DOTFILES_BACKUP
    fi
    assert_eq '"my edit"' "$(cat "$edited")" "file after a failed backup ($copy)"
    assert_not_contains "$RUN_OUTPUT" "Backed up" "$copy output"
    assert_contains "$RUN_OUTPUT" "Couldn't back up $edited" "$copy output"
done
chmod 755 "$HOME/ro"

# maybe_backup with --backup never overwrites a .bak that holds something else: it writes a
# timestamped backup instead
settings="$HOME/settings.json"
printf '{"mine": 1}\n' > "$settings"
printf 'older backup\n' > "$settings.bak"
stub date 'echo stamp'
export DOTFILES_BACKUP=yes
assert_exit 0 maybe_backup "$settings"
unset DOTFILES_BACKUP
rm -f "$STUB_DIR/date"
assert_eq "older backup" "$(cat "$settings.bak")" ".bak after maybe_backup --backup"
assert_eq '{"mine": 1}' "$(cat "$settings.bak.stamp" 2>/dev/null)" "timestamped backup from maybe_backup"
assert_contains "$RUN_OUTPUT" "Backed up $settings to $settings.bak.stamp"
# Asked with a terminal, the question names where the backup goes
rm -f "$settings.bak.stamp"
fake_terminal
stub date 'echo stamp'
assert_exit 0 maybe_backup "$settings" <<< n
rm -f "$STUB_DIR/date"
assert_contains "$RUN_OUTPUT" "Back up $settings to $settings.bak.stamp?"
[ ! -e "$settings.bak.stamp" ] || fail "answering no made a backup"
load_script lib/common.sh

# A copy into a read-only directory fails, even when called under ||, which turns set -e off: no
# "Copied" and nothing recorded
ro="$HOME/read-only"
mkdir -p "$ro"
chmod 555 "$ro"
copy_file_or_7() {
    copy_file "$@" || return 7
}
copy_or_7() {
    copy_file_or_7 "$SANDBOX/repo/edited.yml" "$ro/edited.yml"
}
assert_exit 7 copy_or_7
assert_not_contains "$RUN_OUTPUT" "Copied"
assert_file_not_contains "$record" "$ro/edited.yml"
chmod 755 "$ro"

# A file that matches but was never recorded isn't backed up, and fails when the record can't be
# written, since a later run would take the unrecorded file for an edit
if [ "$(id -u)" -ne 0 ]; then
    printf 'same\n' > "$SANDBOX/repo/same.yml"
    cp "$SANDBOX/repo/same.yml" "$HOME/same.yml"
    state="$(dirname "$INSTALLED_FILES")"
    chmod 555 "$state"
    assert_exit 7 copy_file_or_7 "$SANDBOX/repo/same.yml" "$HOME/same.yml"
    chmod 755 "$state"
    assert_not_contains "$RUN_OUTPUT" "already up to date"
    assert_file_not_contains "$INSTALLED_FILES" "$HOME/same.yml"
    [ ! -e "$HOME/same.yml.bak" ] || fail "backed up a file that matches its source"
fi

# A file that can't be read can't be hashed, so it doesn't count as what setup installed, even
# with no record to compare against
if [ "$(id -u)" -ne 0 ]; then
    printf 'secret\n' > "$HOME/unreadable"
    chmod 000 "$HOME/unreadable"
    installed_unedited "$HOME/unreadable" 2>/dev/null && fail "an unreadable file counts as installed unedited"
    chmod 644 "$HOME/unreadable"
fi

# Backups in the same second: each new version gets its own -2, -3 name, none is overwritten, and
# a version already backed up reuses its file. date is pinned, so the second is the same.
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
backup_file "$f" > /dev/null
assert_eq "$f.bak.20260101-000000-2" "$BACKUP_PATH" "backup path of a version already backed up"
# A path given that holds something else isn't overwritten
echo v4 > "$f"
backup_file "$f" "$f.bak" > /dev/null
assert_eq "v0" "$(cat "$f.bak")" "the .bak after backing up to it by name"
assert_eq "v4" "$(cat "$f.bak.20260101-000000-4")" "backup given a taken name"
unset -f date

# A filter that fails, or yields several values, leaves the file alone, with no backup made or
# offered, since jq runs before maybe_backup
load_script lib/common.sh
fake_terminal
settings="$HOME/badfilter/settings.json"
mkdir -p "$HOME/badfilter"
printf '{"mine": 1}\n' > "$settings"
for filter in 'error("bad")' '.a, .b'; do
    assert_exit 1 json_merge "$settings" "$filter" <<< y
    assert_contains "$RUN_OUTPUT" "Couldn't update $settings with jq." "json_merge $filter"
    assert_not_contains "$RUN_OUTPUT" "Back up" "json_merge $filter"
    assert_eq "settings.json" "$(/bin/ls "$HOME/badfilter")" "files after json_merge $filter"
    assert_eq '{"mine": 1}' "$(cat "$settings")" "settings after json_merge $filter"
done
# A good filter still offers the backup, then writes
assert_exit 0 json_merge "$settings" '.a = 1' <<< y
assert_contains "$RUN_OUTPUT" "Back up $settings"
assert_eq '{"mine": 1}' "$(cat "$settings.bak")" "backup after json_merge"
assert_eq 1 "$(jq .a "$settings")" "settings after json_merge"

# json_merge without jq fails before it backs anything up, so a run before the homebrew step leaves
# no backup to offer again
load_script lib/common.sh
hide jq
settings="$HOME/nojq/settings.json"
mkdir -p "$HOME/nojq"
printf '{"mine": 1}\n' > "$settings"
export DOTFILES_BACKUP=yes
assert_exit 1 json_merge "$settings" '.a = 1'
unset DOTFILES_BACKUP
assert_contains "$RUN_OUTPUT" "jq"
assert_eq "settings.json" "$(/bin/ls "$HOME/nojq")" "files after json_merge without jq"
assert_eq '{"mine": 1}' "$(cat "$settings")" "settings after json_merge without jq"
test_done
