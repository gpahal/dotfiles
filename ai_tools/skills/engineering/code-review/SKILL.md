---
name: code-review
description: Reviews a diff, PR, commit, or set of files for bugs, verifies each finding, and reports them ranked. Use when the user asks to review code, a branch, a PR, or uncommitted work, or to find bugs before merging.
argument-hint: "[low|medium|high|xhigh|max] [scope] [--focus <areas>] [--fix] [--comment]"
---

# Code review

Find every defect a careful maintainer would fix, prove each one, and report them ranked. Finder sub-agents cover every angle at the level's effort, a verifier tries to disprove each candidate, and the bar below decides what reaches the report.

## Arguments

- **Level**: `low`, `medium`, `high`, `xhigh`, or `max`. The default is `medium`. It sets the sub-agents' effort and how finely the angles are split. See _Levels_.
- **`--focus <areas>`**: review only for these concerns. See _Focus_.
- **Scope**: everything else the user passed or asked for. Resolve it with [`references/scope.md`](references/scope.md).
- **`--fix`**: after the report, fix the findings. See _Fix_.
- **`--comment`**: for a PR, post the findings as inline review comments. See _Comment_.

## 1. Resolve the scope

Follow `references/scope.md`. Done when you've printed the scope line and filled in the scope packet.

## 2. Gather context

- **Intent**: one paragraph on what the change is for, from the PR title and body, the commit messages, a spec or tickets under `.scratch/`, and the conversation. Finders judge the change against it.
- **Rule files**: the paths of every rule file, per _Rule files_ in `references/scope.md`.

Done when you hold the intent paragraph and the list of rule files.

## 3. Find candidates

A **finder** is a sub-agent that works through a set of angles from [`references/angles.md`](references/angles.md) over the whole scope. Every level covers every angle. The level sets the effort and how finely the angles are split: the higher the level, the fewer angles each finder carries, so it can dig deeper into each one.

Start the level's finders all at once, each told to edit nothing. If the sub-agent tool caps how many run at once, start the rest as earlier ones finish. Each gets the scope packet, the intent, the rule file paths, _The bar_, and its angles. A finder returns up to 10 candidates, each with:

- `file:line`, as narrow as the defect allows, inside the diff in diff mode
- a one-sentence summary
- a failure scenario: the concrete inputs or state, and the wrong output or crash that follows
- a category (the angle's name, or something narrower such as `test-coverage`) and a proposed priority

Tell finders to pass on every candidate with a failure scenario they can name, even one they half believe. A finder that drops those skips verification, and that's the main way real bugs go missing. At `low`, which has no verifier, tell the finder instead to pass only the candidates it would stake its name on. Also tell it to read no files beyond the diff file, the untracked files (in files mode, the files in scope), and the rule files, to skip test and fixture files (`test/`, `spec/`, `__tests__/`, `*_test.*`, `*.test.*`, `fixtures/`, `testdata/`), and to take each angle only as far as those files show.

For a sharded scope, run the finders once per shard.

Done when every finder has returned.

## 4. Verify

Merge duplicates (same defect, same place) and keep the one with the most concrete failure scenario. At `low`, keep the finder's candidates as they are. From `medium` up, start verifier sub-agents with [`references/verifier.md`](references/verifier.md), each told to edit nothing: one per about 15 candidates, splitting the candidates by file. Keep the candidates the level keeps.

At `xhigh` and `max`, run the gap sweep from `references/angles.md` next, as a fresh finder, and verify what it finds the same way.

Done when every candidate has a vote, or at `low` when duplicates are merged. Then remove the review's temp directory, `<tmp>`, which holds any materialized head.

## Levels

Run every sub-agent the review starts (finders, verifiers, and the gap sweep) at the level as its reasoning effort, through the sub-agent tool's effort setting: `effort` in Claude Code's Agent tool, `reasoning_effort` in Codex's `spawn_agent`, with `fork_context` left unset (or, under Codex's MultiAgentV2, `fork_turns` set to `"none"`), since a full-history fork keeps the parent's effort. If the tool takes no effort setting, the sub-agents run at the session's effort. Say so in the coverage line.

