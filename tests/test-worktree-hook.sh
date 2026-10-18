#!/bin/bash
set -euo pipefail

# Claude Code's WorktreeCreate, WorktreeRemove, and SessionEnd hook puts worktrees where git wt
# does, honors worktree.baseRef, copies the files .worktreeinclude names, and prints only the path
# on create. The claude-code step registers it once for all three. The fetch is skipped after a
# recent fetch of the same branch and can't hang, a name another worktree has checked out becomes
# worktree-<name>, and a merged branch is deleted however many branches contain it.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
unset CLAUDE_PROJECT_DIR GIT_SSH_COMMAND GIT_SSH
export PATH="$REPO_DIR/git/bin:$PATH"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
hook="$REPO_DIR/ai_tools/claude-code/worktree-hook.sh"

command -v jq &> /dev/null || skip "jq isn't installed"

# create <name> <cwd> [<session>]: run the create hook, keeping its stdout in $out and its status
# in $status
create() {
    status=0
    out="$(printf '{"session_id":"%s","hook_event_name":"WorktreeCreate","name":"%s","cwd":"%s"}' "${3:-s}" "$1" "$2" |
        "${HOOK_BASH:-bash}" "$hook" 2> "$SANDBOX/stderr")" || status=$?
}

# remove <path>: run the remove hook on a worktree path, keeping its status in $status
remove() {
    status=0
    printf '{"session_id":"s","hook_event_name":"WorktreeRemove","worktree_path":"%s","cwd":"/"}' "$1" |
        bash "$hook" > "$SANDBOX/stdout" 2> "$SANDBOX/stderr" || status=$?
}

# An origin, cloned to ~/Dev/x/y, which then gets an unpushed commit while origin gets a new one
git init -q -b main "$SANDBOX/seed"
git -C "$SANDBOX/seed" commit -q --allow-empty -m first
git clone -q --bare "$SANDBOX/seed" "$SANDBOX/origin.git"
git -C "$SANDBOX/seed" remote add origin "$SANDBOX/origin.git"
mkdir -p "$HOME/Dev/x"
git clone -q "$SANDBOX/origin.git" "$HOME/Dev/x/y"
repo="$HOME/Dev/x/y"
git -C "$repo" commit -q --allow-empty -m unpushed
git -C "$SANDBOX/seed" commit -q --allow-empty -m "pushed later"
git -C "$SANDBOX/seed" push -q origin main
fresh="$(git -C "$SANDBOX/seed" rev-parse HEAD)"
dir="$WORKTREES_DIR/x/y"
# What the hook leaves after its own fetch of origin's main succeeds
stamp="$repo/.git/dotfiles-worktree-hook/fetched-main"

# Ignored files the new worktree should get: those .worktreeinclude names and .gitignore ignores
printf '.env\nbuild/\n' > "$repo/.gitignore"
printf '.env\nuntracked.txt\n' > "$repo/.worktreeinclude"
git -C "$repo" add .gitignore .worktreeinclude
git -C "$repo" commit -q -m ignores
echo secret > "$repo/.env"
echo notes > "$repo/untracked.txt"
mkdir -p "$repo/build"
echo out > "$repo/build/out"

# A git, first on the hook's PATH, that logs each fetch with the SSH command it gets
real_git="$(command -v git)"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/git" << EOF
#!/bin/bash
case " \$* " in *" fetch "*) printf '%s\\n' "git \$* | \${GIT_SSH_COMMAND:-}" >> "$SANDBOX/fetch.log" ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$HOME/.local/bin/git"
: > "$SANDBOX/fetch.log"

# The default, fresh: branch from origin's default branch, fetched first, and print only the path
mkdir -p "$HOME/.claude"
echo '{"worktree": {"baseRef": "fresh"}}' > "$HOME/.claude/settings.json"
create feat "$repo"
assert_eq 0 "$status" "create hook's exit status"
assert_eq "$dir/feat" "$out" "create hook's stdout"
assert_eq "feat" "$(git -C "$dir/feat" symbolic-ref --short HEAD)" "branch in the feat worktree"
assert_eq "$fresh" "$(git -C "$dir/feat" rev-parse HEAD)" "feat's base"
assert_eq "secret" "$(cat "$dir/feat/.env" 2> /dev/null)" "the .env copied into feat"
[ ! -e "$dir/feat/untracked.txt" ] || fail "copied untracked.txt, which git doesn't ignore"
[ ! -e "$dir/feat/build" ] || fail "copied build/, which .worktreeinclude doesn't name"

