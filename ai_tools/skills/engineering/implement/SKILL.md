---
name: implement
description: "Implements a spec or its tickets in dependency order, then reviews the result."
disable-model-invocation: true
---

Implement the work described by the spec or tickets the user names. They live in a **feature folder**, `.scratch/<feature-slug>/` unless the user passes the path of another folder: the spec at `SPEC.md`, the tickets under `tickets/`. The folder's name is the **feature slug**. Either file may be missing. A spec with no tickets is one ticket. If the user names no feature, ask which one to implement.

If the feature has a `DESIGN.md` from the `architect` skill, the type sketch it describes is the contract: fill in the `not implemented` bodies rather than inventing a new shape, and surface any deviation the sketch didn't anticipate.

If the code has no tests yet, ask the user which they want: add a test setup first, test only at the spec's seams, or skip tests.

## Setup

1. Read every ticket and build the **task graph**: a ticket's id is its file's `NN` prefix, and its **Blocked by** line names the ids or titles of the tickets that gate it. If a blocker matches no ticket, or the blockers form a cycle, show the user the edges at fault and ask how to fix them before changing anything. Done when every edge points at a ticket and the graph has no cycle.
2. If the integration branch, named `<feature-slug>`, already exists, this run **resumes** an earlier one: skip to _Resuming_ below. Otherwise record the **base branch**: the branch checked out now (`git branch --show-current`). The closing review compares against it.
3. If `git status --porcelain` shows changes outside the feature folder, ask the user whether to commit them first, so they stay out of the feature's commits.
4. Create the **integration branch** from the base branch. Every ticket lands on it. Where it's checked out is the **feature checkout**:
   - If the checkout is clean, or the user committed the changes, check it out here with `git switch -c <feature-slug>`. This checkout is the feature checkout.
   - If the user declined to commit, leave this checkout untouched. Run `git wt add <feature-slug> <base-branch>`, which creates the integration branch in a new worktree and prints its path. That worktree is the feature checkout: run every git command and build every ticket there. The spec and tickets stay in this checkout's feature folder, so refer to them, and update them, by absolute path.

   Then record the base branch on the integration branch, so a resumed run can find it: `git config branch.<feature-slug>.implementBase <base-branch>`.
5. Unless the user chose to skip tests, settle the **agreed seams** for every ticket now, since implementers can't ask the user. Take each ticket's seams from the spec's Testing decisions. For tickets the spec doesn't cover, propose seams and ask the user once, in a single question covering all of them. Done when every ticket has seams the spec or the user agreed.

`git wt` puts a worktree at `~/.worktrees/<group>/<repo>/<name>`, where `<group>/<repo>` is the main checkout's path under `~/Dev`, or `_/<repo>-<hash>` for a repo anywhere else, where `<hash>` is the first 8 characters of `printf '%s' <main-checkout-path> | git hash-object --stdin`. If `git wt` isn't installed, run `git worktree add -b <name> <path> <base>` with that path instead.

### Resuming

An earlier run stopped partway, so the integration branch exists and some tickets may be `in-progress` or `blocked`.

1. Read the base branch from `git config branch.<feature-slug>.implementBase`. If it's unset, ask the user for it.
2. Find the feature checkout in `git worktree list`. If no checkout has `<feature-slug>` checked out, check it out as setup steps 3 and 4 do, with `git switch <feature-slug>` here, or `git wt add <feature-slug>` when the user declines to commit.
3. Settle each `in-progress` ticket. If a commit on the integration branch names it (`git log --grep '^<NN>:' <feature-slug>`), review it as a finished ticket below. If its ticket branch `<feature-slug>-<NN>` exists, finish the ticket there as a parallel ticket. Otherwise set its Status back to `ready`.
4. If any ticket is `blocked`, ask the user about each one now, in one question, as _Blocked tickets_ below does.
5. Settle the agreed seams as setup step 5 does, for every ticket not yet `done`.

Done when no ticket is `in-progress`. Then work the tickets as below.

## Working tickets

The **frontier** of the task graph is every `ready` ticket whose blockers are all `done`. Work the frontier until it's empty, setting each ticket's **Status** to `in-progress` when you start it.

