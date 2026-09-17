# Engineering

Skills for code work. Documents they produce go under `.scratch/` in the repo; see
[Scratch files](../README.md#scratch-files) for the layout.

## User-invoked

Reachable only when you type them (Claude Code: `disable-model-invocation: true`; Codex: `policy.allow_implicit_invocation: false` in `agents/openai.yaml`). Together they form the feature workflow: spec, then (optionally) design, then tickets, then implementation.

- **[to-spec](./to-spec/SKILL.md)**: Turn the current conversation into a spec, no interview, and save it at `.scratch/<feature-slug>/SPEC.md`.
- **[architect](./architect/SKILL.md)**: Sketch types, signatures, and module boundaries before code: ground in the existing system, have parallel sub-agents draw at least two distinct candidates, synthesize one into `.scratch/<feature-slug>/DESIGN.md`, then implement against it and scrap it if it fights back.
- **[to-tickets](./to-tickets/SKILL.md)**: Break a plan, spec, or conversation into tracer-bullet tickets, each declaring what blocks it, saved one per file under `.scratch/<feature-slug>/tickets/`.
- **[implement](./implement/SKILL.md)**: Build the work described by a spec or its tickets, working the unblocked tickets first, driving `/tdd` at pre-agreed seams and closing out with parallel code reviews sized to the work's complexity.

## Model-invoked

Model- or user-reachable (rich trigger phrasing so the model can reach for them).

- **[research](./research/SKILL.md)**: Investigate a question against high-trust primary sources in a background agent and save the cited findings at `.scratch/research/<research-slug>.md`.
- **[tdd](./tdd/SKILL.md)**: Test-driven development with a red-green-refactor loop. Builds features or fixes bugs one vertical slice at a time.
- **[code-review-stds-and-spec](./code-review-stds-and-spec/SKILL.md)**: Two-axis review of the diff since a fixed point: **Standards** (does it follow the repo's coding standards, plus a Fowler smell baseline?) and **Spec** (does it faithfully implement the spec?), run as parallel sub-agents.
- **[diagnosing-bugs](./diagnosing-bugs/SKILL.md)**: Disciplined diagnosis loop for hard bugs and performance regressions: build a feedback loop that goes red on this bug → minimise → hypothesise → instrument → fix → regression-test.
- **[resolving-merge-conflicts](./resolving-merge-conflicts/SKILL.md)**: Work through an in-progress git merge or rebase conflict hunk by hunk, resolving by intent traced to each side's primary source, then finish the operation, never `--abort`.
- **[wizard](./wizard/SKILL.md)**: Generate an interactive bash wizard that walks a human through steps only they can perform: provisioning infrastructure, setting up credentials or CI secrets, walking an unfamiliar third-party dashboard, or running a one-off migration or cutover.
