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
| B        | Codex  | `gpt-6.1-sol`     |

To change a model, edit this table. Both reviewers run through the script below with these exact values, so the table is the only place they're set.

## Effort

The first argument, when it's `low`, `medium`, `high`, `xhigh`, or `max`, is the **effort**. The default is `medium`. Both models accept all five. The rest of the arguments are the scope.

The effort sets two things. Every reviewer run uses it as its reasoning effort. It also sets how finely the lenses are split across runs: every effort applies every lens, and the higher the effort, the fewer lenses each run carries, so it can dig deeper into each one.

## Splits

There are seven **lenses**: the six sections of [`references/rubric.md`](references/rubric.md) and the code-quality lens in [`references/code-quality-review.md`](references/code-quality-review.md). They fall into three groups of related lenses. At high and above, a split never mixes groups:

- **Bugs**: correctness, and security
- **Causes**: root causes vs. symptoms, and verification
- **Shape**: structural integrity, complexity budget, and the code-quality lens

| Effort   | Splits                                                                                                                |
| -------- | --------------------------------------------------------------------------------------------------------------------- |
| `low`    | 1: every lens                                                                                                         |
| `medium` | 2: Bugs and Causes; Shape                                                                                             |
| `high`   | 3: Bugs; Causes; Shape                                                                                                |
| `xhigh`  | 5: correctness; security; root causes and verification; structural integrity and complexity budget; code-quality lens |
| `max`    | 7: one per lens                                                                                                       |

Both reviewers run every split, so the runs are twice the splits.

## 1. Resolve the scope

Follow the code-review skill's [`references/scope.md`](../code-review/references/scope.md) (installed beside this skill). The scope comes from the arguments after the effort, and the request. Done when you've printed the scope line and filled in the scope packet.

## 2. State the intent

Write one paragraph on what the change is meant to do, from the user's message, the commit messages, the PR body, a spec or tickets under `.scratch/`, and the code. If you can't tell, ask the user before starting any reviewer.

## 3. Run the reviewers

For each split, fill in the part of [`references/reviewer-prompt.md`](references/reviewer-prompt.md) below its `---` line: the intent, the scope packet, and the split's lenses. The rubric section gets the split's `##` sections of `references/rubric.md`, demoted to `###`, without the file's title and intro line. The code-quality section gets `references/code-quality-review.md` without its top heading. Leave out a section with none of the split's lenses. Both reviewers get the same prompt file for a split.

Number the splits from 1. For a sharded scope, number the shards from 1 too, and fill each shard's prompts with that shard's packet. An unsharded scope is shard 1. Save each prompt as `<tmp>/prompt-<shard>-<n>.md`, directly in the scope's temp directory. The script lets Claude read only the prompt file's directory, so that directory has to hold the diff files and any materialized `head`.

Make a second temp directory, `<answers>` (`mktemp -d`), for the reviewers' answers, and leave its path out of every prompt. The script refuses an out-file under the prompt file's directory, where Claude would read the other reviewer's answers.

Run every reviewer on every split of every shard from the repo root, in the background, at most 4 at a time. Start each of the rest as an earlier run finishes.

```sh
${CLAUDE_SKILL_DIR}/scripts/run-reviewer.sh <claude|codex> <model> <effort> <tmp>/prompt-<shard>-<n>.md <answers>/<reviewer>-<shard>-<n>.md
```

In Codex, resolve `scripts/run-reviewer.sh` against this skill's `SKILL.md` path instead. The model comes from the table, and the effort is the run's effort. The script runs that family's CLI read-only, from the repo root, and writes the reviewer's final answer to the out-file. It needs network access, so in a sandbox, ask to run it outside (in Codex, request escalated permissions). It stops a reviewer that runs past 30 minutes, or 60 minutes at `high` effort and above.

When a run fails (the CLI is missing or signed out, the run errors or times out, or the answer is empty), the script exits non-zero and prints the CLI's last log lines. Retry it once. If it fails again, carry on with the other runs, and say in the verdict which splits only one model reviewed.

Done when you hold each run's findings, or the error from its second failure.

## 4. Synthesize

- **Parse** every finding from every run.
- **Merge duplicates.** The two models, or two splits, describe one issue in different words. Merge them into one finding and note who raised it.
- **Consensus**: a finding both reviewers raised independently is the strongest signal.
- **Lone findings** are still worth reading. Weight them by their evidence.
- **Disagreements**: one reviewer flags something and the other argues the opposite. Keep both sides for the verdict.

## 5. Judge

You are the lead reviewer, a pragmatic senior engineer, not a neutral aggregator. Apply [`references/lead-judgment.md`](references/lead-judgment.md). Open the code behind each finding and trace it before you rule. Put every finding in exactly one bucket:

- **Act on**: a real problem with correctness, security, or maintainability, given the actual goals. It would block a real PR.
- **Consider**: a fair point whose fix may not be worth its cost right now. The user should weigh it.
- **Noted**: true but not worth acting on: low impact, premature, or dependent on context.
- **Dismissed**: wrong, a nitpick, or missing context. Say why in a line.

Each finding carries the reviewers that raised it, its priority, and a one-line reason for its bucket. When the verdict is written, remove both temp directories, `<tmp>` and `<answers>`.

## Output

```
### Scope
<the scope line>

### Intent
> <the paragraph from step 2>

### Reviewers
Effort: <effort>, in <S> splits
- A: <model from the Reviewers table>, <N> findings, and any split whose run failed, with the reason
- B: <model from the Reviewers table>, <N> findings, and any split whose run failed, with the reason

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