# The fetch can't hang: SSH gives up connecting after 5 s, and HTTP a transfer under 1000 B/s
# for 5 s
assert_file_contains "$SANDBOX/fetch.log" "-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 fetch"
assert_file_contains "$SANDBOX/fetch.log" "-o BatchMode=yes -o ConnectTimeout=5"

# A fetch in the last 10 minutes is recent enough: the next create doesn't fetch again
git -C "$SANDBOX/seed" commit -q --allow-empty -m "pushed after the fetch"
git -C "$SANDBOX/seed" push -q origin main
: > "$SANDBOX/fetch.log"
create recent "$repo"
assert_eq "0 $dir/recent" "$status $out" "create hook after a recent fetch"
assert_eq "" "$(cat "$SANDBOX/fetch.log")" "fetches after a recent one"
assert_eq "$fresh" "$(git -C "$dir/recent" rev-parse HEAD)" "recent's base"
# Only the hook's own fetch of that branch counts. After 10 minutes, or after a recent fetch of
# another branch, origin's main is fetched again.
git -C "$SANDBOX/seed" push -q origin main:refs/heads/side
touch -t 202001010000 "$stamp"
git -C "$repo" fetch -q origin side
: > "$SANDBOX/fetch.log"
create unrelated "$repo"
assert_eq "0 $dir/unrelated" "$status $out" "create hook after an unrelated fetch"
assert_file_contains "$SANDBOX/fetch.log" "fetch --quiet origin main"
assert_eq "$(git -C "$SANDBOX/seed" rev-parse HEAD)" "$(git -C "$dir/unrelated" rev-parse HEAD)" \
    "unrelated's base"
# A fetch that fails warns, and the worktree branches from the local copy
touch -t 202001010000 "$stamp"
git -C "$repo" remote set-url origin "$SANDBOX/missing.git"
create offline "$repo"
assert_eq "0 $dir/offline" "$status $out" "create hook when the fetch fails"
assert_contains "$(cat "$SANDBOX/stderr")" "couldn't fetch origin/main" "create hook's stderr"
git -C "$repo" remote set-url origin "$SANDBOX/origin.git"
# The failed fetch left the stamp as old as it was, so the next create fetches
: > "$SANDBOX/fetch.log"
create retry "$repo"
assert_eq "0 $dir/retry" "$status $out" "create hook after a failed fetch"
assert_file_contains "$SANDBOX/fetch.log" "fetch"
for wt in recent unrelated offline retry; do
    remove "$dir/$wt"
done

# An origin added by hand has no origin/HEAD, but an origin/main: that's what the hook fetches
git -C "$repo" remote set-head origin -d
touch -t 202001010000 "$stamp"
: > "$SANDBOX/fetch.log"
create nohead "$repo"
assert_eq "0 $dir/nohead" "$status $out" "create hook without origin/HEAD"
assert_file_contains "$SANDBOX/fetch.log" "fetch --quiet origin main"
remove "$dir/nohead"
git -C "$repo" remote set-head origin main

# The fetch goes through core.sshCommand, with BatchMode, when GIT_SSH_COMMAND isn't set. The
# stub fails, so the hook branches from the local copy. The sandbox allows only local repos, so
# these fetches allow ssh too; the stub stands in for ssh, and nothing reaches the network.
cat > "$SANDBOX/logssh" << EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SANDBOX/ssh.log"
exit 1
EOF
chmod +x "$SANDBOX/logssh"
git -C "$repo" config core.sshCommand "$SANDBOX/logssh"
git -C "$repo" remote set-url origin example.invalid:origin.git
touch -t 202001010000 "$stamp"
GIT_ALLOW_PROTOCOL=file:ssh create sshcmd "$repo"
assert_eq "0 $dir/sshcmd" "$status $out" "create hook with core.sshCommand"
remove "$dir/sshcmd"
assert_file_contains "$SANDBOX/ssh.log" "-o BatchMode=yes -o ConnectTimeout=5 example.invalid"
git -C "$repo" remote set-url origin "$SANDBOX/origin.git"
git -C "$repo" config --unset core.sshCommand

