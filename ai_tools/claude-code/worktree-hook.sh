#!/bin/bash
set -euo pipefail

# Claude Code's WorktreeCreate, WorktreeRemove, and SessionEnd hook. It puts the worktrees that
# --worktree, subagent isolation, and background sessions use where git wt does,
# ~/.worktrees/<group>/<repo>/<name>, with the branch named <name>. When another worktree has
# <name> checked out, such as main, both are worktree-<name> instead. Claude Code keeps a
# subagent's worktree when the subagent finishes, so at the end of a session the hook removes the
# ones made for it that hold nothing to lose (git wt prune --session).
#
# Contract (https://code.claude.com/docs/en/hooks): JSON on stdin. WorktreeCreate gets `name`,
# `cwd`, and `session_id`, and Claude Code reads the worktree's absolute path from the last line
# of stdout, so all other output goes to stderr. WorktreeRemove gets `worktree_path`, and must
# leave it deleted. SessionEnd gets `session_id` and `cwd`, and can't stop the session ending.
#
# The hook replaces Claude Code's own git worktree code, so it does what that did: it honors
# worktree.baseRef (fresh, the default, fetches and branches from origin's default branch; head
# branches from HEAD), and copies the gitignored files .worktreeinclude names. It ignores
# worktree.symlinkDirectories and worktree.sparsePaths. Nothing in it may wait for input.

# Claude Code started from the Dock or a launcher may have only the system's PATH. git wt is in
# ~/.local/bin. Homebrew's dirs go last, for the jq Ubuntu lacks (macOS ships /usr/bin/jq), so the
# hook runs the same git as the session.
for dir in /home/linuxbrew/.linuxbrew/bin /opt/homebrew/bin; do
    if [ -d "$dir" ]; then
        PATH="$PATH:$dir"
    fi
done
export PATH="$HOME/.local/bin:$PATH"
export GIT_TERMINAL_PROMPT=0

input="$(cat)"
exec < /dev/null

die() {
    echo "worktree-hook: $*" >&2
    exit 1
}

field() {
    printf '%s' "$input" | jq -r --arg key "$1" '.[$key] // empty'
}

# Print worktree.baseRef from the first settings file that sets it: the project's local, then the
# project's shared, then the user's. Claude Code's default is fresh.
base_ref() {
    local file value
    for file in "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.local.json" \
        "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json" \
        "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
        [ -f "$file" ] || continue
        value="$(jq -r '.worktree.baseRef // empty' "$file" 2> /dev/null || true)"
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return
        fi
    done
    echo fresh
}

# Print the file whose mtime records the hook's last successful fetch of origin's branch $1, one
# per branch in the repo's common git dir, so every worktree shares it. FETCH_HEAD can't stand in:
# any fetch, of another branch or remote, rewrites it, and the user's own fetches don't count.
# % and / are encoded, so each branch gets its own file name.
fetch_stamp() {
    printf '%s/dotfiles-worktree-hook/fetched-%s\n' \
        "$(git rev-parse --path-format=absolute --git-common-dir)" \
        "$(printf '%s' "$1" | sed 's/%/%25/g; s|/|%2F|g')"
}

