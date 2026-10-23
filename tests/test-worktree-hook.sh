#!/bin/bash
set -euo pipefail
# serial

# Claude Code's worktree hook, run against local repos: WorktreeCreate's base, fetch, and copies,
# and what WorktreeRemove and SessionEnd remove or keep. test-claude-settings.sh covers its
# registration.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
unset CLAUDE_PROJECT_DIR GIT_SSH_COMMAND GIT_SSH
export PATH="$REPO_DIR/git/bin:$PATH"
hook="$REPO_DIR/ai_tools/claude-code/worktree-hook.sh"

command -v jq &> /dev/null || skip "jq isn't installed"

# create <name> <cwd> [<session>]: sets $out and $status
create() {
    status=0
    out="$(printf '{"session_id":"%s","hook_event_name":"WorktreeCreate","name":"%s","cwd":"%s"}' "${3:-s}" "$1" "$2" |
        "${HOOK_BASH:-bash}" "$hook" 2> "$SANDBOX/stderr")" || status=$?
}

remove() {
    status=0
    printf '{"session_id":"s","hook_event_name":"WorktreeRemove","worktree_path":"%s","cwd":"/"}' "$1" |
        bash "$hook" > "$SANDBOX/stdout" 2> "$SANDBOX/stderr" || status=$?
}

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
stamp="$repo/.git/dotfiles-worktree-hook/fetched-main"

printf '.env\nbuild/\n' > "$repo/.gitignore"
printf '.env\nuntracked.txt\n' > "$repo/.worktreeinclude"
git -C "$repo" add .gitignore .worktreeinclude
git -C "$repo" commit -q -m ignores
echo secret > "$repo/.env"
echo notes > "$repo/untracked.txt"
mkdir -p "$repo/build"
echo out > "$repo/build/out"

real_git="$(command -v git)"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/git" << EOF
#!/bin/bash
case " \$* " in *" fetch "*) printf '%s\\n' "git \$* | \${GIT_SSH_COMMAND:-}" >> "$SANDBOX/fetch.log" ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$HOME/.local/bin/git"
: > "$SANDBOX/fetch.log"

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

assert_file_contains "$SANDBOX/fetch.log" "-o BatchMode=yes -o ConnectTimeout=5"

git -C "$SANDBOX/seed" commit -q --allow-empty -m "pushed after the fetch"
git -C "$SANDBOX/seed" push -q origin main
: > "$SANDBOX/fetch.log"
create recent "$repo"
assert_eq "0 $dir/recent" "$status $out" "create hook after a recent fetch"
assert_eq "" "$(cat "$SANDBOX/fetch.log")" "fetches after a recent one"
assert_eq "$fresh" "$(git -C "$dir/recent" rev-parse HEAD)" "recent's base"
# Only the hook's own fetch of that branch counts as recent
git -C "$SANDBOX/seed" push -q origin main:refs/heads/side
touch -t 202001010000 "$stamp"
git -C "$repo" fetch -q origin side
: > "$SANDBOX/fetch.log"
create unrelated "$repo"
assert_eq "0 $dir/unrelated" "$status $out" "create hook after an unrelated fetch"
assert_file_contains "$SANDBOX/fetch.log" "fetch --quiet origin main"
assert_eq "$(git -C "$SANDBOX/seed" rev-parse HEAD)" "$(git -C "$dir/unrelated" rev-parse HEAD)" \
    "unrelated's base"
touch -t 202001010000 "$stamp"
git -C "$repo" remote set-url origin "$SANDBOX/missing.git"
create offline "$repo"
assert_eq "0 $dir/offline" "$status $out" "create hook when the fetch fails"
assert_contains "$(cat "$SANDBOX/stderr")" "couldn't fetch origin/main" "create hook's stderr"
git -C "$repo" remote set-url origin "$SANDBOX/origin.git"
: > "$SANDBOX/fetch.log"
create retry "$repo"
assert_eq "0 $dir/retry" "$status $out" "create hook after a failed fetch"
assert_file_contains "$SANDBOX/fetch.log" "fetch"
for wt in recent unrelated offline retry; do
    remove "$dir/$wt"
done

# The sandbox allows only local repos, so allow ssh; the stub stands in for ssh
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