# GIT_SSH is an executable path, not a shell command. Preserve it, with a space and an apostrophe,
# under the Mac's /bin/bash 3.2, which parses the quoting differently.
mkdir "$SANDBOX/it's"
cp "$SANDBOX/logssh" "$SANDBOX/it's/ssh wrapper"
: > "$SANDBOX/ssh.log"
git -C "$repo" remote set-url origin example.invalid:origin.git
GIT_ALLOW_PROTOCOL=file:ssh GIT_SSH="$SANDBOX/it's/ssh wrapper" HOOK_BASH=/bin/bash create ssh-wrapper "$repo"
assert_eq "0 $dir/ssh-wrapper" "$status $out" "create with GIT_SSH"
assert_file_contains "$SANDBOX/ssh.log" 'BatchMode=yes'
remove "$dir/ssh-wrapper"
git -C "$repo" remote set-url origin "$SANDBOX/origin.git"

# A fetch stalled after connecting gets its deadline in all, 15 s unless shortened as here, then is
# killed with its child process.
cp "$HOME/.local/bin/git" "$SANDBOX/git-before-stall"
cat > "$HOME/.local/bin/git" <<EOF
#!/bin/bash
case " \$* " in
    *" fetch "*)
        (trap '' TERM; exec sleep 40) &
        echo \$! > "$SANDBOX/fetch-child"
        wait
        exit 1 ;;
esac
exec "$real_git" "\$@"
EOF
chmod +x "$HOME/.local/bin/git"
rm -f "$stamp"
started=$SECONDS
WORKTREE_HOOK_FETCH_DEADLINE=2 create stalled "$repo"
elapsed=$((SECONDS - started))
assert_eq "0 $dir/stalled" "$status $out" "create after stalled fetch"
[ "$elapsed" -ge 1 ] && [ "$elapsed" -lt 12 ] || fail "stalled fetch took $elapsed seconds, not 2"
assert_file_contains "$SANDBOX/stderr" "branching from the local copy"
child="$(cat "$SANDBOX/fetch-child")"
# A terminated child can remain briefly as a zombie before init reaps it.
child_state="$(ps -o stat= -p "$child" 2>/dev/null || true)"
case "$child_state" in "" | *Z*) ;; *) fail "stalled fetch left a live child ($child_state)" ;; esac
mv "$SANDBOX/git-before-stall" "$HOME/.local/bin/git"
remove "$dir/stalled"

# Fresh branches from origin's default branch even when origin has a stale branch of that name
git -C "$SANDBOX/seed" push -q origin "$(git -C "$SANDBOX/seed" rev-parse HEAD~2):refs/heads/old-remote"
git -C "$repo" fetch -q origin
create old-remote "$repo"
assert_eq "0 $dir/old-remote" "$status $out" "create hook with a stale origin branch"
assert_eq "$(git -C "$repo" rev-parse origin/main)" "$(git -C "$dir/old-remote" rev-parse HEAD)" \
    "old-remote's base"
remove "$dir/old-remote"

# With hundreds of worktrees, the porcelain listing overflows the pipe; finding main's worktree
# first mustn't kill the listing with SIGPIPE
main_head="$(git -C "$repo" rev-parse HEAD)"
i=0
while [ "$i" -lt 400 ]; do
    reg="$repo/.git/worktrees/many-$i"
    mkdir -p "$reg"
    echo "$SANDBOX/gone/a-long-worktree-directory-name-to-fill-the-pipe-faster-$i/.git" > "$reg/gitdir"
    echo "../.." > "$reg/commondir"
    echo "$main_head" > "$reg/HEAD"
    i=$((i + 1))
done
create main "$repo"
assert_eq "0 $dir/worktree-main" "$status $out" "create hook for main with many worktrees"
remove "$dir/worktree-main"
git -C "$repo" worktree prune

# Under a symlinked worktrees dir, git's resolved path still matches the worktree for the name
real_wt="$WORKTREES_DIR"
mkdir -p "$SANDBOX/wt-real"
export WORKTREES_DIR="$SANDBOX/wt-link"
ln -s "$SANDBOX/wt-real" "$WORKTREES_DIR"
create linked "$repo"
assert_eq "0 $WORKTREES_DIR/x/y/linked" "$status $out" "create hook under a symlinked dir"
create linked "$repo"
assert_eq "0 $WORKTREES_DIR/x/y/linked" "$status $out" "a second create hook under a symlinked dir"
remove "$WORKTREES_DIR/x/y/linked"
export WORKTREES_DIR="$real_wt"

