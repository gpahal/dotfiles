---
name: code-review-council-loop
description: "Has every council model review a change, fixes what holds up, and repeats until all of them and the author agree."
disable-model-invocation: true
argument-hint: "[low|medium|high|xhigh|max] [scope]"
---

# Code review council loop

Run the code-review-loop skill, read from [`../code-review-loop/SKILL.md`](../code-review-loop/SKILL.md) (installed beside this skill), with these changes:

- The reviewers are every member of the Council table in the code-review-council skill, not only the other family's. A fresh run of your own family's model still reviews with no memory of your work.
- Each round, run all the reviewers at once, in the background, with the same prompt. Give each its own out-file.
- Merge findings that describe one problem, and note who raised each. A finding more than one reviewer raised is stronger evidence.
- You have agreed only when every reviewer approves the current diff. A later round goes to every reviewer, since a fix for one can break what another approved.
- Report each reviewer's verdict per round.
