---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the spec or tickets the user names. They live in the repo under `.scratch/<feature-slug>/`: the spec at `SPEC.md`, the tickets under `tickets/`. If the user names neither, ask which feature to implement.

Before touching any code, record the **base commit**: `git rev-parse HEAD`. The closing review diffs against it.

If the feature has a `DESIGN.md` from the `architect` skill, the type sketch it describes is the contract: fill in the `not implemented` bodies rather than inventing a new shape, and surface any deviation the sketch didn't anticipate.

## Working tickets

Work the **frontier**: any ticket whose "Blocked by" tickets are all `done`, lowest number first. Before starting a ticket set its **Status** to `in-progress`; when its acceptance criteria all pass, tick them and set it to `done`. One ticket at a time, so the ticket files always show where the work stands.

## Building

Use /tdd where possible, at the seams the spec agreed. If the code doesn't already have any tests, confirm with the user what they want to do and present them relevant options on testing.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

## Closing out

1. Commit your work to the current branch. Both reviews read `git diff <base>...HEAD`, so uncommitted work is invisible to them.
2. Pick the built-in review's effort from the work's complexity, per _Review effort_ below.
3. Run both reviews **in parallel**, each scoped to the base commit:
   - **Built-in review**, launched first so it runs in the background:
     - Claude Code: `/code-review <effort> <base>...HEAD`. It runs as a background sub-agent and its findings arrive when it finishes.
     - Codex: `codex exec review -c model_reasoning_effort=<effort> -o <file> "Review the changes in git diff <base>...HEAD"` as a background shell command, reading `<file>` when it exits.
   - **`/code-review-stds-and-spec`**, invoked **once**, yourself, in this context while the built-in review runs, with two arguments: the base commit as its fixed point, and the spec path (plus the ticket files you worked) as its spec source. That single invocation covers both axes: the skill spawns its own Standards and Spec sub-agents and returns both reports.

   Done when you hold all three reports: the built-in review's findings, and `/code-review-stds-and-spec`'s `## Standards` and `## Spec`. A tool with no built-in review runs `/code-review-stds-and-spec` alone.
4. Fix the findings you agree with, rerun the tests, and commit the fixes.

### Review effort

Size the review to the work. Read the change with `git diff --stat <base>...HEAD` alongside the spec and tickets, and take the highest row that matches. `high` is the ceiling, so never pass `xhigh` or `max`:

| Effort   | The work                                                                   |
| -------- | -------------------------------------------------------------------------- |
| `low`    | Up to a few tickets, or a change contained in one module                   |
| `medium` | Several tickets, a change across modules, or a shape set by `DESIGN.md`    |
| `high`   | A large change across many modules, or any change touching a risky surface |

A **risky surface** is code where a bug is costly or silent: concurrency and shared state, auth and permissions, persistence and migrations, money, public APIs and wire formats.

When the work touches several risky surfaces, or threads one through a large change, also tell the user they can run `/code-review ultra`, Claude Code's billed cloud review, which only they can launch.
