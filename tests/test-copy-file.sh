#!/bin/bash
set -euo pipefail

# copy_file replaces a file that differs from the repo's, edited or not, with no backup or
# question, and leaves one that matches alone. status_file reports a file that differs as missing.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

src="$SANDBOX/repo/config.yml"
# A path with spaces, like lazygit's config on macOS
dest="$HOME/Library/Application Support/tool/config.yml"
mkdir -p "$SANDBOX/repo"

# Act as if stdin were a terminal, answered from the test's stdin. read -p prints no question
# without a terminal, so confirm prints it. load_script lib/common.sh puts the real ones back.
# shellcheck disable=SC2329 # maybe_backup calls them
fake_terminal() {
    is_interactive() { true; }
    confirm() {
        local reply
        echo "$1"
        read -r reply
        [ "$reply" == y ]
    }
}

# First install: copied, and a second run leaves it
printf 'hello\n' > "$src"
assert_exit 0 copy_file "$src" "$dest"
assert_contains "$RUN_OUTPUT" "Copied"
assert_eq "hello" "$(cat "$dest")" "installed file"
assert_exit 0 copy_file "$src" "$dest"
assert_eq "  $dest is already up to date" "$RUN_OUTPUT" "second copy"

# A repo update or a hand edit is replaced, with no question or backup, even with a terminal and
# --backup, which only answers the settings merges' questions. No install record is kept.
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
    assert_contains "$RUN_OUTPUT" "Copied" "copy after a $change change"
    assert_not_contains "$RUN_OUTPUT" "?" "copy after a $change change"
    assert_eq "hello2" "$(cat "$dest")" "file after a $change change"
    assert_eq "config.yml" "$(/bin/ls -A "$(dirname "$dest")")" "files after a $change change"
done
assert_eq "" "$(/bin/ls -A "$HOME/.local/state/dotfiles" 2>/dev/null)" "state files after copies"
load_script lib/common.sh

# status_file: ok when it matches, and missing when it differs or is gone, without writing
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

# The AI tools' user instructions, which may hold edits made by hand, are replaced the same way
load_script ai_tools/lib/user-instructions.sh
instructions="$HOME/.codex/AGENTS.md"
mkdir -p "$HOME/.codex"
printf 'my own instructions\n' > "$instructions"
assert_exit 0 install_user_instructions "$instructions"
assert_eq "" "$(cmp "$REPO_DIR/ai_tools/user-instructions.md" "$instructions" 2>&1)" "user instructions after an edit"
assert_eq "AGENTS.md" "$(/bin/ls -A "$HOME/.codex")" "files beside the user instructions"

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

# A backup that fails leaves the file as it is and fails, saying nothing was backed up: here the
# .bak holds another file, and the file's directory is read-only, so no new backup can be made
load_script lib/common.sh
edited="$HOME/ro/edited.yml"
mkdir -p "$HOME/ro"
printf 'repo\n' > "$SANDBOX/repo/edited.yml"
# JSON, so json_merge's jq succeeds and, since the filter changes it, goes on to back it up
printf '"my edit"\n' > "$edited"
printf 'older\n' > "$edited.bak"
chmod 555 "$HOME/ro"
export DOTFILES_BACKUP=yes
assert_exit 1 json_merge "$edited" '"merged"'
unset DOTFILES_BACKUP
assert_eq '"my edit"' "$(cat "$edited")" "file after a failed backup"
assert_not_contains "$RUN_OUTPUT" "Backed up"
assert_contains "$RUN_OUTPUT" "Couldn't back up $edited"
chmod 755 "$HOME/ro"

# A copy into a read-only directory fails, even when called under ||, which turns set -e off: no
# "Copied"
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
chmod 755 "$ro"

# A copied file made read-only is left as it is, as cp would leave it, though its directory
# would let a rename replace it. So is one a symlink points to.
if [ "$(id -u)" -ne 0 ]; then
    locked="$HOME/locked/config.yml"
    printf 'old\n' > "$SANDBOX/repo/locked.yml"
    assert_exit 0 copy_file "$SANDBOX/repo/locked.yml" "$locked"
    chmod 444 "$locked"
    ln -s config.yml "$HOME/locked/link.yml"
    printf 'new\n' > "$SANDBOX/repo/locked.yml"
    for name in config.yml link.yml; do
        assert_exit 1 copy_file "$SANDBOX/repo/locked.yml" "$HOME/locked/$name"
        assert_contains "$RUN_OUTPUT" "$HOME/locked/$name is read-only, so left it unchanged."
        assert_not_contains "$RUN_OUTPUT" "Copied"
        assert_eq old "$(cat "$locked")" "read-only file after copying to $name"
    done
    chmod 644 "$locked"
fi

# A copy goes to a temp file beside the destination, then moves into place, so a copy that fails
# partway leaves the old file whole, and a script running from the old file reads on unchanged.
# Here cp writes part of the file, then fails.
load_script lib/common.sh
atomic="$HOME/atomic/config.yml"
printf 'old\n' > "$SANDBOX/repo/atomic.yml"
assert_exit 0 copy_file "$SANDBOX/repo/atomic.yml" "$atomic"
printf 'new\n' > "$SANDBOX/repo/atomic.yml"
stub cp 'for last; do :; done; printf part > "$last"; exit 1'
assert_exit 1 copy_file "$SANDBOX/repo/atomic.yml" "$atomic"
rm -f "$STUB_DIR/cp"
assert_eq old "$(cat "$atomic")" "file after a copy that failed partway"
assert_eq config.yml "$(/bin/ls -A "$HOME/atomic")" "files beside it after a copy that failed partway"
assert_not_contains "$RUN_OUTPUT" "Copied"
inode="$(/bin/ls -i "$atomic" | awk '{print $1}')"
assert_exit 0 copy_file "$SANDBOX/repo/atomic.yml" "$atomic"
assert_eq new "$(cat "$atomic")" "file after a copy"
[ "$inode" != "$(/bin/ls -i "$atomic" | awk '{print $1}')" ] || fail "copy_file wrote through the file instead of moving a new one into place"

