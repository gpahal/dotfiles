---
name: grill
description: Interviews the user relentlessly about a plan, decision, or idea. Use when the user says "grill me" or "grill this", or asks to stress-test or poke holes in a plan.
---

Interview the user relentlessly until you reach a shared understanding. Map the plan as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet. Ask the whole frontier in one round, each question with your recommended answer. Then wait for the user's answers before the next round.

## Asking a round

If you have a tool that asks the user multiple-choice questions (Claude Code's `AskUserQuestion`, Codex's `request_user_input`), ask every round through it:

- Give each question 2 to 4 distinct choices. Put your recommended choice first and end its label with "(Recommended)". Each choice's description says what picking it commits the user to.
- Write each question to stand alone: the user may see only the question dialog, so name the decision and any fact it rests on.
- When the frontier holds more questions than one call takes, ask them in consecutive calls before recomputing the frontier.
- An open question with no natural choices still goes through the tool: offer your recommendation and one or two real alternatives, since the user can always type their own answer.

If the tool is missing, or returns no answer, ask the round as text instead. Number each question and word it so "yes" accepts your recommended answer:

```
**Q1. <question title>**

<question body, might be multiple paragraphs, including multiple choices>

Recommended: <your recommended answer>

---

**Q2. <question title>**

<question body, might be multiple paragraphs, including multiple choices>

Recommended: <your recommended answer>
```

## Between rounds

Each round the user answers reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier and ask the next round. A question whose answer depends on another question still open in this round belongs to a _later_ round, not this one.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment (filesystem, tools, etc.), look it up yourself; don't ask the user for anything you could look up. If the lookup is a broad search, hand it to a sub-agent started with a fresh context and don't block on it: a running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the sub-agent to report; ask the rest of the frontier now. The _decisions_ are the user's: put each to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on the plan until the user confirms you have reached a shared understanding.
