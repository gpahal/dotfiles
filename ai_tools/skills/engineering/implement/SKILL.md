---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the spec or tickets the user names. They live in the repo under `.scratch/<feature-slug>/`: the spec at `SPEC.md`, the tickets under `tickets/`. If the user names neither, ask which feature to implement.

If the feature has a `DESIGN.md` from the `architect` skill, the type sketch it describes is the contract: fill in the `not implemented` bodies rather than inventing a new shape, and surface any deviation the sketch didn't anticipate.

## Working tickets

Work the **frontier**: any ticket whose "Blocked by" tickets are all `done`, lowest number first. Before starting a ticket set its **Status** to `in-progress`; when its acceptance criteria all pass, tick them and set it to `done`. One ticket at a time, so the ticket files always show where the work stands.

## Building

Use /tdd where possible, at the seams the spec agreed. If the code doesn't already have any tests, confirm with the user what they want to do and present them relevant options on testing.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

## Closing out

Once done, review the work with `/code-review-stds-and-spec`, passing the spec path (or the ticket files) as its spec source. If the tool has a built-in review command (Claude Code `/code-review`, Codex `/review`), run that too.

Commit your work to the current branch.
