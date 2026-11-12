# Review scope

How the review skills and fix-docs decide what to review. Work the scope out once, before any reviewer starts, and give every reviewer the same facts.

## What to review

Review what the user names: a PR, a commit, a range, "since X", `staged`, `uncommitted`, some paths, or `all` for the whole repo. Paths on their own mean those files as they are now. Paths beside one of the others narrow it. Turn anything looser ("the auth refactor", "what I did today") into one of these.

When the user names nothing:

- On a feature branch, review everything since the branch left the default branch, plus uncommitted and untracked work. Compare against `origin/<default>` when it exists, since the local default branch can be stale.
- On the default branch, review the uncommitted work plus any unpushed commits.
- If that is empty, ask the user what to review, and offer the last commit.

Leave out generated and vendored files unless the user named them: lockfiles, build output, `vendor/`, minified bundles, snapshots, and binaries.

Before reviewing, print one **scope line** that says what you resolved, such as "Reviewing `feat/login` since `main` (merge base `a1b2c3d`) plus uncommitted work: 14 files, +420 −96."

## Code that isn't checked out

Review without changing the user's working tree, index, or branches.

For a PR, read it with `gh pr view <n> --json number,title,body,baseRefName,headRefOid,url`. Fetch from the base repo's URL (`gh repo view --json url -q .url`), since `origin` may be a fork: fetch `<baseRefName>` and `pull/<n>/head`. The diff runs from the merge base of the two to `headRefOid`.

When the code under review differs from the working tree (a PR, a commit, a range, or `staged`), reviewers need its files as files. Make a temp directory, `<tmp>` (`mktemp -d`), and run `scripts/materialize-head.sh <tmp> <commit>` or `scripts/materialize-head.sh <tmp> --staged` from inside the repo. The script is in the code-review skill, the directory above this file's `references/`. It writes the files to `<tmp>/head` and leaves the repo alone. Remove `<tmp>` when the review is done.

## What reviewers get

Give each reviewer the scope line, the base and head, the exact diff command, the untracked files to read whole, and where to read the code: the working tree, or `<tmp>/head`. For a reviewer that runs through a CLI, also write the diff to `<tmp>/scope.diff`.

Reviewers are read-only. They read the diff and any file around it, and may run git commands that only read. They never edit, commit, check out, or fetch.

## Rule files

The **rule files** for a scope are every `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, and `CLAUDE.local.md` at the repo root and in each directory above a file in scope, plus the user's own (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`).
