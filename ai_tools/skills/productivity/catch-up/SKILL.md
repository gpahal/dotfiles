---
name: catch-up
description: "Catches the user up on what changed in this conversation since their last message, and lists every decision waiting on them."
disable-model-invocation: true
---

# Catch up

Catch the user up on what changed in this conversation since the last message they wrote before this one. Assume they remember that message and nothing after it. Change nothing: no edits, no posts, no new jobs.

Gather your own work since then, what sub-agents reported, and the current state of each PR, check, or agent this conversation touched. Check every number against where it came from.

Write the way one person catches up another: plain words, short sentences, no jargon. Say what changed for the user, not how you did it. Leave out hashes, paths, and commands unless the user needs one to act.

1. Open with one sentence that says what is waiting on the user, or that nothing is.
2. Say what happened, briefly: one line per thing the user asked for, with whether it is done, still running, failed, or not checked. Show a screenshot or a small diagram where a picture explains it faster than words.
3. List every decision waiting on the user: a choice, an approval, a step that can't be undone, or access you lack. For each one give your pick, what it changes, the evidence behind your pick, and its risk, so the user can decide from this reply alone. Work you can still do yourself is not on this list. Name it in one line instead.

If nothing happened and nothing is waiting, say so and stop.
