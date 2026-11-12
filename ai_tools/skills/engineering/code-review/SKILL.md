---
name: code-review
description: Reviews a diff, PR, commit, or set of files for bugs, checks each finding, and reports them ranked. Use when the user asks to review code, a branch, a PR, or uncommitted work, or to find bugs before merging.
argument-hint: "[deep] [scope] [--fix] [--comment]"
---

# Code review

Find the defects a careful maintainer would fix in this change, and report the ones you can show.

## What to review

Work out the scope with [`references/scope.md`](references/scope.md). Work out what the change is for from the PR, the commit messages, a spec or tickets under `.scratch/`, and the conversation. Read the rule files that apply.

## How to review

Read the change, then read around it: the whole function around each hunk, the callers, the callees, the types, and the tests. Go where your judgment says the bugs are. Places that often hide one:

- Logic in the changed lines, and the known traps of the language.
- Behavior that deleted or moved code used to enforce.
- Callers and readers of anything the change modified.
- Untrusted input that reaches a query, a shell, a file path, or a page.
- New code that repeats something the codebase already has, or adds complexity it doesn't need.
- Docs, comments, and tests the change made wrong, and rules in the rule files it breaks.

For each suspected defect, work out how it happens: the input, state, or call site that triggers it, and the wrong result that follows. Then try to prove yourself wrong by reading the code again. Drop what the code refutes. Keep a defect that is real but depends on timing or config you can't settle, and say what would confirm it.

By default, do this yourself in one careful pass. Go **deep** when the user says `deep`, or when the change is large or touches code where a bug is costly or silent: concurrency, auth, persistence and migrations, money, public APIs. Going deep means splitting the hunt across parallel read-only sub-agents in whatever way suits the change, then giving the findings to a fresh sub-agent that tries to disprove each one. Without a sub-agent tool, do both passes yourself.

## What counts

Report a finding when it meaningfully affects correctness, security, performance, or maintainability, the change introduced it or touched the function that has it, and the author would fix it if they knew. Leave out style, anything a linter or type checker already catches, problems that predate the change, and behavior the change clearly meant.

## Report

Start with the scope line. List the findings, most serious first. For each one give the `file:line`, how it happens, what goes wrong, and a fix when you have one. Say which findings should block the merge. If there are none, write `No findings.`

End with a verdict: is the change safe to merge, and why. Add what you couldn't check.

If your tools include a findings-report tool, such as Claude Code's `ReportFindings`, report the findings through one call to it instead of printing them.

## Fix and comment

With `--fix`, after the report, fix each finding you stand behind with the smallest change that removes it. Run the tests that cover what you changed, report what you fixed and what you left, and leave the changes uncommitted. A PR that isn't checked out can't be fixed in place: say so.

With `--comment` on a PR, post one review with every finding as an inline comment on the PR head: `gh api repos/{owner}/{repo}/pulls/<n>/reviews --method POST --input <file>`. GitHub rejects the whole review if one comment's line is outside the hunks of `gh pr diff <n>`, so check each line against that diff and put any finding that doesn't fit into the review body.
