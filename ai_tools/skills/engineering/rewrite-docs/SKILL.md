---
name: rewrite-docs
description: "Brings a repo's docs, agent instructions, and code comments up to date with the code and cuts them down, asking before any big change."
disable-model-invocation: true
argument-hint: "[scope]"
---

# Rewrite docs

Make every doc, agent instruction file, and code comment in scope true to the code as it is now, complete where a reader needs it, and terse. The code is the source of truth. A doc is a set of claims about it, and each claim gets checked.

## 1. Resolve the scope

Follow the code-review skill's [`references/scope.md`](../code-review/references/scope.md) (installed beside this skill), with one change: with no scope given, the scope is `all`. A diff scope ("since main", a PR) narrows the work to the docs and comments that the change made stale, wherever they live.

Done when you've printed the scope line.

## 2. Inventory

List what's in scope, in three groups:

- **Docs**: `README*`, everything under `docs/`, and the other Markdown and text docs: `CONTRIBUTING`, guides, examples, help text, and doc comments that publish as API docs.
- **Agent files**: every `AGENTS.md`, `CLAUDE.md`, and similar file read by agents, such as `.cursor/rules/` and `.github/copilot-instructions.md`.
- **Comments**: the comments in tracked source files.

Leave out files nobody should hand-edit: past changelog entries, licenses, vendored and third-party copies, and generated docs (regenerate those with their own command instead). List what you left out.

Done when every file in scope is in a group or on the left-out list.

## 3. Audit

Check every claim against the code, config, scripts, `--help` output, and the recent `git log`. For a large inventory, split it into groups of related files and audit them with parallel sub-agents, each told to edit nothing and to return its findings. Each finding is one of:

- **Stale**: true once, false now, such as a renamed flag, a changed default, or a removed step.
- **Wrong**: never true, or a command that fails.
- **Conflict**: two docs disagree, or a doc disagrees with the code.
- **Missing**: behavior a reader needs that no doc covers, where the repo documents comparable behavior.
- **Bloat**: words that do no work: restated context, a comment that repeats the code, hedging, preamble, and duplication of another doc or the environment (link it or drop it).

Each finding names its `path:line`, the evidence (the code line, the command and its output), and the fix.

Done when every file in the inventory has been audited, and each finding has its evidence.

## 4. Sort small from big

Decide each finding's size by what it would change for a reader:

- **Small**: the fix leaves the doc saying what its author meant, only true and shorter. Fixing a stale fact, a broken command or link, a renamed symbol, cutting bloat, and deleting a comment that repeats the code or a finished TODO are all small. Apply these.
- **Big**: the fix changes what the doc says, or its shape. Deleting a section or a file, adding a doc or a section, moving or splitting docs, rewriting most of a file, and changing what an agent file tells agents to do are all big. Ask first.

A conflict between a doc and the code is big when the code might be the one that's wrong. Report it as a possible bug, and change neither until the user decides.

Ask about the big ones in one round, numbered, each with what you'd change, why, and your recommendation. Apply the ones the user approves. When unsure of a finding's size, treat it as big.

Done when every small fix is applied and every big one is approved, declined, or still waiting on the user.

## 5. Rewrite

- **Docs** follow the technical-writing skill, read from `../technical-writing/SKILL.md` (installed beside this skill).
- **Agent files** follow the writing-for-agents skill. Prune no-ops, stale lines, and caches of what the environment already says.
- **Comments** explain what the code can't show, such as why it's written this way or a constraint it works around. Delete the rest, and keep each one to a line where you can.
- **All prose** goes through the unslop skill.

Use the code's names for things, and call each thing by one name across all the docs. Match the repo's formatter.

## 6. Verify

- Every relative link and anchor resolves.
- Every symbol, path, flag, and command the docs name exists. Run read-only commands such as `--help` to confirm them.
- The formatter, linter, and build still pass, since an edit to a comment can break code.

Done when all three pass.

## Report

- **Changed**: each file, with one line on what changed.
- **Asked**: each big change, and whether it was approved, declined, or still waiting.
- **Possible bugs**: each place where the code, not the doc, looks wrong.
- **Left out**: the files you didn't touch, and why.

Leave the changes uncommitted.
