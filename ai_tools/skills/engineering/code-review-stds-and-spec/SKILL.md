---
name: code-review-stds-and-spec
description: "Reviews changes against the repo's documented standards and the spec, as two separate reports. Use when the user asks whether a change follows the repo's conventions or implements its spec or tickets."
argument-hint: "[scope] [spec-path]"
---

Two-axis review of a change, or of a set of files:

- **Standards**: does the code conform to this repo's documented coding standards?
- **Spec**: does the code faithfully implement the spec?

Both axes run as **parallel sub-agents** so they don't pollute each other's context, then this skill aggregates their findings. One invocation of this skill is the whole review: the caller runs it once, and this skill owns the dispatch of both sub-agents. Each sub-agent receives only its axis brief from step 4. For bugs, use the code-review skill: this one judges conformance, not correctness.

## Process

### 1. Resolve the scope

Follow the code-review skill's [`references/scope.md`](../code-review/references/scope.md) (installed beside this skill). Whatever the user said is the scope: a ref to review since ("review since X"), a PR, a commit, paths, or nothing for the branch's work. A path to a spec or tickets is the spec source for step 2, not part of the scope. Done when you've printed the scope line and filled in the scope packet.

### 2. Identify the spec source

Look for the originating spec, in this order:

1. A path the user passed as an argument: a spec, a tickets directory, or any other document.
2. A feature under `.scratch/<feature-slug>/` in the repo matching the branch name or the feature: its `SPEC.md`, plus the ticket files under `tickets/` if the change is scoped to some of them.
3. If nothing is found, ask the user where the spec is. If they say there isn't one, the **Spec** sub-agent will skip and report "no spec available".

### 3. Identify the standards sources

Anything in the repo that documents how code should be written: `AGENTS.md` and `CLAUDE.md` at the root and in each directory above a file in scope, plus files such as `CODING_STANDARDS.md` or `CONTRIBUTING.md`.

On top of whatever the repo documents, the Standards axis always carries the **smell baseline** below: a fixed set of Fowler code smells (_Refactoring_, ch.3) that applies even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell.
- **Always a judgement call.** Each smell is a labelled heuristic ("possible Feature Envy"), never a hard violation. Like any standard here, skip anything tooling already enforces.

Each smell reads *what it is* → *how to fix*; match it against the change:

- **Mysterious Name**: a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code**: the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy**: a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps**: the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession**: a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches**: the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery**: one logical change forces scattered edits across many files in the change. → gather what changes together into one module.
- **Divergent Change**: one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality**: abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Message Chains**: long `a.b().c().d()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object.
- **Middle Man**: a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest**: a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.

### 4. Spawn both sub-agents in parallel

**Standards sub-agent prompt** should include:

- The scope packet.
- The list of standards-source files you found in step 3, **plus the smell baseline from step 3** pasted in full (the sub-agent has no other access to it).
- The brief: "Report, per `path:line` where relevant, (a) every place the change violates a documented standard: cite the standard by `path:line-range` and quote the rule; and (b) any baseline smell you spot: name it and quote the hunk. Distinguish hard violations from judgement calls: documented-standard breaches can be hard, but baseline smells are always judgement calls, and a documented repo standard overrides the baseline. Skip anything tooling enforces. Under 400 words."

**Spec sub-agent prompt** should include:

- The scope packet.
- The path or fetched contents of the spec.
- The brief: "Report: (a) requirements the spec asked for that are missing or partial; (b) behaviour in the change that wasn't asked for (scope creep); (c) requirements that look implemented but where the implementation looks wrong. Quote the spec line for each finding. Under 400 words."

If the spec is missing, skip the Spec sub-agent and note this in the final report.

### 5. Aggregate

Present the two reports under `## Standards` and `## Spec` headings, verbatim or lightly cleaned. Do **not** merge or rerank findings, because the two axes are deliberately separate (see _Why two axes_).

End with a one-line summary: total findings per axis, and the worst issue _within each axis_ (if any). Don't pick a single winner across axes: that's the reranking the separation exists to prevent.

## Why two axes

A change can pass one axis and fail the other:

- Code that follows every standard but implements the wrong thing → **Standards pass, Spec fail.**
- Code that does exactly what the spec asked but breaks the project's conventions → **Spec pass, Standards fail.**

Reporting them separately stops one axis from masking the other.
