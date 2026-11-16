---
name: code-review-council-loop
description: "Has every council model, Opus and Sol unless you name others, review a change, fixes what holds up, and repeats until all of them and the author agree."
disable-model-invocation: true
argument-hint: "[low|medium|high|xhigh|max] [models] [scope]"
---

# Code review council loop

Run the code-review-loop skill, read from [`../code-review-loop/SKILL.md`](../code-review-loop/SKILL.md) (installed beside this skill), with these changes:

- The reviewers are every council member, picked as the _Council_ section of the code-review-council skill's `SKILL.md` (`../code-review-council/SKILL.md`) says: the models the user names, after the skill name or in their own words, and otherwise the table. A fresh run of your own family's model still reviews with no memory of your work.
- Each round, run all the reviewers at once, in the background, with the same prompt. Give each its own out-file. The answer shape gains a `SCORE: <n>/10` line after `VERDICT`, for how ready the change is to merge.
- Check each reviewer's findings against the code as its answer lands, while the others still run, and plan your answers. Edit nothing in scope until every blocking reviewer has finished. If you must edit while a non-blocking reviewer still runs, stop it first; it has no answer that round.
- Merge findings that describe one problem, and note who raised each. A finding more than one reviewer raised is stronger evidence.
- You have agreed only when every blocking reviewer approves the current diff. A non-blocking reviewer's approval isn't needed, and its findings count as feedback for the next round. A later round goes to every reviewer, since a fix for one can break what another approved.
- Report a table of each reviewer's model, verdict, and score per round. A reviewer that gave no `SCORE` line has `no score`, never a guessed one.
