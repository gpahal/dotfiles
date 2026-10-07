---
name: code-review
description: Reviews a diff, PR, commit, or set of files for bugs, verifies each finding, and reports them ranked. Use when the user asks to review code, a branch, a PR, or uncommitted work, or to find bugs before merging.
argument-hint: "[low|medium|high|xhigh|max] [scope] [--focus <areas>] [--fix] [--comment]"
---

# Code review

Find every defect a careful maintainer would fix, prove each one, and report them ranked. Finder sub-agents cast wide from separate angles, a verifier sub-agent tries to disprove each candidate, and the bar below decides what reaches the report.

## Arguments

- **Level**: `low`, `medium`, `high`, `xhigh`, or `max`. The default is `medium`. See _Levels_.
- **`--focus <areas>`**: review only for these concerns. See _Focus_.
- **Scope**: everything else the user passed or asked for. Resolve it with [`references/scope.md`](references/scope.md).
- **`--fix`**: after the report, fix the findings. See _Fix_.
- **`--comment`**: for a PR, post the findings as inline review comments. See _Comment_.

## 1. Resolve the scope

Follow `references/scope.md`. Done when you've printed the scope line and filled in the scope packet.

## 2. Gather context

- **Intent**: one paragraph on what the change is for, from the PR title and body, the commit messages, a spec or tickets under `.scratch/`, and the conversation. Finders judge the change against it.
- **Rule files**: the paths of every `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, and `CLAUDE.local.md` at the repo root and in each directory above a file in scope, plus the user's own (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`).

Done when you hold the intent paragraph and the list of rule files.

## 3. Find candidates

Start one finder sub-agent per angle for the level (or the focus), all at once, each told to edit nothing. Each gets the scope packet, the intent, the rule file paths, _The bar_, and its angle from [`references/angles.md`](references/angles.md). It returns up to the level's candidate count, each with:

