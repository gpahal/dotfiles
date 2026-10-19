---
name: implement
description: "Implements a spec or its tickets in dependency order, then reviews the result."
disable-model-invocation: true
---

Implement the work described by the spec or tickets the user names. They live in the repo under `.scratch/<feature-slug>/`: the spec at `SPEC.md`, the tickets under `tickets/`. If the user names neither, ask which feature to implement. A spec with no tickets is one ticket.

If the feature has a `DESIGN.md` from the `architect` skill, the type sketch it describes is the contract: fill in the `not implemented` bodies rather than inventing a new shape, and surface any deviation the sketch didn't anticipate.

If the code has no tests yet, ask the user which they want: add a test setup first, test only at the spec's seams, or skip tests.

## Setup

1. Record the **base branch**: the branch checked out now (`git branch --show-current`). The closing review compares against it.
2. If `git status --porcelain` shows changes outside `.scratch/`, ask the user whether to commit them first, so they stay out of the feature's commits.
3. Create the **integration branch** from the base branch. Every ticket lands on it. Where it's checked out is the **feature checkout**:
   - If the checkout is clean, or the user committed the changes, check it out here with `git switch -c <feature-slug>`. This checkout is the feature checkout.
   - If the user declined to commit, leave this checkout untouched. Run `git wt add <feature-slug> <base-branch>`, which creates the integration branch in a new worktree and prints its path. That worktree is the feature checkout: run every git command and build every ticket there. The spec and tickets stay in this checkout's `.scratch/`, so refer to them, and update them, by absolute path.
4. Unless the user chose to skip tests, settle the **agreed seams** for every ticket now, since implementers can't ask the user. Take each ticket's seams from the spec's Testing decisions. For tickets the spec doesn't cover, propose seams and ask the user once, in a single question covering all of them. Done when every ticket has seams the spec or the user agreed.

`git wt` puts a worktree at `~/.worktrees/<group>/<repo>/<name>`, where `<group>/<repo>` is the main checkout's path under `~/Dev`, or `_/<repo>-<hash>` for a repo anywhere else, where `<hash>` is the first 8 characters of `printf '%s' <main-checkout-path> | git hash-object --stdin`. If `git wt` isn't installed, run `git worktree add -b <name> <path> <base>` with that path instead.

## Working tickets

The tickets form a **task graph**: each names the tickets that block it. The **frontier** is every `ready` ticket whose blockers are all `done`. Work the frontier until no ticket is left, setting each ticket's **Status** to `in-progress` when you start it.

Build each ticket in a foreground **implementer sub-agent** in the feature checkout, one at a time, so each ticket gets a fresh context. Give it the feature checkout's absolute path, to work and commit only there, and absolute paths to the ticket, the spec, and any `DESIGN.md`. The implementer builds the ticket with the tdd skill where possible, at the ticket's agreed seams, which you pass it, runs typechecking and the tests for the files it touched, commits, and reports what it built, or what blocks it, in a few lines. Then review its commit against the ticket, tick the ticket's acceptance criteria, and set its Status to `done`. Without a sub-agent tool, build each ticket yourself the same way.

### Parallel tickets

When the frontier holds two or more **substantial** tickets that touch separate modules, build them in parallel instead, up to 3 at once. A ticket is substantial when it has 3 or more acceptance criteria. Without a sub-agent tool, build them yourself in this session, one at a time, as serial tickets.

1. For each, create a worktree from the integration branch tip with `git wt add <feature-slug>-<NN> <feature-slug>`, which prints its path, and start an **implementer sub-agent** in the background, given the worktree path, the ticket's agreed seams, and absolute paths to the ticket, the spec, and any `DESIGN.md`, since `.scratch/` may not exist in the worktree.
2. Each implementer, working only inside its worktree, builds, tests, and commits the ticket as a serial implementer does, merges the integration branch tip into its branch, fixes any conflict, reruns the tests, commits, and reports done, or what blocks it, in a few lines. You update the ticket file, which lives in the `.scratch/` the spec is in.
3. When one reports done, squash-merge its branch in the feature checkout, `git merge --squash <feature-slug>-<NN>`, resolve any conflict, and commit it as one commit named for the ticket. Then tick the ticket's acceptance criteria and set its Status to `done`. Remove its worktree (`git wt rm <feature-slug>-<NN>`, or `git worktree remove <path>` if `git wt` isn't installed) and branch (`git branch -D <feature-slug>-<NN>`, since git doesn't count a squashed branch as merged).

Done when every ticket is `done` on the integration branch and the full test suite passes there.

## Closing out

1. Run both reviews, one after the other, each with `<base-branch>...<feature-slug>` as its scope:
   - **The code-review skill**, at the level from _Review level_ below, for bugs.
   - **The code-review-stds-and-spec skill**, with the spec path (plus the ticket files) as its spec source, for conformance. One invocation covers both of its axes.

   Done when you hold the code review's findings and the `## Standards` and `## Spec` reports.
2. Fix the findings you agree with and rerun the tests. Report the integration branch, and any finding you left, with the reason. If the feature checkout is a worktree, also report its path, and that the user's checkout was left as it was.

### Review level

Size the review to the work. Read the change with `git diff --stat <base-branch>...<feature-slug>` alongside the spec and tickets, and take the highest level whose row matches:

| Level    | The work                            |
| -------- | ----------------------------------- |
| `low`    | Up to 3 tickets, all in one module  |
| `medium` | Anything larger                     |
| `high`   | Any change touching a risky surface |

A **risky surface** is code where a bug is costly or silent: concurrency and shared state, auth and permissions, persistence and migrations, money, public APIs and wire formats.
