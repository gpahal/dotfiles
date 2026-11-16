---
name: code-review-council
description: "Has the council models, Opus and Sol unless you name others, review the same change independently, then checks their findings into one verdict."
disable-model-invocation: true
argument-hint: "[low|medium|high|xhigh|max] [models] [scope]"
---

# Code review council

Models from different families miss different things. Each council member reviews the same change alone, from the same brief. You are the lead: you check what they found against the code and tell the user what is real. The verdict is the deliverable, so leave the user's checkout unchanged.

Either Claude Code or Codex can run this skill.

## Council

The members are the models the user names, after the skill name or in their own words ("with Sonnet and Sol", "add Fable"). Named models replace the table unless the user says to add them, and the same model may run as two members. Without names, the members are the table:

| Member | Family | Model             |
| ------ | ------ | ----------------- |
| A      | Claude | `claude-opus-5-5` |
| B      | Codex  | `gpt-6.1-sol`     |

To change a default, edit this table. It is the only place the defaults are set.

Run a Claude model through the `claude` family and an OpenAI model through `codex`. Pass a Claude model as the claude CLI's alias (`opus`, `sonnet`, `fable`) or its full name. Pass a Codex model by its full name, taken from the table when the user means a model there ("Sol"). If a named model belongs to neither family, or its name is too vague to resolve, tell the user it can't run instead of substituting another, and run the rest. If no member can run, stop.

The user can mark a member non-blocking. Write the report without waiting for it: findings it returns in time are judged like any other, but it gets no score.

## Run the members

1. Work out the scope with the code-review skill's [`references/scope.md`](../code-review/references/scope.md) (installed beside this skill). Write one paragraph on what the change is meant to do. If you can't tell, ask the user first.
2. Write the prompt to `<tmp>/prompt.md`: the brief below, the intent, and the scope facts. Put the diff file in `<tmp>` too. Outside the repo, the Claude member can read only the prompt file's directory.
3. Make a second temp directory, `<answers>` (`mktemp -d`), and leave its path out of the prompt. The script refuses an out-file under the repo or `<tmp>`, where one member could read another's answer.
4. Run every member from the repo root, in the background, with the same prompt file:

```sh
${CLAUDE_SKILL_DIR}/scripts/run-reviewer.sh <claude|codex> <model> <effort> <tmp>/prompt.md <answers>/<member>.md
```

In Codex, resolve `scripts/run-reviewer.sh` against this skill's `SKILL.md` path instead. The effort is the first argument when it is `low`, `medium`, `high`, `xhigh`, or `max`, and `high` otherwise. The script runs that family's CLI read-only and writes the member's final answer to the out-file. It needs network access, so in a sandbox, ask to run it outside.

The Codex member can read any file you can, so instructions planted in a diff could get a secret quoted into its answer. Run this skill only on changes from authors you trust.

If a run fails, retry it once. If it fails again, carry on and say in the verdict which member is missing. A member that fails gets `no score`.

The brief:

> Review this change and find what is wrong with it: bugs, security holes, and design that will cost the team later. Read around the change before you judge it: callers, callees, types, and tests. For each problem, say where it is, how it happens, and why it matters. For a bug, give the command or test that would show it. Put the most serious first. Say nothing about what is fine. "No findings" is a valid answer. End with `SCORE: <n>/10` for how ready the change is to merge. You are read-only: edit nothing, and review alone, without sub-agents.

## Judge

Judge each member's answer as it lands, while the others still run. Open the code behind every finding before you rule on it. A finding more than one member raised independently is strong evidence. A lone finding stands on its own evidence.

Prove a bug by running it when that is cheap: a failing test or a short script. Run it in a detached worktree (`git worktree add --detach <tmp>/run <head>`, with the uncommitted diff applied for a working-tree scope), not in the user's checkout. A bug whose run shows nothing wrong is dismissed.

Judge as a pragmatic senior engineer would: given what the change is for, what is worth acting on now?

## Report

Tell the user what to fix and why, with who raised each finding and the proof. Then what is worth a thought but may not be worth its cost, and what you dismissed and why. Say where the members agreed and where they split. Give each member's model and score; a member with no `SCORE` line has `no score`, never a guessed one. Use whatever shape fits the findings.

When the report is written, remove the run worktree (`git worktree remove --force <tmp>/run`) and both temp directories.
