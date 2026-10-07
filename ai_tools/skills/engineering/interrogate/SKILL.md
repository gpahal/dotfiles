---
name: interrogate
description: "Has a Claude reviewer and a Codex reviewer tear into the same change independently, then judges their findings into one verdict."
disable-model-invocation: true
argument-hint: "[low|medium|high|xhigh|max] [scope]"
---

# Interrogate

Two reviewers from different model families review the same change adversarially, with the same prompt. The signal comes from model diversity: what both find independently is the strongest evidence, and where they disagree is worth a look. You are the lead. You scope the change, state its intent, run both reviewers, and judge what they found. The deliverable is the verdict, so change no code.

Either Claude Code or Codex can run this skill.

## Reviewers

| Reviewer | Family | Model             |
| -------- | ------ | ----------------- |
| A        | Claude | `claude-opus-5-5` |
| B        | Codex  | `gpt-6-astra`     |

To change a model, edit this table. Both reviewers run through the script below with these exact values, so the table is the only place they're set.

## Effort

The first argument, when it's `low`, `medium`, `high`, `xhigh`, or `max`, is the **effort**: the reasoning effort both reviewers run at. The default is `medium`. Both models accept all five. The rest of the arguments are the scope.

## 1. Resolve the scope

Follow the code-review skill's [`references/scope.md`](../code-review/references/scope.md) (installed beside this skill). The scope comes from the arguments after the effort, and the request. Done when you've printed the scope line and filled in the scope packet.

## 2. State the intent

Write one paragraph on what the change is meant to do, from the user's message, the commit messages, the PR body, a spec or tickets under `.scratch/`, and the code. If you can't tell, ask the user before starting any reviewer.

## 3. Run the reviewers

Fill in the part of [`references/reviewer-prompt.md`](references/reviewer-prompt.md) below its `---` line: the intent, the scope packet, [`references/rubric.md`](references/rubric.md), and [`references/code-quality-review.md`](references/code-quality-review.md), each reference pasted without its top heading. Save it as `<tmp>/prompt.md`, in the scope's temp directory beside the diff file. Both reviewers get that same file.

Run each reviewer from the repo root, in the background, both at once:

```sh
<skill-dir>/scripts/run-reviewer.sh <claude|codex> <model> <effort> <tmp>/prompt.md <tmp>/<reviewer>.md
```

`<skill-dir>` is this skill's directory, the model comes from the table, and the effort is the run's effort. The script runs that family's CLI read-only, from the repo root, and writes the reviewer's final answer to the out-file. It needs network access, so in a sandbox, ask to run it outside (in Codex, request escalated permissions). It stops a reviewer that runs past 30 minutes, or 60 minutes at `high` effort and above.

For a sharded scope, run both reviewers once per shard, each shard with its own prompt file.

When a reviewer fails (the CLI is missing or signed out, the run errors or times out, or the answer is empty), the script exits non-zero and prints the CLI's last log lines. Retry it once. If it fails again, carry on with the other reviewer, and say in the verdict that only one model reviewed the change.

Done when you hold each reviewer's findings, or the error from its second failure.

## 4. Synthesize

- **Parse** every finding from every reviewer.
- **Merge duplicates.** The two models describe one issue in different words. Merge them into one finding and note that both raised it.
- **Consensus**: a finding both reviewers raised independently is the strongest signal.
- **Lone findings** are still worth reading. Weight them by their evidence.
- **Disagreements**: one reviewer flags something and the other argues the opposite. Keep both sides for the verdict.

## 5. Judge

You are the lead reviewer, a pragmatic senior engineer, not a neutral aggregator. Apply [`references/lead-judgment.md`](references/lead-judgment.md). Open the code behind each finding and trace it before you rule. Put every finding in exactly one bucket:

- **Act on**: a real problem with correctness, security, or maintainability, given the actual goals. It would block a real PR.
- **Consider**: a fair point whose fix may not be worth its cost right now. The user should weigh it.
- **Noted**: true but not worth acting on: low impact, premature, or dependent on context.
- **Dismissed**: wrong, a nitpick, or missing context. Say why in a line.

Each finding carries the reviewers that raised it, its priority, and a one-line reason for its bucket. When the verdict is written, remove the PR worktree if the scope made one.

## Output

```
### Scope
<the scope line>

### Intent
> <the paragraph from step 2>

### Reviewers
- A: claude-opus-5-5 (<effort>), <N> findings, or the reason it failed
- B: gpt-6-astra (<effort>), <N> findings, or the reason it failed

### Act on
<each finding: what's wrong, where, who raised it, why it matters>

### Consider
<each finding: what's wrong, who raised it, the trade-off>

### Noted
<a short list>

### Dismissed
<each finding, with the reason>

### Agreement map
<where the reviewers agreed, where they split, and what that pattern says about the change>
```