# Bring the branch git wt base picks up to date, so the worktree branches from what's on the
# remote. Every `claude -w` and isolated subagent waits for this, so skip it within 10 minutes of
# the hook's last fetch of that branch, and stop the fetch 15 s after it starts
# (WORKTREE_HOOK_FETCH_DEADLINE, which the test shortens). That's a deadline for the whole fetch,
# not a stall timeout, so a slow fetch that's still downloading stops too. A failed fetch leaves
# the local copy, as Claude Code does, and no stamp.
fetch_default_branch() {
    local base branch stamp
    base="$(git wt base)"
    case "$base" in
        refs/remotes/origin/*) ;;
        *) return 0 ;;
    esac
    branch="${base#refs/remotes/origin/}"
    stamp="$(fetch_stamp "$branch")"
    [ -z "$(find "$stamp" -mmin -10 2> /dev/null)" ] || return 0
    if fetch_with_timeout "$branch"; then
        mkdir -p "$(dirname "$stamp")" && touch "$stamp" || true
    else
        echo "worktree-hook: couldn't fetch ${base#refs/remotes/}; branching from the local copy" >&2
    fi
}

# Job control gives the fetch and watchdog separate process groups, including their children.
# Killing both groups on exit also covers SSH wrappers that ignore TERM. No external timeout
# command is needed on macOS's system Bash.
fetch_with_timeout() (
    set -m
    git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 fetch --quiet origin "$1" >&2 &
    fetch_pid=$!
    (
        set +m
        sleep "${WORKTREE_HOOK_FETCH_DEADLINE:-15}"
        kill -TERM -- "-$fetch_pid" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$fetch_pid" 2>/dev/null || true
    ) &
    timer_pid=$!
    trap 'kill -KILL -- "-$fetch_pid" "-$timer_pid" 2>/dev/null || true; wait "$timer_pid" 2>/dev/null || true' EXIT
    wait "$fetch_pid"
)

# Print the ssh command git would run in this repo, GIT_SSH_COMMAND, else core.sshCommand, else
# GIT_SSH, else ssh, with BatchMode, so nothing ssh does for the fetch or git wt add (an LFS smudge, a hook) can
# ask for input, and a 5 s connect timeout
batch_ssh_command() {
    local ssh="${GIT_SSH_COMMAND:-}"
    [ -n "$ssh" ] || ssh="$(git config core.sshCommand || true)"
    if [ -z "$ssh" ] && [ -n "${GIT_SSH:-}" ]; then
        # GIT_SSH names one executable, while GIT_SSH_COMMAND is interpreted by a shell. sed, not
        # ${//}, escapes its apostrophes: bash 3.2 parses quotes in that replacement differently.
        ssh="'$(printf '%s' "$GIT_SSH" | sed "s/'/'\\\\''/g")'"
    fi
    printf '%s -o BatchMode=yes -o ConnectTimeout=5\n' "${ssh:-ssh}"
}

# Print the path of the worktree that has branch $1 checked out, if any. awk reads to the end:
# exiting at the match would kill a long listing with SIGPIPE, and pipefail the hook.
branch_worktree() {
    git worktree list --porcelain | awk -v ref="branch refs/heads/$1" '
        /^worktree / { path = substr($0, 10) }
        $0 == ref && found == "" { found = path }
        END { if (found != "") print found }'
}

# Name of the file, in a worktree's git dir, that says the hook created its branch, so removing
# the worktree may delete it. A branch that existed before, such as a pushed one, is kept. Beside
# it goes the file naming the session the worktree was made for. git wt prune reads both.
CREATED_BRANCH_MARKER=worktree-hook-created-branch
SESSION_MARKER=worktree-hook-session

# symlinked_parent <worktree> <entry>: print the first dir above <entry> that is a symlink in the
# worktree, as when its branch tracks config as a link to a dir outside it, and fail when none is
symlinked_parent() {
    local dir="" rest="$2"
    while [ "${rest#*/}" != "$rest" ]; do
        dir="${dir:+$dir/}${rest%%/*}"
        rest="${rest#*/}"
        if [ -L "$1/$dir" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
        [ -d "$1/$dir" ] || return 1
    done
    return 1
}

# Copy what the checkout's .worktreeinclude names, and git ignores, into the new worktree. Unlike
# Claude Code, which searched every ignored dir, node_modules included, git lists an ignored dir
# whole without entering it, and a matching dir is copied whole. So a pattern inside an ignored
# dir, such as build/config.json when build/ is ignored, matches nothing; name the dir instead.
# The match runs in an empty repo, so the checkout's .gitignore doesn't apply. An entry that can't
# be copied, or sits under a dir the new branch tracks as a symlink, is skipped with a warning.
copy_worktree_include() {
    local top include tmp entry flags link
    top="$(git rev-parse --show-toplevel)"
    include="$top/.worktreeinclude"
    [ -f "$include" ] || return 0
    tmp="$(mktemp -d)" || return 1
    git init -q "$tmp" || { rm -rf "$tmp"; return 1; }
    # check-ignore treats an entry with a trailing slash as a dir, so dir/ patterns match it
    git -C "$top" ls-files -z --others --ignored --exclude-standard --directory |
        { git -C "$tmp" -c core.excludesFile="$include" check-ignore --no-index -z --stdin ||
            true; } |
        while IFS= read -r -d '' entry; do
            # -p copies what a symlink points at, so the worktree gets its own copy, which a link
            # relative to the checkout or into it wouldn't give
            flags=-p
            case "$entry" in */) flags=-pR entry="${entry%/}" ;; esac
            # A tracked symlink, even a dangling one, could point cp outside the worktree
            if [ -e "$1/$entry" ] || [ -L "$1/$entry" ]; then
                continue
            fi
            if link="$(symlinked_parent "$1" "$entry")"; then
                echo "worktree-hook: skipped $entry: $link is a symlink in the worktree" >&2
                continue
            fi
            # -R keeps the symlinks in a dir
            if ! { mkdir -p "$(dirname "$1/$entry")" && cp "$flags" "$top/$entry" "$1/$entry"; }; then
                echo "worktree-hook: couldn't copy $entry into the worktree" >&2
            fi
        done
    rm -rf "$tmp"
}

