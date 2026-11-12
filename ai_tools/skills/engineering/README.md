# Engineering

Skills for code work. The review skills and fix-docs share one scope syntax: [`code-review/references/scope.md`](./code-review/references/scope.md).

## User-invoked

Only when you type them. The first four are the feature workflow.

- **[to-spec](./to-spec/SKILL.md)**: Turn the conversation into `.scratch/<feature-slug>/SPEC.md`.
- **[architect](./architect/SKILL.md)**: Design types and module boundaries from two candidates into `DESIGN.md`, then implement against it.
- **[to-tickets](./to-tickets/SKILL.md)**: Break a plan or spec into tracer-bullet tickets with blockers.
- **[build](./build/SKILL.md)**: Build a spec's tickets in dependency order with sub-agents, then review.
- **[fix-docs](./fix-docs/SKILL.md)**: Make docs, agent files, and comments true to the code and terse.
- **[code-review-council](./code-review-council/SKILL.md)**: Independent review by a Claude and a Codex model, judged by the lead.
- **[code-review-loop](./code-review-loop/SKILL.md)**: Review by the other model family, fix, and repeat until both agree.
- **[code-review-council-loop](./code-review-council-loop/SKILL.md)**: The same loop with every council model as a reviewer.
- **[best-of](./best-of/SKILL.md)**: Run several attempts at one task and keep the best parts.

## Model-invoked

When you type them, or when the model reaches for them.

- **[research](./research/SKILL.md)**: Answer a question from primary sources into `.scratch/research/`.
- **[tdd](./tdd/SKILL.md)**: Red-green test-driven development, one slice at a time.
- **[code-review](./code-review/SKILL.md)**: Bug review with checked, ranked findings, and a `deep` mode. Replaces Claude Code's `/code-review`.
- **[spec-check](./spec-check/SKILL.md)**: Review a change against the repo's standards and the spec.
- **[diagnose](./diagnose/SKILL.md)**: Diagnosis loop for hard bugs and performance regressions.
- **[walkthrough](./walkthrough/SKILL.md)**: Generate a bash wizard for steps only a human can do.
