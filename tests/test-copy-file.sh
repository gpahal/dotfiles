#!/bin/bash
set -euo pipefail

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
assert_contains "$RUN_OUTPUT" "Copied"
assert_eq "hello" "$(cat "$dest")" "installed file"
assert_exit 0 copy_file "$src" "$dest"
assert_eq "  $dest is already up to date" "$RUN_OUTPUT" "second copy"

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
    assert_contains "$RUN_OUTPUT" "Copied" "copy after a $change change"
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

load_script ai_tools/lib/user-instructions.sh
instructions="$HOME/.codex/AGENTS.md"
mkdir -p "$HOME/.codex"
printf 'my own instructions\n' > "$instructions"
assert_exit 0 install_user_instructions "$instructions"
assert_eq "" "$(cmp "$REPO_DIR/ai_tools/user-instructions.md" "$instructions" 2>&1)" "user instructions after an edit"
assert_eq "AGENTS.md" "$(/bin/ls -A "$HOME/.codex")" "files beside the user instructions"

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

# A failed backup: the .bak is taken and the dir is read-only
load_script lib/common.sh
edited="$HOME/ro/edited.yml"
mkdir -p "$HOME/ro"
printf 'repo\n' > "$SANDBOX/repo/edited.yml"
# JSON, so json_merge's jq succeeds and goes on to back it up
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

# Under ||, where set -e is off
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

# test-write-back.sh covers the shared replacement cases
if [ "$(id -u)" -ne 0 ]; then
    chmod 444 "$dest"
    printf 'changed\n' > "$src"
    assert_exit 1 copy_file "$src" "$dest"
    assert_contains "$RUN_OUTPUT" "$dest is read-only, so left it unchanged."
    assert_not_contains "$RUN_OUTPUT" "Copied"
    assert_eq hello2 "$(cat "$dest")" "read-only copy"
    chmod 644 "$dest"
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
assert_contains "$RUN_OUTPUT" "Copied"
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
run backup_file "$f"
assert_eq "  $f is already backed up to $f.bak.20260101-000000-2" "$RUN_OUTPUT" "backup of a version already backed up"
echo v4 > "$f"
backup_file "$f" "$f.bak" > /dev/null
assert_eq "v0" "$(cat "$f.bak")" "the .bak after backing up to it by name"
assert_eq "v4" "$(cat "$f.bak.20260101-000000-4")" "backup given a taken name"
unset -f date

# A failing or multi-value filter makes no backup, since jq runs before maybe_backup
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
# Each case is "<file contents>|<what json_merge says>"
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
assert_exit 0 json_merge "$settings" '.a = 1' <<< y
assert_contains "$RUN_OUTPUT" "Back up $settings"
assert_eq '{"mine": 1}' "$(cat "$settings.bak")" "backup after json_merge"
assert_eq 1 "$(jq .a "$settings")" "settings after json_merge"
# json_applied puts its comparison on its own line, after a trailing comment
assert_exit 0 json_applied "$settings" '.a = 1
# a comment on the last line'
assert_exit 1 json_applied "$settings" '.a = 2
# a comment on the last line'
printf '{"a":1,  "mine":1}\n' > "$settings"
assert_exit 0 json_merge "$settings" '.a = 1' <<< y
assert_not_contains "$RUN_OUTPUT" "Back up" "json_merge with nothing to change"
assert_eq '{"a":1,  "mine":1}' "$(cat "$settings")" "settings after json_merge with nothing to change"

printf 'copied\n' > "$SANDBOX/repo/copied.yml"
for want in true false; do
    COPIED=false
    copy_file "$SANDBOX/repo/copied.yml" "$HOME/copied.yml" > /dev/null
    assert_eq "$want" "$COPIED" "COPIED after copy_file"
done

test_done
