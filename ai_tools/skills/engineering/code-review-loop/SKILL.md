---
name: code-review-loop
description: "Has a model from the other family review a change, fixes what holds up, and repeats until the reviewer and the author agree."
disable-model-invocation: true
argument-hint: "[low|medium|high|xhigh|max] [scope]"
---

# Code review loop

Get a change reviewed, answer the review, and send it back, until the reviewer and you agree. You are the author. The reviewer is the council member from the other model family: a Codex model when you are Claude, a Claude model when you are Codex.

Make the smallest changes that settle the real findings. Push back on the rest, and never agree only to end the loop.

## The reviewer

Take the reviewer's model from the Council table in the code-review-council skill's `SKILL.md` (`../code-review-council/SKILL.md`, installed beside this skill), and run it the way that skill's _Run the members_ section says, with its `scripts/run-reviewer.sh`. The same rules apply: the prompt and diff go in `<tmp>`, the answer goes in a separate directory, the run needs network access, and the change must come from authors you trust. Each run starts with no memory of the last one, so every prompt carries what the reviewer needs.

Edit nothing in scope while a review runs. A run that fails or times out is not an approval: retry it once, then tell the user.

## Rounds

The budget is 3 rounds. Go to 5 only when the user asks, or when the change touches auth, permissions, data loss, or concurrency and a real finding is still open.

1. **Scope.** Work out the scope and the intent with the code-review skill's `references/scope.md` (`../code-review/references/scope.md`). Leave unrelated changes alone. Run the checks that cover the change first, and fix what the change broke before sending it.
2. **Round 1.** Ask for a full review. The brief asks the reviewer to find what is wrong with the change given its intent, to hold the change to its smallest form, and to answer in this shape:

   ```
   VERDICT: APPROVE or CHANGES
   R1 [blocker|should|nit] <file>:<line> <what is wrong and how it happens>. Fix: <suggestion>
   ```

   A blocker means the intended case is wrong. A should is a real bug callers will hit. Everything else is a nit.
3. **Answer each finding.** Check it against the code yourself, and regrade it if the reviewer overrated it.
   - If you agree, make the smallest fix. Prefer deleting or narrowing code to adding a guard, an option, or a helper.
   - If you disagree, say why with evidence: a `file:line`, a test, or command output.
   - If it is out of scope or a nit, decline it in one line and list it as a follow-up.

   Keep a list of every finding and your answer. Run the checks again. If the review made the diff bigger, cut before going on.
4. **Next round.** Run one only when a blocker or should is still open, or you changed behavior since the last verdict. Send the intent, your list of answers, and what changed since the last round. Ask the reviewer to look only at the open findings and the changed code, to mark each old finding `resolved` or `still open`, and to give a new verdict.

## Stopping

- **Agreed**: the reviewer approves the current diff, no blocker or should is open, and you have no concern of your own.
- **Only nits left**: stop without another round.
- **Stuck**: a finding is still disputed after two replies, or the budget runs out. Show the user both sides in a few lines each and let them decide. Running out of rounds is not an approval.

Leave the changes uncommitted unless the user asked for a commit. Report the rounds, the reviewer's model, whether you agreed, what you fixed, and what you declined and why. Then remove the temp directories.