| Level    | Finders                                                                                    | Verifier | Keep                                    | Report up to |
| -------- | ------------------------------------------------------------------------------------------ | -------- | --------------------------------------- | ------------ |
| `low`    | 1: Line, Flow, Design, and Conformance                                                     | None     | What the finder would stake its name on | 5            |
| `medium` | 2: Line and Flow; Design and Conformance                                                   | Yes      | CONFIRMED, and PLAUSIBLE at P0 or P1    | 8            |
| `high`   | 4: Line; Flow; Design; Conformance                                                         | Yes      | CONFIRMED and PLAUSIBLE                 | 12           |
| `xhigh`  | 7: A; D; B; C and E; F; Design; Conformance. Then a gap sweep for up to 4 correctness bugs | Yes      | CONFIRMED and PLAUSIBLE                 | 15           |
| `max`    | 13: one per angle. Then a gap sweep for up to 8 defects of any kind                        | Yes      | CONFIRMED and PLAUSIBLE                 | all          |

Line, Flow, Design, and Conformance are the angle groups in `references/angles.md`. At high and above, a split never mixes angles from different groups.

`low` and `medium` report what a maintainer will act on. `high` and above favor recall: a bug that ships costs more than a finding the author dismisses. When more findings survive than the level reports, keep the highest priority, and correctness findings (Line and Flow) before the rest.

Without a sub-agent tool, work through every finder's angles yourself, one finder at a time, and from `medium` up vote on each candidate yourself by `references/verifier.md`, before you look at the next. Say in the report that the review ran in one context, at the session's effort.

## Focus

`--focus` takes a comma-separated list. Only the named areas' angles run, split the way the level splits them: a finder with no focused angle doesn't run, and a finder with some keeps only those. The level still sets the effort, the verifier, what to keep, the gap sweep, and the report size.

| Area          | Angles                          |
| ------------- | ------------------------------- |
| `correctness` | A, B, C, D, E                   |
| `security`    | F                               |
| `performance` | Efficiency                      |
| `cleanup`     | Reuse, simplification, altitude |
| `conventions` | Conventions                     |
| `docs`        | Docs and comments               |
| `tests`       | Tests                           |

Anything else in the focus, such as `--focus "retry logic"` or `--focus concurrency`, becomes a **custom angle**: a brief to hunt that one concern across the scope. It runs as one more finder, or joins the single finder at `low`. Name the focus in the report's coverage line.

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
- **Coverage**: the level and the effort the sub-agents ran at, the focus, if any, the finders that ran, the candidates they raised, and how many were refuted (from `medium` up).

If your tools include a findings-report tool, such as Claude Code's `ReportFindings`, report the findings through one call to it (ranked, with `level`, and each finding's `file`, `line`, `summary`, `short_summary`, `failure_scenario`, `category`, and `verdict`) instead of printing them. Print the scope line, verdict, gaps, and coverage as usual.

## Fix

With `--fix`, after the report, fix each CONFIRMED finding, and each PLAUSIBLE one you agree with, with the smallest change that removes the defect. Run the tests that cover the files you changed. Report what you fixed and what you left, and why. Leave the changes uncommitted. A PR that isn't checked out can't be fixed in place: say so and stop.

## Comment

With `--comment` on a PR, post one review that holds every finding as an inline comment on the PR head:

```sh
gh api repos/{owner}/{repo}/pulls/<n>/reviews --method POST --input <file>
```

where `<file>` holds `{"commit_id": "<head>", "event": "COMMENT", "body": "<verdict>", "comments": [{"path": "...", "line": 42, "side": "RIGHT", "body": "..."}]}`. A comment's line must fall inside a hunk of `gh pr diff <n>`, GitHub's own diff, which carries less context than the review's `-U10` diff; GitHub rejects the whole review over one line outside its hunks. Check each line against `gh pr diff <n>`, and put a finding whose line isn't there into the review body. With no findings, post the verdict alone. For any other scope, `--comment` does nothing: say so.