- `file:line`, as narrow as the defect allows, inside the diff in diff mode
- a one-sentence summary
- a failure scenario: the concrete inputs or state, and the wrong output or crash that follows
- a category (the angle's name, or something narrower such as `test-coverage`) and a proposed priority

Tell finders to pass on every candidate with a failure scenario they can name, even one they half believe. A finder that drops those skips verification, and that's the main way real bugs go missing.

For a sharded scope, run the finders once per shard. Without a sub-agent tool, work through the angles yourself, one after another, and say in the report that the review ran in one context.

Done when every finder has returned.

## 4. Verify

Merge duplicates (same defect, same place) and keep the one with the most concrete failure scenario. Then start verifier sub-agents with [`references/verifier.md`](references/verifier.md), each told to edit nothing: one per candidate, or one per file when a file has several. Without a sub-agent tool, vote on each candidate yourself by that brief, before you look at the next. Keep the candidates the level keeps.

At `xhigh` and `max`, run the gap sweep from `references/angles.md` next, within the level's limit, and verify what it finds the same way.

Done when every candidate has a vote. Remove the PR worktree if the scope made one.

## Levels

| Level    | Finders                                                                             | Candidates per finder | Keep                                       | Report up to |
| -------- | ----------------------------------------------------------------------------------- | --------------------- | ------------------------------------------ | ------------ |
| `low`    | None. You read the diff once, per _Low level_ in `references/angles.md`             | n/a                   | What you'd stake your name on, no verifier | 5            |
| `medium` | A, B, C, reuse, simplification, efficiency, altitude, conventions                   | 6                     | CONFIRMED, and PLAUSIBLE at P0 or P1       | 8            |
| `high`   | `medium`'s, plus F, docs and comments, and tests                                    | 6                     | CONFIRMED and PLAUSIBLE                    | 12           |
| `xhigh`  | `high`'s, plus D and E, then a gap sweep for up to 4 correctness bugs               | 8                     | CONFIRMED and PLAUSIBLE                    | 15           |
| `max`    | `xhigh`'s, with a gap sweep for up to 8 defects of any kind                         | 8                     | CONFIRMED and PLAUSIBLE                    | all          |

`medium` reports what a maintainer will act on. `high` and above favor recall: a bug that ships costs more than a finding the author dismisses. When more findings survive than the level reports, keep the highest priority, and correctness findings before cleanup.

## Focus

`--focus` takes a comma-separated list. Each named area runs its angles from `references/angles.md`, whether or not the level includes them, and no other angles run. The level still sets the candidates per finder, what to keep, the gap sweep, and the report size.

| Area          | Angles                          |
| ------------- | ------------------------------- |
| `correctness` | A, B, C, D, E                   |
| `security`    | F                               |
| `performance` | Efficiency                      |
| `cleanup`     | Reuse, simplification, altitude |
| `conventions` | Conventions                     |
| `docs`        | Docs and comments               |
| `tests`       | Tests                           |

Anything else in the focus, such as `--focus "retry logic"` or `--focus concurrency`, becomes a **custom angle**: one more finder briefed to hunt that one concern across the scope. At `low`, which has no finders, the focus narrows what you flag yourself. Name the focus in the report's coverage line.

## The bar

Report a finding only when all of these hold:

1. It meaningfully affects correctness, security, performance, or maintainability.
2. It's one discrete defect with one fix, not a general complaint about the codebase.
3. The change introduced it, or touched the function that has it. Problems elsewhere that predate the change don't count. In files mode, everything in the files counts.
4. You can show how it happens: name the inputs, state, or call site that trigger it. To claim the change breaks other code, name that code.
5. It isn't what the change evidently meant to do.
6. The fix asks for no more rigor than the rest of the codebase shows.
7. The author would fix it if they knew.

Leave out style unless it hides meaning or breaks a rule in a rule file, and anything a linter, formatter, or type checker already enforces.

Priorities:

- **P0**: breaks release or major use for everyone, whatever the input.
- **P1**: urgent. Fix before merging.
- **P2**: a real defect. Fix soon.
- **P3**: low impact, still worth fixing.

## Report

Start with the scope line and the level. Then the findings, highest priority first, one per defect:

```
[P1] <imperative title, at most 80 characters> (path/to/file.ts:42)
<One paragraph. Start with the scenario that triggers it, then what goes wrong and why. Say how
much the severity depends on that scenario.>
```

- Quote at most 3 lines of code. Add a fix in one sentence, or a ` ```suggestion ` block when the replacement is exact and complete.
- When a rule file backs the finding, cite its path and line range and quote the rule.
- Mark a PLAUSIBLE finding with what would confirm it: `(plausible: fails only if two writers race on X)`.
- Write it matter-of-fact, so the author gets the point on one read.

If nothing survives, write `No findings.`

Then close with:

- **Verdict**: `correct` or `incorrect`, and one to three sentences why. Correct means existing code and tests won't break and no blocking defect remains. Nits don't count.
- **Test gaps and risk**: what the change leaves untested, and what you couldn't verify. Leave it out when there's nothing.
- **Coverage**: the focus, if any, the finders that ran, the candidates they raised, and how many verifiers refuted.

If your tools include a findings-report tool, such as Claude Code's `ReportFindings`, report the findings through one call to it (ranked, with `level`, and each finding's `file`, `line`, `summary`, `short_summary`, `failure_scenario`, `category`, and `verdict`) instead of printing them. Print the scope line, verdict, gaps, and coverage as usual.

## Fix

With `--fix`, after the report, fix each CONFIRMED finding, and each PLAUSIBLE one you agree with, with the smallest change that removes the defect. Run the tests that cover the files you changed. Report what you fixed and what you left, and why. Leave the changes uncommitted. A PR that isn't checked out can't be fixed in place: say so and stop.

## Comment

With `--comment` on a PR, post one review that holds every finding as an inline comment on the PR head:

```sh
gh api repos/{owner}/{repo}/pulls/<n>/reviews --method POST --input <file>
```

where `<file>` holds `{"commit_id": "<head>", "event": "COMMENT", "body": "<verdict>", "comments": [{"path": "...", "line": 42, "side": "RIGHT", "body": "..."}]}`. A comment's line must be in the diff. Put a finding whose line isn't into the review body. With no findings, post the verdict alone. For any other scope, `--comment` does nothing: say so.
