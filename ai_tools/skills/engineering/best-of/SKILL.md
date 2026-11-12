---
name: best-of
description: "Runs several independent attempts at the same task, keeps the best one, and adds the strongest parts of the others."
disable-model-invocation: true
argument-hint: "[number of attempts] [task]"
---

# Best of

One attempt locks in the first shape that comes to mind. Run several attempts at the same task, keep the best as the base, and add what the others did better.

1. **Frame.** Say what each attempt must produce, and write down the few things that make a result good for this task. Attempts get only the task. The list is for judging them.
2. **Attempt.** Start the attempts as sub-agents, all at once, each with the same task and context. Run 2 unless the user gave a number. Use different models when your tools can start them, since they fail in different ways. Give each attempt its own place to write: its own git worktree for code, or its own directory otherwise. Ask each for the result and a short note on what it considered and rejected. If one fails, carry on with the rest and say so.
3. **Pick.** Read every attempt in full. Judge each against your list, and pick as the base the one a later maintainer could extend most easily. If the attempts all took the same shape, that agreement is the answer. If they share almost nothing, the task was unclear: reframe it and run again.
4. **Add.** Go through the other attempts for what is worth bringing over, usually one or two things each. Work each into the base by hand, so the result still reads as one design.
5. **Check.** Verify the final result as you would any other work: run it, test it, read the diff.

Report the base and why you picked it, what you brought over and from which attempt, and what you rejected. Then remove the attempts' worktrees and branches, and leave the result uncommitted unless the user asked for a commit.

Without a sub-agent tool, make the attempts yourself, one after another, and write down the first attempt's main decision before starting the second so the second takes a different one.
