---
name: implement
description: "Implements a spec or its tickets with parallel sub-agents in worktrees, then reviews the result."
disable-model-invocation: true
---

Implement the work described by the spec or tickets the user names. They live in the repo under `.scratch/<feature-slug>/`: the spec at `SPEC.md`, the tickets under `tickets/`. If the user names neither, ask which feature to implement. A spec with no tickets is one ticket.

If the feature has a `DESIGN.md` from the `architect` skill, the type sketch it describes is the contract: fill in the `not implemented` bodies rather than inventing a new shape, and surface any deviation the sketch didn't anticipate.

If the code doesn't already have any tests, confirm with the user what they want to do and present them relevant options on testing.

## Setup

1. Record the **base branch**: the branch checked out now (`git branch --show-current`). The closing review compares against it.
2. Worktrees start from committed history, so if `git status --porcelain` shows changes outside `.scratch/`, ask the user whether to commit them first.
3. Create the **integration branch** from the base branch and check it out here: `git switch -c <feature-slug>`. Every ticket lands on it.
4. Add `.scratch/*/worktrees/` to the file `git rev-parse --git-path info/exclude` prints, unless it's already there, so the worktrees below stay out of `git status`.

## Working tickets

The tickets form a **task graph**: each names the tickets that block it. The **frontier** is every `ready` ticket whose blockers are all `done`. Keep messages to and from sub-agents short: pass paths to the spec, the tickets, `DESIGN.md`, and commits instead of restating them.

1. For each frontier ticket:
   - Set its **Status** to `in-progress`.
   - Create its worktree from the integration branch tip: `git worktree add -b <feature-slug>-<NN> .scratch/<feature-slug>/worktrees/<NN> <feature-slug>`.
   - Start an **implementer sub-agent** in the background, given the worktree path and absolute paths to the ticket and spec, since `.scratch/` may not exist in the worktree. Start all of them at once.
2. Each implementer, working only inside its worktree:
   - builds the ticket with the tdd skill where possible, at the seams the spec agreed;
   - runs typechecking and the tests for the files it touched, and commits;
   - merges the integration branch tip into its branch, fixes any conflict, reruns the tests, and commits;
   - reports done, or what blocks it, in a few lines.
3. When an implementer reports done, merge its branch into the integration branch here: `git merge --no-ff --no-edit <feature-slug>-<NN>`. Hand any conflict to a **merger sub-agent** so its detail stays out of your context. Then tick the ticket's acceptance criteria and set its Status to `done`.
4. If that merge unblocked tickets, start their implementers right away (step 1), without waiting for the rest of the running ones.

Done when every ticket is `done` and merged into the integration branch, and the full test suite passes there.

## Closing out

1. Pick the code review's level from the work's complexity, per _Review level_ below.
2. Run both reviews. Each covers the integration branch since the base branch, which is the whole feature now that every ticket is merged, so pass `<base-branch>` as the scope of each:
   - **The code-review skill** at that level, for bugs.
   - **The code-review-stds-and-spec skill**, with the spec path (plus the ticket files) as its spec source, for conformance. One invocation covers both of its axes.

   Each skill runs its own sub-agents in parallel, so run the two skills one after the other. Done when you hold the code review's findings and the `## Standards` and `## Spec` reports.
3. Fix the findings you agree with on the integration branch and rerun the tests.
4. Remove each implementer worktree (`git worktree remove`) and its branch (`git branch -d`), then report the integration branch.

### Review level

Size the review to the work. Read the change with `git diff --stat <base-branch>...<feature-slug>` alongside the spec and tickets, and take the highest row that matches. `high` is the ceiling, so never pass `xhigh` or `max`:

| Level    | The work                                                                   |
| -------- | -------------------------------------------------------------------------- |
| `low`    | Up to a few tickets, or a change contained in one module                   |
| `medium` | Several tickets, a change across modules, or a shape set by `DESIGN.md`    |
| `high`   | A large change across many modules, or any change touching a risky surface |

A **risky surface** is code where a bug is costly or silent: concurrency and shared state, auth and permissions, persistence and migrations, money, public APIs and wire formats.