# A name checked out in another worktree, such as main in the repo itself, gets worktree-<name>
# as its branch and directory. Removing it deletes that branch, which the hook created.
create main "$repo"
assert_eq "0 $dir/worktree-main" "$status $out" "create hook for main"
assert_eq "worktree-main" "$(git -C "$dir/worktree-main" symbolic-ref --short HEAD 2> /dev/null)" \
    "branch in the worktree-main worktree"
create main "$repo"
assert_eq "0 $dir/worktree-main" "$status $out" "a second create hook for main"
remove "$dir/worktree-main"
assert_eq 0 "$status" "remove hook's exit status for worktree-main"
[ ! -e "$dir/worktree-main" ] || fail "remove hook left $dir/worktree-main"
git -C "$repo" show-ref --verify --quiet refs/heads/worktree-main && fail "remove hook kept the worktree-main branch"
assert_eq "main" "$(git -C "$repo" symbolic-ref --short HEAD)" "the repo's own branch"

# head in the project's settings wins over the user's fresh: branch from the local HEAD
mkdir -p "$repo/.claude"
echo '{"worktree": {"baseRef": "head"}}' > "$repo/.claude/settings.json"
create local "$repo"
assert_eq "0 $dir/local" "$status $out" "create hook with baseRef head"
assert_eq "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$dir/local" rev-parse HEAD)" "local's base"
rm -r "$repo/.claude"

# Created from inside a worktree, it still lands in the repo's directory
create sub "$dir/feat"
assert_eq "0 $dir/sub" "$status $out" "create hook run from inside a worktree"

# A name git can't use fails creation
create "bad..name" "$repo"
[ "$status" -ne 0 ] || fail "create hook succeeded for a bad name"

# Remove: the worktree, its empty directories, and its branch when it has no new commits
remove "$dir/sub"
assert_eq 0 "$status" "remove hook's exit status"
[ ! -e "$dir/sub" ] || fail "remove hook left $dir/sub"
git -C "$repo" show-ref --verify --quiet refs/heads/sub && fail "remove hook kept the sub branch"
assert_eq "" "$(cat "$SANDBOX/stdout")" "remove hook's stdout"

# A worktree with uncommitted changes and a commit: Claude Code asked first, so it goes, but the
# branch stays
echo change > "$dir/local/file"
git -C "$dir/local" add file
git -C "$dir/local" commit -q -m work
echo dirty > "$dir/local/file"
remove "$dir/local"
assert_eq 0 "$status" "remove hook's exit status for a dirty worktree"
[ ! -e "$dir/local" ] || fail "remove hook left the dirty $dir/local"
git -C "$repo" show-ref --verify --quiet refs/heads/local || fail "remove hook deleted the local branch, which has a commit"
assert_contains "$(cat "$SANDBOX/stderr")" "kept branch local" "remove hook's stderr for a branch with a commit"

remove "$dir/feat"
[ ! -e "$WORKTREES_DIR/x" ] || fail "remove hook left $WORKTREES_DIR/x"
[ -d "$WORKTREES_DIR" ] || fail "remove hook removed $WORKTREES_DIR"

# A worktree already gone counts as removed
remove "$dir/gone"
assert_eq 0 "$status" "remove hook's exit status for a missing worktree"

# A branch that existed before the worktree, such as a pushed one, survives its removal
git -C "$repo" branch my-feature
git -C "$repo" push -q origin my-feature
create my-feature "$repo"
assert_eq "0 $dir/my-feature" "$status $out" "create hook on an existing branch"
remove "$dir/my-feature"
assert_eq 0 "$status" "remove hook's exit status for an existing branch"
[ ! -e "$dir/my-feature" ] || fail "remove hook left $dir/my-feature"
git -C "$repo" show-ref --verify --quiet refs/heads/my-feature ||
    fail "remove hook deleted my-feature, which existed before the worktree"

# What .worktreeinclude names is copied: patterns that match below the top, such as a .env in a
# tracked subdir, name a directory, or negate. An ignored dir the include names is copied whole,
# symlinks kept. Nothing inside an ignored dir it doesn't name is copied, even what a pattern that
# matches at any depth names: config/a.json for config/*.json, the .pem in certs/, and the .env in
# node_modules/ and in sub/node_modules/, which git lists as sub/. A symlink is copied as a link,
# even a broken one. A file that can't be copied, such as an unreadable one, gets a warning, and
# the worktree is still created and its path printed.
mkdir -p "$repo/apps/web" "$repo/.cache/a" "$repo/config" "$repo/node_modules/pkg" "$repo/vendor/lib" \
    "$repo/certs/dev" "$repo/sub/node_modules/x"
