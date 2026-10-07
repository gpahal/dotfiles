---
name: show-me-your-work
description: "Lists the decisions behind the work so far, each with its phase, reason, evidence, and result, and flags the ones to check."
disable-model-invocation: true
argument-hint: "[what to cover] [--check]"
---

# Show me your work

Reply with a numbered list of the decisions behind the work in this conversation, so the user can review a long or unattended run and check each claim. The reply is the deliverable: write no file.

## List the decisions

One item per decision, in the order they happened: a fork taken, an approach dropped, a unit of work finished and how it was verified, a pivot or revert and its trigger, a blocker hit, and an assumption made without asking. Leave out routine actions, such as reading files or running the obvious command.

```
1. **<The decision: what was chosen or done, in one line>**
   - Phase: <the stage or workstream, in a word or two>
   - Why: <the reason, in plain words>
   - Evidence: <a pointer to follow: a commit SHA, `path:line`, a PR, or the command whose output showed it>
   - Result: <the outcome as a state, such as tests pass, reverted, open, or unverified>
```

Evidence is a pointer, never a paragraph. When there is none, write `none`: that gap is a finding in itself. Write each item the way you'd tell a teammate what you did, and apply the unslop skill.

If the user named a part of the work ("since the last commit", "the migration"), cover only that part. If earlier turns were compacted into a summary, build those items from the summary and add `(from summary)` to their phase.

## Audit the list

Before replying, check every item against what happened:

- It maps to a real decision or action in this conversation.
- Its evidence resolves and shows what the item claims: the commit exists (`git cat-file -e <sha>`), the line says it, the command's output showed that result.
- A fork, pivot, or dropped approach that shaped the work but has no item is a gap. Add it.

Correct a wrong item so it states what happened. Done when every item passes and no gap remains.

## Attention

End with an **Attention** section: the items the user should check first, by number. Flag decisions with weak or `none` evidence, verification claimed but never shown, choices that look risky now (premature, beyond scope, or treating a symptom), and assumptions the user never confirmed. `No flags.` is a valid answer.

With `--check`, have a reviewer from the other model family scan the list before you write Attention, since a model reviewing its own work misses what it already believes. In a `mktemp -d` directory, write `prompt.md`: the list, the `git log --stat` of the commits it cites, and a brief to flag the problems above by item number, reading files in the repo to test the evidence. Run it from the repo root with the interrogate skill's runner, installed beside this skill:

```sh
<skill-dir>/../interrogate/scripts/run-reviewer.sh <claude|codex> <model> medium <tmp>/prompt.md <tmp>/check.md
```

Take the other family's model from the reviewer table in the interrogate skill's `SKILL.md`. The runner needs network access, so in a sandbox, ask to run it outside (in Codex, request escalated permissions). Merge its flags into Attention, and start the section with `Reviewed by <model>.` If the run fails, say so in Attention and give your own flags.
