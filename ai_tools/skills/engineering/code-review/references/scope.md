# Review scope

How the review skills (code-review, code-review-stds-and-spec, interrogate) and rewrite-docs turn the user's words into what to review. The lead agent resolves the scope once, before it starts any reviewer, and hands every reviewer the same **scope packet**. The file also lists the scope's **rule files**, under _Rule files_.

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
2. Fetch from the base repo, since `origin` may be a fork: `url="$(gh repo view --json url -q .url)"`, then `git fetch "$url" <baseRefName>`, `base_tip="$(git rev-parse FETCH_HEAD)"`, and `git fetch "$url" pull/<n>/head`. A fetch from a URL only adds objects and `FETCH_HEAD`.
3. `<head>` is `headRefOid`, and the base is `git merge-base "$base_tip" <head>`. The diff is `git diff <base> <head>`.
4. Materialize the head in the review's temp directory, per _Checks_, so reviewers read the PR's files as files.

## Checks

Make a temp directory for the review (`mktemp -d`), then run these before starting anything, so a bad scope fails once here instead of inside every reviewer.

To **materialize** a head is to write its files to `<tmp>/head` with `scripts/materialize-head.sh` from the code-review skill, the directory above this file's `references/`. Run it from inside the repo, as `materialize-head.sh <tmp> <head>`, or `materialize-head.sh <tmp> --staged`. It leaves the repo's branches, index, and working tree alone, and removing `<tmp>` cleans it up. Files go through the repo's checkout filters, so an LFS file comes out as its content, and Git LFS may download objects into `.git/lfs` for it. A submodule comes out as an empty directory, so read a submodule's files in its own checkout. Reviewers read a head other than the working tree there, since interrogate's restricted Claude reviewer can read only the repo and `<tmp>`.


- Every ref resolves: `git rev-parse --verify --quiet <ref>^{commit}`.
- The scope isn't empty: the scope's own diff command with `--stat` shows changes, or the untracked list or the files-mode list has files.
- For `commit <sha>`, the head is `<sha>`; for `A..B` or `A...B`, it is `B`. Resolve the head to a SHA and materialize it, so callers, tests, and rule files are read as they were at the head.
- For `staged`, materialize with `--staged`, which copies the index's version of each staged file, since the working tree may differ from what gets committed. Keep staged deletions in the review diff; they have no index entry to copy.
- Skip generated and vendored files unless the user named them: lockfiles, build output (`dist/`, `build/`), `vendor/`, minified bundles, snapshots, and binaries. List what you skipped in the packet.
- Measure the size: the diff command with `--shortstat`, plus `wc -l` of the untracked files, or `wc -l` of every file in files mode. Over about 60 files or about 5,000 lines, split the scope into **shards** of related files, by top-level directory or module, each under that size. Every reviewer runs once per shard, and the lead merges the shards' findings before judging them.

## Scope packet

In diff mode, write the diff to `<tmp>/scope.diff`, with `-U10` so each hunk carries its surroundings. For a sharded scope, number the shards from 1 and write each shard's diff to `<tmp>/scope-<shard>.diff` instead, with the shard's paths as the diff command's pathspec. Each shard gets its own packet. Every reviewer gets this block, filled in:

```
Scope: <the scope line>
Mode: diff | files
Base: <SHA, or none in files mode>
Head: <SHA, or "working tree">
Diff file: <tmp>/scope.diff (or the shard's diff), or none in files mode
Diff command: <the exact command that wrote it, with any pathspec>
Untracked: <paths to read whole, or none>
Commits: <git log --oneline <base>..<head, or HEAD for the working tree>, or none>
Files: <one per line: path and +added −removed, or path and line count>
Skipped: <paths and why, or none>
Read files: <"in the working tree"; "in <tmp>/head" for a PR, commit, or range; "changed files in <tmp>/head, the rest in the working tree" for staged>
```

Reviewers are **read-only**. They read the diff file and any file in the repo for context: callers, callees, types, and tests. A reviewer with a shell may also run git commands that only read, such as `log`, `blame`, and `grep`. They never edit, commit, check out, or fetch.

For PR, commit, and range scopes, Git history queries use the packet's head SHA. Never substitute the current working tree for missing historical context.

Each skill's own bar decides which findings in the scope count.

## Rule files

The **rule files** for a scope are every `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, and `CLAUDE.local.md` at the repo root and in each directory above a file in scope, plus the user's own (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`).