touch "$repo/apps/web/index.js"
printf '.env*\n.cache/\nconfig/\n*.local\nnode_modules/\nvendor/\ncerts/\n' >> "$repo/.gitignore"
printf '.env*\n.cache/\nconfig/*.json\n*.local\n!keep.local\nvendor\n*.pem\n' >> "$repo/.worktreeinclude"
git -C "$repo" add .gitignore .worktreeinclude apps/web/index.js
git -C "$repo" commit -q -m "more includes"
ln -s "$SANDBOX/missing" "$repo/.env.local"
echo unreadable > "$repo/.env.unreadable"
chmod 000 "$repo/.env.unreadable"
echo web > "$repo/apps/web/.env"
echo cached > "$repo/.cache/a/b"
echo a > "$repo/config/a.json"
echo l > "$repo/a.local"
echo k > "$repo/keep.local"
echo n > "$repo/node_modules/pkg/.env"
echo n > "$repo/sub/node_modules/x/.env"
echo v > "$repo/vendor/lib/v.js"
ln -s v.js "$repo/vendor/lib/link.js"
echo c > "$repo/certs/dev/dev.pem"
create pat "$repo"
assert_eq "0 $dir/pat" "$status $out" "create hook with nested, directory, and negated patterns"
assert_eq "$SANDBOX/missing" "$(readlink "$dir/pat/.env.local")" "the broken symlink copied"
# root reads the file anyway
[ -r "$repo/.env.unreadable" ] ||
    assert_contains "$(cat "$SANDBOX/stderr")" ".env.unreadable" "create hook's stderr with an unreadable file to copy"
assert_eq "secret" "$(cat "$dir/pat/.env" 2> /dev/null)" "the .env copied"
assert_eq "web" "$(cat "$dir/pat/apps/web/.env" 2> /dev/null)" "the nested .env copied"
assert_eq "cached" "$(cat "$dir/pat/.cache/a/b" 2> /dev/null)" "the .cache dir copied"
assert_eq "l" "$(cat "$dir/pat/a.local" 2> /dev/null)" "a.local copied"
assert_eq "v" "$(cat "$dir/pat/vendor/lib/v.js" 2> /dev/null)" "vendor copied"
assert_eq "v.js" "$(readlink "$dir/pat/vendor/lib/link.js")" "the symlink in vendor kept"
for skipped in config keep.local certs node_modules sub; do
    [ ! -e "$dir/pat/$skipped" ] || fail "copied $skipped, which .worktreeinclude leaves out"
done
remove "$dir/pat"
rm -rf "$repo/.env.local" "$repo/.env.unreadable" "$repo/node_modules" "$repo/vendor" "$repo/certs" "$repo/sub"

# A branch that tracks apps as a symlink to a dir outside the worktree gets nothing copied
# through it, even though the checkout's ignored apps/web/.env matches the include
mkdir -p "$SANDBOX/outside"
git -C "$repo" worktree add -q -b linkapps "$SANDBOX/linkapps"
rm -rf "$SANDBOX/linkapps/apps"
ln -s "$SANDBOX/outside" "$SANDBOX/linkapps/apps"
git -C "$SANDBOX/linkapps" add -A apps
git -C "$SANDBOX/linkapps" commit -q -m "apps as a symlink"
git -C "$repo" worktree remove "$SANDBOX/linkapps"
create linkapps "$repo"
assert_eq "0 $dir/linkapps" "$status $out" "create hook with a symlinked apps"
assert_eq "" "$(ls -A "$SANDBOX/outside")" "files copied through the apps symlink"
assert_contains "$(cat "$SANDBOX/stderr")" \
    "worktree-hook: skipped apps/web/.env: apps is a symlink in the worktree" "create hook's stderr"
remove "$dir/linkapps"