# GIT_SSH is a path, not a command; bash 3.2 parses the quoting differently
mkdir "$SANDBOX/it's"
cp "$SANDBOX/logssh" "$SANDBOX/it's/ssh wrapper"
: > "$SANDBOX/ssh.log"
git -C "$repo" remote set-url origin example.invalid:origin.git
GIT_ALLOW_PROTOCOL=file:ssh GIT_SSH="$SANDBOX/it's/ssh wrapper" HOOK_BASH=/bin/bash create ssh-wrapper "$repo"
assert_eq "0 $dir/ssh-wrapper" "$status $out" "create with GIT_SSH"
assert_file_contains "$SANDBOX/ssh.log" 'BatchMode=yes'
remove "$dir/ssh-wrapper"
git -C "$repo" remote set-url origin "$SANDBOX/origin.git"

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
WORKTREE_HOOK_FETCH_DEADLINE=1 create stalled "$repo"
elapsed=$((SECONDS - started))
assert_eq "0 $dir/stalled" "$status $out" "create after stalled fetch"
[ "$elapsed" -ge 1 ] && [ "$elapsed" -lt 12 ] || fail "stalled fetch took $elapsed seconds, not 1"
assert_file_contains "$SANDBOX/stderr" "branching from the local copy"
child="$(cat "$SANDBOX/fetch-child")"
child_state="$(ps -o stat= -p "$child" 2>/dev/null || true)"
case "$child_state" in "" | *Z*) ;; *) fail "stalled fetch left a live child ($child_state)" ;; esac
mv "$SANDBOX/git-before-stall" "$HOME/.local/bin/git"
remove "$dir/stalled"

git -C "$SANDBOX/seed" push -q origin "$(git -C "$SANDBOX/seed" rev-parse HEAD~2):refs/heads/old-remote"
git -C "$repo" fetch -q origin
create old-remote "$repo"
assert_eq "0 $dir/old-remote" "$status $out" "create hook with a stale origin branch"
assert_eq "$(git -C "$repo" rev-parse origin/main)" "$(git -C "$dir/old-remote" rev-parse HEAD)" \
    "old-remote's base"
remove "$dir/old-remote"

# Enough worktrees to overflow the pipe, which mustn't SIGPIPE the listing
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

mkdir -p "$repo/.claude"
echo '{"worktree": {"baseRef": "head"}}' > "$repo/.claude/settings.json"
create local "$repo"
assert_eq "0 $dir/local" "$status $out" "create hook with baseRef head"
assert_eq "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$dir/local" rev-parse HEAD)" "local's base"
rm -r "$repo/.claude"

# Claude Code asked before removing a dirty worktree
echo change > "$dir/local/file"
git -C "$dir/local" add file
git -C "$dir/local" commit -q -m work
echo dirty > "$dir/local/file"
remove "$dir/local"
assert_eq 0 "$status" "remove hook's exit status for a dirty worktree"
[ ! -e "$dir/local" ] || fail "remove hook left the dirty $dir/local"
git -C "$repo" show-ref --verify --quiet refs/heads/local || fail "remove hook deleted the local branch, which has a commit"

remove "$dir/gone"
assert_eq 0 "$status" "remove hook's exit status for a missing worktree"

git -C "$repo" branch my-feature
git -C "$repo" push -q origin my-feature
# git wt add ignores the base for an existing branch, so there's nothing to fetch
touch -t 202001010000 "$stamp"
: > "$SANDBOX/fetch.log"
create my-feature "$repo"
assert_eq "0 $dir/my-feature" "$status $out" "create hook on an existing branch"
assert_eq "" "$(cat "$SANDBOX/fetch.log")" "fetches for an existing branch"
remove "$dir/my-feature"
assert_eq 0 "$status" "remove hook's exit status for an existing branch"
[ ! -e "$dir/my-feature" ] || fail "remove hook left $dir/my-feature"
git -C "$repo" show-ref --verify --quiet refs/heads/my-feature ||
    fail "remove hook deleted my-feature, which existed before the worktree"

# Nothing inside an ignored dir the include doesn't name is copied, even what a pattern matching
# at any depth names; git lists sub/node_modules/ as sub/
mkdir -p "$repo/apps/web" "$repo/.cache/a" "$repo/config" "$repo/node_modules/pkg" "$repo/vendor/lib" \
    "$repo/certs/dev" "$repo/sub/node_modules/x"