Build each ticket in a foreground **implementer sub-agent** in the feature checkout, one at a time, so each ticket gets a fresh context. Give it the feature checkout's absolute path, to work and commit only there, and absolute paths to the ticket, the spec, and any `DESIGN.md`. The implementer builds the ticket with the tdd skill where possible, at the ticket's agreed seams, which you pass it, runs typechecking and the tests for the files it touched, commits with a message starting `<NN>: <ticket title>`, and reports what it built, or what blocks it, in a few lines. Then review its commit against the ticket, tick the ticket's acceptance criteria, and set its Status to `done`. Without a sub-agent tool, build each ticket yourself the same way.

### Blocked tickets

When an implementer reports a blocker it can't resolve without the user (a missing decision, credential, or service, or a ticket that contradicts the spec or code), set the ticket's Status to `blocked`, add a **Blocker:** line under it saying what's needed, and keep its commits and worktree. A serial ticket's partial work would mix into the next ticket's, so move it to its own ticket branch: in the feature checkout, run `git switch -c <feature-slug>-<NN>`, commit any changes, and run `git switch <feature-slug>`. Keep working the rest of the frontier: the tickets it blocks wait. When the frontier is empty and tickets are still `blocked`, ask the user about all of them in one question. Set each one the user resolves back to `ready`, and work the frontier again.

### Parallel tickets

When the frontier holds two or more **substantial** tickets that touch separate modules, build them in parallel instead, up to 5 at once. Whenever a parallel ticket is merged, recompute the frontier, and start the next substantial ticket that touches a module no running implementer touches, keeping up to 5 running. Start a serial ticket only once no parallel implementer is running. A ticket is substantial when it has 3 or more acceptance criteria. A ticket whose ticket branch `<feature-slug>-<NN>` already exists, from a blocker or an earlier run, is always built as a parallel ticket in that branch's worktree, whatever its size. Without a sub-agent tool, build them yourself in this session, one at a time, as serial tickets.

1. For each, create a worktree from the integration branch tip with `git wt add <feature-slug>-<NN> <feature-slug>`, which prints its path, and start an **implementer sub-agent** in the background, given the worktree path, the ticket's agreed seams, and absolute paths to the ticket, the spec, and any `DESIGN.md`, since the feature folder may not exist in the worktree.
2. Each implementer, working only inside its worktree, builds, tests, and commits the ticket as a serial implementer does, merges the integration branch tip into its branch, fixes any conflict, reruns the tests, commits, and reports done, or what blocks it, in a few lines. You update the ticket file, which lives in the feature folder.
3. When one reports done, squash-merge its branch in the feature checkout, `git merge --squash <feature-slug>-<NN>`, resolve any conflict, and commit it as one commit whose message starts `<NN>: <ticket title>`. Then tick the ticket's acceptance criteria and set its Status to `done`. Remove its worktree (`git wt rm <feature-slug>-<NN>`, or `git worktree remove <path>` if `git wt` isn't installed) and branch (`git branch -D <feature-slug>-<NN>`, since git doesn't count a squashed branch as merged).

Done when every ticket is `done` on the integration branch, or `blocked` with the user's answer to leave it, and the full test suite passes there.

## Closing out

1. Run both reviews, one after the other, each with `<base-branch>...<feature-slug>` as its scope:
   - **The code-review skill**, at the level from _Review level_ below, for bugs.
   - **The code-review-stds-and-spec skill**, with the spec path (plus the ticket files) as its spec source, for conformance. One invocation covers both of its axes.

   Done when you hold the code review's findings and the `## Standards` and `## Spec` reports.
2. Fix the findings you agree with and rerun the tests. Report the integration branch, any ticket left `blocked` with its blocker, and any finding you left, with the reason. If the feature checkout is a worktree, also report its path, and that the user's checkout was left as it was.

### Review level

Size the review to the work. Read the change with `git diff --stat <base-branch>...<feature-slug>` alongside the spec and tickets, and take the highest level whose row matches:

| Level    | The work                            |
| -------- | ----------------------------------- |
| `low`    | Up to 3 tickets, all in one module  |
| `medium` | Anything larger                     |
| `high`   | Any change touching a risky surface |

A **risky surface** is code where a bug is costly or silent: concurrency and shared state, auth and permissions, persistence and migrations, money, public APIs and wire formats.