# A symlink stays a link, and its target is replaced, keeping its mode
mkdir -p "$HOME/real"
printf 'old\n' > "$HOME/real/linked.yml"
chmod 640 "$HOME/real/linked.yml"
ln -s "$HOME/real/linked.yml" "$HOME/linked.yml"
assert_exit 0 copy_file "$SANDBOX/repo/atomic.yml" "$HOME/linked.yml"
[ -L "$HOME/linked.yml" ] || fail "copy_file replaced the symlink"
assert_eq new "$(cat "$HOME/real/linked.yml")" "symlink target after copy_file"
assert_eq 640 "$(file_mode "$HOME/real/linked.yml")" "symlink target's mode after copy_file"
assert_eq linked.yml "$(/bin/ls -A "$HOME/real")" "files beside the symlink target after copy_file"

# A new file gets 644, or 755 when the source is executable, whatever the umask. An existing file
# keeps its mode, and gets back an executable bit it lost, which copy_file doesn't take for up to
# date.
(
    umask 077
    copy_file "$SANDBOX/repo/atomic.yml" "$HOME/modes/plain" > /dev/null
    copy_file "$SANDBOX/repo/cmd" "$HOME/modes/cmd" > /dev/null
)
assert_eq 644 "$(file_mode "$HOME/modes/plain")" "mode of a new file"
assert_eq 755 "$(file_mode "$HOME/modes/cmd")" "mode of a new executable"
chmod 600 "$HOME/modes/plain"
printf 'newer\n' > "$SANDBOX/repo/atomic.yml"
assert_exit 0 copy_file "$SANDBOX/repo/atomic.yml" "$HOME/modes/plain"
assert_eq 600 "$(file_mode "$HOME/modes/plain")" "mode of a replaced file"
chmod 644 "$HOME/modes/cmd"
assert_exit 0 copy_file "$SANDBOX/repo/cmd" "$HOME/modes/cmd"
assert_contains "$RUN_OUTPUT" "Copied"
assert_eq 755 "$(file_mode "$HOME/modes/cmd")" "mode of an executable that lost its bit"
assert_eq "" "$(find "$HOME/modes" -name '*.bak*')" "backups of an executable that lost its bit"

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
run backup_file "$f"
assert_eq "  $f is already backed up to $f.bak.20260101-000000-2" "$RUN_OUTPUT" "backup of a version already backed up"
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
# A file that holds several JSON values isn't configured, even when the last one is, and
# json_merge leaves it as it is, as it does invalid JSON
# Each is "<file contents>|<what json_merge says>". Invalid JSON keeps jq's parse error, which
# says where the file goes wrong.
for case in '{"a": 0}
{"a": 1}|holds 2 JSON values, not one, so it was left as it is.' \
    '{"a": 1,}|jq: parse error' '{"a": 1,}|isn'"'"'t valid JSON, so it was left as it is.'; do
    bad="${case%|*}"
    printf '%s\n' "$bad" > "$settings"
    ! json_applied "$settings" '.a = 1' || fail "json_applied passed $bad"
    assert_exit 1 json_merge "$settings" '.a = 1' <<< y
    assert_contains "$RUN_OUTPUT" "${case##*|}" "json_merge on $bad"
    assert_not_contains "$RUN_OUTPUT" "Back up" "json_merge on $bad"
    assert_eq "$bad" "$(cat "$settings")" "settings after json_merge on $bad"
done
printf '{"mine": 1}\n' > "$settings"
# A good filter still offers the backup, then writes
assert_exit 0 json_merge "$settings" '.a = 1' <<< y
assert_contains "$RUN_OUTPUT" "Back up $settings"
assert_eq '{"mine": 1}' "$(cat "$settings.bak")" "backup after json_merge"
assert_eq 1 "$(jq .a "$settings")" "settings after json_merge"
# A filter whose last line is a comment is still checked as a whole: the comparison json_applied
# adds goes on a line of its own
assert_exit 0 json_applied "$settings" '.a = 1
# a comment on the last line'
assert_exit 1 json_applied "$settings" '.a = 2
# a comment on the last line'
# A filter that changes nothing leaves the file as it is, and asks nothing
printf '{"a":1,  "mine":1}\n' > "$settings"
assert_exit 0 json_merge "$settings" '.a = 1' <<< y
assert_not_contains "$RUN_OUTPUT" "Back up" "json_merge with nothing to change"
assert_eq '{"a":1,  "mine":1}' "$(cat "$settings")" "settings after json_merge with nothing to change"

# COPIED turns true only when a copy happens, so a caller that resets it knows whether to reload
printf 'copied\n' > "$SANDBOX/repo/copied.yml"
for want in true false; do
    COPIED=false
    copy_file "$SANDBOX/repo/copied.yml" "$HOME/copied.yml" > /dev/null
    assert_eq "$want" "$COPIED" "COPIED after copy_file"
done

# A question without {} gets the backup's path appended, once
plain="$HOME/plain-question.yml"
printf 'mine\n' > "$plain"
assert_exit 0 maybe_backup "$plain" no "Keep a copy?" <<< y
assert_eq "Keep a copy? ($plain.bak)
  Backed up $plain to $plain.bak" "$RUN_OUTPUT" "maybe_backup with a question without {}"
test_done