create() {
    local name cwd base="" path other own gitdir session existed=false
    name="$(field name)"
    cwd="$(field cwd)"
    [ -n "$name" ] || die "no worktree name in the input"
    cd "${cwd:-.}"
    GIT_SSH_COMMAND="$(batch_ssh_command)"
    export GIT_SSH_COMMAND
    if [ "$(base_ref)" = head ]; then
        base=HEAD
    else
        fetch_default_branch
    fi
    # A branch checked out in another worktree, such as main, can't be checked out again. Use
    # worktree-<name>, Claude Code's own default, for the branch and the directory. git prints
    # resolved paths, so compare against the resolved path too.
    other="$(branch_worktree "$name")"
    own="$(git wt path "$name")"
    if [ -n "$other" ] && [ "$other" != "$own" ] &&
        [ "$other" != "$(CDPATH='' cd -P -- "$(dirname "$own")" 2> /dev/null && pwd)/${own##*/}" ]; then
        name="worktree-$name"
    fi
    git show-ref --verify --quiet "refs/heads/$name" && existed=true
    # Without a base, git wt add would track a branch origin has, which the fetch didn't update
    if [ -z "$base" ] && ! "$existed"; then
        base="$(git wt base)"
    fi
    path="$(git wt add "$name" ${base:+"$base"})"
    if ! "$existed"; then
        gitdir="$(git -C "$path" rev-parse --absolute-git-dir)"
        touch "$gitdir/$CREATED_BRANCH_MARKER"
        session="$(field session_id)"
        [ -z "$session" ] || printf '%s\n' "$session" > "$gitdir/$SESSION_MARKER"
    fi
    copy_worktree_include "$path" ||
        echo "worktree-hook: couldn't copy the files .worktreeinclude names" >&2
    printf '%s\n' "$path"
}

remove() {
    local path dir common branch name created=false
    path="$(field worktree_path)"
    [ -n "$path" ] || die "no worktree_path in the input"
    # Already gone counts as removed
    [ -d "$path" ] || return 0
    common="$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)" ||
        die "$path isn't in a git repository"
    # Empty in a linked worktree of a --separate-git-dir repo, where git wt can't find the main
    # checkout, so the worktree counts as not one of ours below
    dir="$(git -C "$path" wt path 2> /dev/null || true)"
    # Not --short, which prints heads/<name> for a branch a tag shares a name with
    branch="$(git -C "$path" symbolic-ref --quiet HEAD 2> /dev/null || true)"
    branch="${branch#refs/heads/}"
    [ ! -f "$(git -C "$path" rev-parse --absolute-git-dir)/$CREATED_BRANCH_MARKER" ] || created=true
    # The common directory is a Git context even for submodules and separate-git-dir repos.
    # Its parent needn't be a checkout, and the worktree being removed can't remain our cwd.
    cd "$common"
    if [ -n "$dir" ] && [ "${path#"$dir"/}" != "$path" ]; then
        name="${path#"$dir"/}"
    else
        # Not one of ours: a worktree outside ~/.worktrees, or one of a --separate-git-dir repo,
        # where dir is empty
        git worktree remove --force "$path" >&2
        return
    fi
    # Claude Code asks before removing a worktree with changes, so by now they're meant to go.
    # Delete the branch too when the create hook made it, unless it has commits no other branch,
    # local or remote, has.
    if [ "$branch" = "$name" ] && "$created"; then
        git wt rm --force --delete-merged-branch "$name" >&2
    else
        git wt rm --force "$name" >&2
    fi
}

# Remove the session's worktrees that hold nothing to lose. A cwd outside a repo has none.
session_end() {
    local session cwd
    session="$(field session_id)" && cwd="$(field cwd)" || return 0
    [ -n "$session" ] && [ -n "$cwd" ] || return 0
    git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1 || return 0
    git -C "$cwd" wt prune --session "$session" >&2 || true
}

case "$(field hook_event_name)" in
    WorktreeCreate) create ;;
    WorktreeRemove) remove ;;
    # Cleanup that fails leaves worktrees behind, which isn't worth an error as Claude Code exits
    SessionEnd) session_end || true ;;
    *) die "expected a WorktreeCreate, WorktreeRemove, or SessionEnd event" ;;
esac
