---
name: architect
description: "Sketch types, signatures, and module structure before code, then stay in the loop while implementation fills in. Use for non-trivial work where jumping to code would lock in the wrong shape."
disable-model-invocation: true
---

# Architect

Design before implementing. Sketch types, function signatures, class shapes, and module boundaries with `not implemented` bodies and pseudocode. Have several independent candidates drawn up, synthesize one, then fill in code against the chosen sketch. If implementation proves the sketch wrong, throw it out and redesign.

Design files live beside the feature's spec and tickets under `.scratch/<feature-slug>/`: candidates under `design/candidates/<n>/`, the synthesized rationale at `DESIGN.md`. Reuse the slug of an existing `SPEC.md` if there is one; otherwise choose a slug that names the feature. The type sketch itself goes into the codebase.

## Start

Track the five phases as todos before starting.

1. Ground
2. Sketch
3. Agree
4. Implement
5. Scrap

## Phase A: Ground the problem

Build a real mental model of every system the new code touches. Trace the relevant subsystems: entry points, the data flow through them, which module owns which state, and the invariants each boundary protects. Write that traced model down as a grounding artifact for Phase B.

Naming a file isn't grounding. If the design redefines ownership or layering, also run the **why** skill on the existing shape so the rationale becomes a constraint, not a guess.

Skip Phase A only when the work is genuinely greenfield with no surrounding system to integrate.

## Phase B: Sketch

Spawn parallel sub-agents, one per candidate, each given the design task, the Phase A grounding artifacts, [`references/runner-prompt.md`](references/runner-prompt.md) as its prompt, and its own output directory under `.scratch/<feature-slug>/design/candidates/<n>/`. Each candidate produces a design package shaped per [`references/rationale-template.md`](references/rationale-template.md).

Design it twice. Require at least two structurally distinct candidates before synthesis, even when the first looks sufficient. Whole-shape alternatives, not point fixes inside one shape.

Screen every candidate against [`references/design-red-flags.md`](references/design-red-flags.md) before synthesis. Reject or revise shallow modules, information leakage, temporal decomposition, and pass-through methods.

Compare viable candidates on interface depth. Prefer the design that hides more complexity behind a smaller, simpler public surface. A rich interface can keep call chains short by concentrating capability instead of scattering it across layers.

Synthesize one design package: pick the candidate with the best shape as the base, graft what the others did better, and record what was rejected and why. That decision populates the rationale's "Synthesis decision" section. Save the synthesized package as `.scratch/<feature-slug>/DESIGN.md`.

## Phase C: Agree (opt-in)

Default: proceed directly to implementation with the synthesized design. No human checkpoint.

Opt in to a checkpoint when the invoker explicitly asks: "/architect with checkpoint," "stop and show me before implementing," or similar. Then surface the synthesized design and pause for sign-off.

The sketch can ship as its own commit either way: types, signatures, and `not implemented` bodies first, with planned and scoped breakage during fill-in. For adversarial pressure on the design before implementing, run the **grill** skill on the synthesized sketch.

If the human pushes back on the shape (in a checkpoint or after the fact), treat that as Phase A evidence. Re-ground and re-run Phase B before writing more code.

## Phase D: Implement against the sketch

Replace `not implemented` bodies with code, pseudocode with logic. The synthesized sketch is the contract. When the feature has tickets, the **implement** skill does this phase ticket by ticket.

Deviations from the sketch are signal worth surfacing, not friction to absorb silently. If a function needs a parameter the sketch didn't anticipate, ask whether the sketch was wrong, the requirement was missed, or the implementation is overreaching.

## Phase E: Scrap when the architecture is wrong

If implementation keeps producing friction the sketch can't absorb, throw the sketch out. Don't bolt fixes onto a wrong design; fix the root cause.

The signal is a *pattern*, not single instances. Tells:

- The same shape of workaround appearing repeatedly across unrelated code.
- Multiple unrelated edge cases that all need special-case branches.
- Types that need escape hatches (`any`, casts, optional fields always set in practice) to compile.
- The "we need a lock" reflex when the sketch said the state wasn't shared.
- Callers having to know the abstraction's internal rules to use it.
- Two or more independent Phase D deviations of the same shape across the implementation.

Use judgment. A few edge cases don't condemn an architecture. Some problems are legitimately complex. Complexity in the data is not complexity in the design.

When you scrap:

1. Re-run Phase A over what's been built.
2. Redesign as if the new constraints had been day-one assumptions.
3. Subtract before adding. The new sketch should be smaller than the old one before it grows.
4. Return to Phase B with fresh candidates.

## Outputs

The caller's usage is written first and the type sketch derived from it. One file with new types and signatures for small changes. Module map plus type definitions for larger work. The rationale ships alongside as `.scratch/<feature-slug>/DESIGN.md`, shaped per `references/rationale-template.md`, including the usage sketch and the synthesis decision.
