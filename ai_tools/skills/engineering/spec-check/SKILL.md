---
name: spec-check
description: "Reviews changes against the repo's documented standards and the spec, as two separate reports. Use when the user asks whether a change follows the repo's conventions or implements its spec or tickets."
argument-hint: "[scope] [spec-path]"
---

Review a change, or a set of files, on two questions:

- **Standards**: does the code follow this repo's documented coding standards?
- **Spec**: does the code do what the spec asked?

A change can pass one and fail the other, so keep the two reports separate. For bugs, use the code-review skill: this one judges conformance, not correctness.

## What to review against

Work out the scope with the code-review skill's [`references/scope.md`](../code-review/references/scope.md) (installed beside this skill). A path to a spec or tickets is the spec, not part of the scope.

- **The spec** is the path the user passed. Otherwise it is the feature under `.scratch/<feature-slug>/` that matches the branch or the work: its `SPEC.md`, and its tickets when the change covers only some of them. If you find none, ask the user. If there is none, skip the spec review and say so.
- **The standards** are the rule files, per _Rule files_ in `references/scope.md`, plus files such as `CODING_STANDARDS.md` or `CONTRIBUTING.md`. A documented standard always wins. Where the repo is silent, well-known code smells still count as judgment calls: an unclear name, duplicated logic, a function that mostly uses another object's data, the same switch repeated, an abstraction nothing needs yet. Skip anything tooling already enforces.

## Review

Run the two reviews as parallel read-only sub-agents, each with a fresh context, so neither colors the other. Give each the scope facts and its own sources. Without a sub-agent tool, do the standards review yourself, then the spec review, and keep their notes apart.

- **Standards** reports each place the change breaks a documented standard, citing the rule's `path:line` and quoting it, and each smell it spots. It says which are hard violations and which are judgment calls.
- **Spec** reports what the spec asked for that is missing or partial, what the change does that nobody asked for, and what looks implemented but wrong. It quotes the spec line for each.

## Report

Present the two reports under `## Standards` and `## Spec`, without merging or reranking them. End with one line: the number of findings in each, and the worst in each. Then remove any temp directory the scope made.