# A merged branch is deleted even when thousands of other branches contain it, so the list of
# them, over 100 KB, overflows the pipe
create big "$repo"
assert_eq "0 $dir/big" "$status $out" "create hook for big"
big_commit="$(git -C "$dir/big" rev-parse HEAD)"
i=0
while [ "$i" -lt 2000 ]; do
    echo "create refs/heads/many/a-long-branch-name-to-fill-the-pipe-faster-$i $big_commit"
    i=$((i + 1))
done | git -C "$repo" update-ref --stdin
remove "$dir/big"
assert_eq 0 "$status" "remove hook's exit status for big"
git -C "$repo" show-ref --verify --quiet refs/heads/big && fail "remove hook kept the merged big branch"
git -C "$repo" for-each-ref --format='delete %(refname)' refs/heads/many | git -C "$repo" update-ref --stdin

# Removal also works when the common Git directory isn't <checkout>/.git.
mkdir -p "$SANDBOX/storage"
git init -q -b main --separate-git-dir "$SANDBOX/storage/separate.git" "$SANDBOX/separate"
git -C "$SANDBOX/separate" commit -q --allow-empty -m initial
git -C "$repo" -c protocol.file.allow=always submodule add -q "$SANDBOX/seed" module
for checkout in "$SANDBOX/separate" "$repo/module"; do
    mkdir -p "$checkout/.claude"
    printf '{"worktree":{"baseRef":"head"}}\n' > "$checkout/.claude/settings.json"
    create extra "$checkout"
    assert_eq 0 "$status" "create hook with separate Git directory"
    extra="$out"
    remove "$extra"
    assert_eq 0 "$status" "remove hook with separate Git directory"
    [ ! -d "$extra" ] || fail "remove hook left $extra"
done

# At SessionEnd, the session's worktrees that hold nothing to lose go, with their branches,
# including the files the create hook copied from .worktreeinclude while they match the repo's.
# One with changes, a changed copy, or a commit no other branch has stays, as do another
# session's and one the hook didn't make. They branch from HEAD, whose .gitignore ignores the
# copies.
end_session() {
    status=0
    printf '{"session_id":"%s","hook_event_name":"SessionEnd","reason":"other","cwd":"%s"}' "$1" "$2" |
        bash "$hook" > "$SANDBOX/stdout" 2> "$SANDBOX/stderr" || status=$?
}
mkdir -p "$repo/.claude"
echo '{"worktree": {"baseRef": "head"}}' > "$repo/.claude/settings.local.json"
for name in e-clean e-changed e-copy e-committed; do
    create "$name" "$repo" s1
    assert_eq "0 $dir/$name" "$status $out" "create hook for $name"
done
assert_eq s1 "$(cat "$(git -C "$dir/e-clean" rev-parse --absolute-git-dir)/worktree-hook-session")" \
    "the session the create hook records"
create e-other "$repo" s2
git -C "$repo" wt add e-unmarked > /dev/null 2>&1
[ -f "$dir/e-clean/.env" ] || fail "the create hook copied no .env into e-clean"
echo change > "$dir/e-changed/file"
echo changed > "$dir/e-copy/.env"
git -C "$dir/e-committed" commit -q --allow-empty -m mine
end_session s1 "$repo"
assert_eq "0" "$status" "SessionEnd hook's exit status"
assert_eq "" "$(cat "$SANDBOX/stdout")" "SessionEnd hook's stdout"
[ ! -e "$dir/e-clean" ] || fail "SessionEnd hook kept e-clean"
git -C "$repo" show-ref --verify --quiet refs/heads/e-clean && fail "SessionEnd hook kept branch e-clean"
for name in e-changed e-copy e-committed e-other e-unmarked; do
    [ -d "$dir/$name" ] || fail "SessionEnd hook removed $name"
done
# A cwd outside a repo, or with no git wt, removes nothing and still exits 0
end_session s2 "$SANDBOX"
assert_eq "0" "$status" "SessionEnd hook's exit status outside a repo"
printf '{"session_id":"s2","hook_event_name":"SessionEnd","cwd":"%s"}' "$repo" |
    env PATH=/usr/bin:/bin bash "$hook" > /dev/null 2>&1 || fail "SessionEnd hook without git wt failed"
[ -d "$dir/e-other" ] || fail "SessionEnd hook removed e-other without git wt"
for name in e-changed e-copy e-committed e-other e-unmarked; do
    git -C "$repo" wt rm -f "$name" 2> /dev/null
