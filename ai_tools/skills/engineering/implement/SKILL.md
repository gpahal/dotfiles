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

1. Commit your work to the current branch. The review reads `git diff <base>...HEAD`, so uncommitted work is invisible to it.
2. Invoke `/code-review-stds-and-spec` **once**, yourself, in this context, with two arguments: the base commit as its fixed point, and the spec path (plus the ticket files you worked) as its spec source. That single invocation covers both axes: the skill spawns its own Standards and Spec sub-agents and returns both reports. Done when you hold its `## Standards` and `## Spec` report.
3. If the tool has a built-in review command (Claude Code `/code-review`, Codex `/review`), run that too.
4. Fix the findings you agree with, rerun the tests, and commit the fixes.