touch "$repo/apps/web/index.js"
printf '.env*\n.cache/\nconfig/\n*.local\nnode_modules/\nvendor/\ncerts/\n' >> "$repo/.gitignore"
printf '.env*\n.cache/\nconfig/*.json\n*.local\n!keep.local\nvendor\n*.pem\n' >> "$repo/.worktreeinclude"
git -C "$repo" add .gitignore .worktreeinclude apps/web/index.js
git -C "$repo" commit -q -m "more includes"
ln -s "$SANDBOX/missing" "$repo/.env.local"
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
assert_contains "$(cat "$SANDBOX/stderr")" ".env.local" "create hook's stderr with a broken symlink to copy"
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
rm -rf "$repo/.env.local" "$repo/node_modules" "$repo/vendor" "$repo/certs" "$repo/sub"

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

# Branch from HEAD, whose .gitignore ignores the copies; test-git-wt.sh covers the other safeguards
end_session() {
    status=0
    printf '{"session_id":"%s","hook_event_name":"SessionEnd","reason":"%s","cwd":"%s"}' "$1" "${3:-other}" "$2" |
        bash "$hook" > "$SANDBOX/stdout" 2> "$SANDBOX/stderr" || status=$?
}
mkdir -p "$repo/.claude"
echo '{"worktree": {"baseRef": "head"}}' > "$repo/.claude/settings.local.json"
create e-clean "$repo" s1
assert_eq "0 $dir/e-clean" "$status $out" "create hook for e-clean"
assert_eq s1 "$(cat "$(git -C "$dir/e-clean" rev-parse --absolute-git-dir)/worktree-hook-session")" \
    "the session the create hook records"
create e-other "$repo" s2
end_session s1 "$repo" clear
assert_eq "0" "$status" "SessionEnd hook's exit status on /clear"
[ -d "$dir/e-clean" ] || fail "SessionEnd hook removed e-clean on /clear"
end_session s1 "$repo"
assert_eq "0" "$status" "SessionEnd hook's exit status"
assert_eq "" "$(cat "$SANDBOX/stdout")" "SessionEnd hook's stdout"
[ ! -e "$dir/e-clean" ] || fail "SessionEnd hook kept e-clean"
git -C "$repo" show-ref --verify --quiet refs/heads/e-clean && fail "SessionEnd hook kept branch e-clean"
end_session s2 "$SANDBOX"
assert_eq "0" "$status" "SessionEnd hook's exit status outside a repo"
printf '{"session_id":"s2","hook_event_name":"SessionEnd","cwd":"%s"}' "$repo" |
    env PATH=/usr/bin:/bin bash "$hook" > /dev/null 2>&1 || fail "SessionEnd hook without git wt failed"
[ -d "$dir/e-other" ] || fail "SessionEnd hook removed e-other without git wt"
git -C "$repo" wt rm -f e-other 2> /dev/null
mv "$repo/.env" "$repo/env-a"
ln -s env-a "$repo/.env"
create e-link "$repo" s3
[ ! -L "$dir/e-link/.env" ] || fail "the hook copied the .env symlink as a link"
assert_eq "secret" "$(cat "$dir/e-link/.env" 2> /dev/null)" "the .env copied into e-link"
rm "$repo/.env"
mv "$repo/env-a" "$repo/.env"

# The hook hard-codes Homebrew's dirs, so a copy points them into the sandbox
session_git() {
    local name
    mkdir -p "$SANDBOX/brew/bin" "$SANDBOX/session-bin"
    for name in brew session; do
        printf '%s\n' '#!/bin/bash' "echo $name >> \"$SANDBOX/git.log\"" "exec \"$real_git\" \"\$@\"" \
            > "$SANDBOX/$name-bin-git"
    done
    mv "$SANDBOX/brew-bin-git" "$SANDBOX/brew/bin/git"
    mv "$SANDBOX/session-bin-git" "$SANDBOX/session-bin/git"
    chmod +x "$SANDBOX/brew/bin/git" "$SANDBOX/session-bin/git"
    sed -e "s|/opt/homebrew/bin|$SANDBOX/brew/bin|" -e "s|/home/linuxbrew/.linuxbrew/bin|$SANDBOX/brew/bin|" \
        "$REPO_DIR/ai_tools/claude-code/worktree-hook.sh" > "$SANDBOX/hook.sh"
    hook="$SANDBOX/hook.sh"
    rm "$HOME/.local/bin/git"
    PATH="$SANDBOX/session-bin:$PATH"
    create e-path "$repo" s4
    assert_eq "0 $dir/e-path" "$status $out" "create hook with a git in Homebrew's dir"
    assert_file_contains "$SANDBOX/git.log" session
    assert_file_not_contains "$SANDBOX/git.log" brew
    git -C "$repo" wt rm -f e-path 2> /dev/null
}
subtest session_git
rm -r "$repo/.claude"
test_done
