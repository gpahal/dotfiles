# Engineering

Skills for code work. The review skills and rewrite-docs share one scope syntax: [`code-review/references/scope.md`](./code-review/references/scope.md).

## User-invoked

Only when you type them. The first four are the feature workflow.

- **[to-spec](./to-spec/SKILL.md)**: Turn the conversation into `.scratch/<feature-slug>/SPEC.md`.
- **[architect](./architect/SKILL.md)**: Design types and module boundaries from two candidates into `DESIGN.md`, then implement against it.
- **[to-tickets](./to-tickets/SKILL.md)**: Break a plan or spec into tracer-bullet tickets with blockers.
- **[implement](./implement/SKILL.md)**: Build a spec's tickets in dependency order with sub-agents, then review.
- **[rewrite-docs](./rewrite-docs/SKILL.md)**: Make docs, agent files, and comments true to the code and terse.
- **[interrogate](./interrogate/SKILL.md)**: Adversarial review by a Claude and a Codex reviewer, judged by the lead.

## Model-invoked

When you type them, or when the model reaches for them.

- **[research](./research/SKILL.md)**: Answer a question from primary sources into `.scratch/research/`.
- **[tdd](./tdd/SKILL.md)**: Red-green test-driven development, one slice at a time.
- **[code-review](./code-review/SKILL.md)**: Bug review from `low` to `max`, with verified, ranked findings. Replaces Claude Code's `/code-review`.
- **[code-review-stds-and-spec](./code-review-stds-and-spec/SKILL.md)**: Review a change against the repo's standards and the spec.
- **[diagnosing-bugs](./diagnosing-bugs/SKILL.md)**: Diagnosis loop for hard bugs and performance regressions.
- **[wizard](./wizard/SKILL.md)**: Generate a bash wizard for steps only a human can do.
