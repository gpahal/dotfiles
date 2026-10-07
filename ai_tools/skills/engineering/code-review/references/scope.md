# Review scope

How the review skills (code-review, code-review-stds-and-spec, interrogate) and rewrite-docs turn the user's words into what to review. The lead agent resolves the scope once, before it starts any reviewer, and hands every reviewer the same **scope packet**.

## Forms

A scope has a **mode**: _diff_ reviews what changed, and _files_ reviews whole files as they are.

First, pull out any **paths** (files, directories, globs). Paths together with a diff form narrow it: apply `-- <paths>` to its diff and to its untracked list. Paths with no diff form select files mode: the current content of the matching tracked files. Then match the rest against this table, top to bottom, and take the first row that fits:

| The user gives                                       | Mode  | Base, and the diff to review                                                      |
| ---------------------------------------------------- | ----- | --------------------------------------------------------------------------------- |
| Nothing                                              | diff  | Per _Default_ below                                                               |
| `all`, `repo`, or `.`                                | files | Every tracked file                                                                |
| `uncommitted` or `wip`                               | diff  | Base `HEAD`: `git diff HEAD`, plus untracked files                                |
| `staged`                                             | diff  | Base `HEAD`: `git diff --cached`, with the staged files copied out, per _Checks_  |
| A PR: `#123`, `pr 123`, or a PR URL                  | diff  | Per _Pull requests_ below                                                         |
| `commit <sha>`, or "the last commit"                 | diff  | Base `<sha>^`: `git show --format= --diff-merges=first-parent <sha>`              |
| A range: `A..B` or `A...B`                           | diff  | Base `git merge-base A B`: `git diff A...B`, the commits on `B` since it forked   |
| A ref, or "since X": a branch, tag, SHA, or `HEAD~3` | diff  | Base `git merge-base <ref> HEAD`: `git diff <base>`, plus untracked files         |

"Untracked files" are `git ls-files --others --exclude-standard [-- <paths>]`, reviewed whole as new files.

Anything else ("the auth refactor", "what I did today") gets translated into these forms: a feature becomes its paths, a stretch of time becomes a range of commits (`git log --since`). The translation goes into the scope line.

Before reviewing, print one **scope line** that says what you resolved, such as "Reviewing `feat/login` since `main` (merge base `a1b2c3d`) plus uncommitted work: 14 files, +420 −96."

## Default

With no scope given:

1. Find the default branch: `git symbolic-ref --short refs/remotes/origin/HEAD`, with the `origin/` prefix removed. If that fails, use `main`, then `master`.
2. On any other branch, review since the default branch, by the ref row. Use `origin/<default>` when it exists, since the local branch can be stale, and the local branch otherwise.
3. On the default branch, review the uncommitted changes plus any unpushed commits: the ref row with `@{upstream}` as the ref. With no upstream, review the uncommitted changes only.
4. If that is empty, ask the user what to review, and offer the last commit.

## Pull requests

Review a PR without touching the working tree:

1. `gh pr view <n> --json number,title,body,baseRefName,headRefOid,url`. The title and body feed the intent.
2. `git fetch origin pull/<n>/head <baseRefName>`, which only adds objects and remote-tracking refs.
3. `<head>` is `headRefOid`, and the base is `git merge-base origin/<baseRefName> <head>`. The diff is `git diff <base> <head>`.
4. Check the head out in a detached worktree inside the review's temp directory, `git worktree add --detach <tmp>/head <head>`, so reviewers read the PR's files as files. Remove it with `git worktree remove --force <tmp>/head` when the review is done.

## Checks

Make a temp directory for the review (`mktemp -d`), then run these before starting anything, so a bad scope fails once here instead of inside every reviewer:

- Every ref resolves: `git rev-parse --verify --quiet <ref>^{commit}`.
- The scope isn't empty: the scope's own diff command with `--stat` shows changes, or the untracked list or the files-mode list has files.
- For `staged`, copy the staged version of each file into the temp directory, `git checkout-index --prefix=<tmp>/head/ -- <paths>`, since the working tree may differ from what gets committed.
- Skip generated and vendored files unless the user named them: lockfiles, build output (`dist/`, `build/`), `vendor/`, minified bundles, snapshots, and binaries. List what you skipped in the packet.
- Measure the size: the diff command with `--shortstat`, plus `wc -l` of the untracked files, or `wc -l` of every file in files mode. Over about 40 files or about 3,000 lines, split the scope into **shards** of related files, by top-level directory or module, each under that size. Every reviewer runs once per shard, and the lead merges the shards' findings before judging them.

## Scope packet

In diff mode, write the diff to `<tmp>/scope.diff`, with `-U10` so each hunk carries its surroundings. Every reviewer gets this block, filled in:

```
Scope: <the scope line>
Mode: diff | files
Base: <SHA, or none in files mode>
Head: <SHA, or "working tree">
Diff file: <tmp>/scope.diff, or none in files mode
Diff command: <the exact command that wrote it, with any pathspec>
Untracked: <paths to read whole, or none>
Commits: <git log --oneline <base>..<head, or HEAD for the working tree>, or none>
Files: <one per line: path and +added −removed, or path and line count>
Skipped: <paths and why, or none>
Read files: <"in the working tree", or "in <tmp>/head" for a PR or staged>
```

Reviewers are **read-only**. They read the diff file and any file in the repo for context: callers, callees, types, and tests. A reviewer with a shell may also run git commands that only read, such as `log`, `blame`, and `grep`. They never edit, commit, check out, or fetch.

Each skill's own bar decides which findings in the scope count.
