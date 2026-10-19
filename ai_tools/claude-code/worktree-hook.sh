#!/bin/bash
set -euo pipefail

# Claude Code's WorktreeCreate, WorktreeRemove, and SessionEnd hook, creating worktrees with git wt.
# Claude Code reads the created path from stdout's last line, so all other output goes to stderr.
# Replaces Claude Code's worktree code: honors worktree.baseRef and .worktreeinclude, ignores
# worktree.symlinkDirectories and worktree.sparsePaths. Nothing may wait for input.

# Launched from the Dock, Claude Code may have only the system PATH. Homebrew is for jq on Ubuntu.
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

# Stamp file whose mtime is the hook's last fetch of branch $1. Not FETCH_HEAD: any fetch rewrites it.
fetch_stamp() {
    printf '%s/dotfiles-worktree-hook/fetched-%s\n' \
        "$(git rev-parse --path-format=absolute --git-common-dir)" \
        "$(printf '%s' "$1" | sed 's/%/%25/g; s|/|%2F|g')"
}

# Every `claude -w` waits on this, so skip within 10 min of the last fetch and cap it at 15 s total.
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

# set -m puts fetch and watchdog in their own process groups, so killing a group gets children
# too (SSH wrappers ignoring TERM). macOS's bash has no timeout command.
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

# The ssh command git would use, with BatchMode so nothing can prompt.
batch_ssh_command() {
    local ssh="${GIT_SSH_COMMAND:-}"
    [ -n "$ssh" ] || ssh="$(git config core.sshCommand || true)"
    if [ -z "$ssh" ] && [ -n "${GIT_SSH:-}" ]; then
        # GIT_SSH is one executable, so quote it. sed, since bash 3.2 mis-parses quotes in ${//}.
        ssh="'$(printf '%s' "$GIT_SSH" | sed "s/'/'\\\\''/g")'"
    fi
    printf '%s -o BatchMode=yes -o ConnectTimeout=5\n' "${ssh:-ssh}"
}

# awk reads to the end: exiting early would SIGPIPE git and fail the hook under pipefail.
branch_worktree() {
    git worktree list --porcelain | awk -v ref="branch refs/heads/$1" '
        /^worktree / { path = substr($0, 10) }
        $0 == ref && found == "" { found = path }
        END { if (found != "") print found }'
}

# Markers in a worktree's git dir: the hook created the branch (so removal may delete it), and the
# session it was made for. git wt prune reads both.
CREATED_BRANCH_MARKER=worktree-hook-created-branch
SESSION_MARKER=worktree-hook-session

# symlinked_parent <worktree> <entry>: print the first dir above <entry> that's a symlink, else fail
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

# Unlike Claude Code, a pattern inside an ignored dir (build/x when build/ is ignored) matches
# nothing; name the dir. Matching runs in an empty repo so the checkout's .gitignore doesn't apply.
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
            # -p copies a symlink's target, since a link into the checkout wouldn't be its own copy
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
    # A branch checked out elsewhere can't be checked out again; fall back to Claude Code's
    # worktree-<name>. git prints resolved paths, so compare the resolved one too.
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
    [ -d "$path" ] || return 0
    common="$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)" ||
        die "$path isn't in a git repository"
    # Empty in a --separate-git-dir repo, where git wt can't find the main checkout
    dir="$(git -C "$path" wt path 2> /dev/null || true)"
    # Not --short, which prints heads/<name> for a branch a tag shares a name with
    branch="$(git -C "$path" symbolic-ref --quiet HEAD 2> /dev/null || true)"
    branch="${branch#refs/heads/}"
    [ ! -f "$(git -C "$path" rev-parse --absolute-git-dir)/$CREATED_BRANCH_MARKER" ] || created=true
    # A git context even for submodules and separate-git-dir repos, and not the removed worktree
    cd "$common"
    if [ -n "$dir" ] && [ "${path#"$dir"/}" != "$path" ]; then
        name="${path#"$dir"/}"
    else
        # Not one of ours
        git worktree remove --force "$path" >&2
        return
    fi
    # Claude Code already asked before discarding changes
    if [ "$branch" = "$name" ] && "$created"; then
        git wt rm --force --delete-merged-branch "$name" >&2
    else
        git wt rm --force "$name" >&2
    fi
}

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
    SessionEnd) session_end || true ;;
    *) die "expected a WorktreeCreate, WorktreeRemove, or SessionEnd event" ;;
esac