done
# A .env that's a symlink in the checkout is copied as one, so the worktree still counts as clean
mv "$repo/.env" "$repo/env-a"
ln -s env-a "$repo/.env"
create e-link "$repo" s3
assert_eq "env-a" "$(readlink "$dir/e-link/.env")" "the .env symlink copied into e-link"
end_session s3 "$repo"
[ ! -e "$dir/e-link" ] || fail "SessionEnd hook kept e-link, whose .env is the checkout's symlink"
rm "$repo/.env"
mv "$repo/env-a" "$repo/.env"
rm -r "$repo/.claude"

# The claude-code step registers the hook for the three events, once, keeps hooks for other
# events, and reports the script. It needs git wt, which the git step installs to ~/.local/bin.
# test-claude-settings.sh covers another command already in a worktree event.
load_script ai_tools/claude-code/install.sh
stub claude 'echo "{\"loggedIn\": true}"'
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO_DIR/git/bin/git-wt" "$HOME/.local/bin/git-wt"
settings="$HOME/.claude/settings.json"
echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other"}]}]}}' > "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '{"SessionEnd":1,"Stop":1,"WorktreeCreate":1,"WorktreeRemove":1}' \
    "$(jq -cS '.hooks | map_values([.[].hooks[]] | length)' "$settings")" "hooks per event"
assert_eq '["other"]' "$(jq -c '[.hooks.Stop[].hooks[].command]' "$settings")" "Stop hooks"
json_applied "$settings" "$(claude_code_settings)" || fail "settings not applied after json_merge"
# A timeout you set goes back to the step's, since a short one kills the hook mid-fetch (#37)
jq '.hooks.WorktreeRemove[0].hooks[0].timeout = 30' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
json_merge "$settings" "$(claude_code_settings)" > /dev/null
assert_eq '[120]' "$(jq -c '[.hooks.WorktreeRemove[].hooks[].timeout]' "$settings")" \
    "a WorktreeRemove timeout you set"
run status
assert_contains "$RUN_OUTPUT" "worktree-hook.sh"

# A hook copy that isn't executable, as after a failed copy: the step removes the registration
# an earlier run made, since Claude Code would fail to create worktrees, keeps other hooks, and fails
failures="$TEST_FAILURES"
(
    # shellcheck disable=SC2329 # main calls them
    install_claude_code() { :; }
    # shellcheck disable=SC2329
    install_scripts() {
        mkdir -p "$(dirname "$CLAUDE_CODE_WORKTREE_HOOK")" && : > "$CLAUDE_CODE_WORKTREE_HOOK"
        chmod 644 "$CLAUDE_CODE_WORKTREE_HOOK"
        return 1
    }
    assert_exit 1 main
    assert_eq "null null null" \
        "$(jq -r '"\(.hooks.WorktreeCreate) \(.hooks.WorktreeRemove) \(.hooks.SessionEnd)"' "$settings")" \
        "worktree hooks with a hook copy that isn't executable"
    assert_eq '["other"]' "$(jq -c '[.hooks.Stop[].hooks[].command]' "$settings")" "Stop hooks"
    [ "$TEST_FAILURES" -eq "$failures" ]
) || fail "removing the worktree hook's registration"
rm -f "$CLAUDE_CODE_WORKTREE_HOOK"

# Without git wt the step removes the hook's registrations, keeping other hooks, says to run the
# git step, and fails after doing the rest; status reports the hook as missing
install_claude_code() { :; }
echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other"}]}]}}' > "$settings"
assert_exit 0 main
assert_eq '["SessionEnd","Stop","WorktreeCreate","WorktreeRemove"]' "$(jq -c '.hooks | keys' "$settings")" \
    "hooks registered with git wt"
rm "$HOME/.local/bin/git-wt"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "bash setup.sh git"
assert_eq '["Stop"]' "$(jq -c '.hooks | keys' "$settings")" "hooks left after git wt went"
echo '{}' > "$settings"
assert_exit 1 main
assert_eq "null" "$(jq -c '.hooks' "$settings")" "hooks registered without git wt"
assert_eq "claude-opus-5-5" "$(jq -r '.model' "$settings")" "model set without git wt"
[ -x "$CLAUDE_CODE_WORKTREE_HOOK" ] || fail "the hook script wasn't copied without git wt"
run status
assert_contains "$RUN_OUTPUT" "missing    Worktree hook"
assert_eq 3 "$RUN_STATUS" "status exit without git wt"
test_done
