# Engineering

Skills for code work. Documents they produce go under `.scratch/` in the repo; see
[Scratch files](../README.md#scratch-files) for the layout.

The review skills (code-review, code-review-stds-and-spec, and interrogate) and rewrite-docs share one way to say what to work on, in [`code-review/references/scope.md`](./code-review/references/scope.md): nothing for the current branch's work, `uncommitted`, `staged`, a PR, a commit, a range, a ref to review since, paths, `all` for the whole repo, or a diff form limited to paths.

## User-invoked

Reachable only when you type them (Claude Code: `disable-model-invocation: true`; Codex: `policy.allow_implicit_invocation: false` in `agents/openai.yaml`). The first four form the feature workflow: spec, then (optionally) design, then tickets, then implementation.

- **[to-spec](./to-spec/SKILL.md)**: Turn the current conversation into a spec, no interview, and save it at `.scratch/<feature-slug>/SPEC.md`.
- **[architect](./architect/SKILL.md)**: Sketch types, signatures, and module boundaries before code: ground in the existing system, have parallel sub-agents draw at least two distinct candidates, synthesize one into `.scratch/<feature-slug>/DESIGN.md`, then implement against it and scrap it if it fights back.
- **[to-tickets](./to-tickets/SKILL.md)**: Break a plan, spec, or conversation into tracer-bullet tickets, each declaring what blocks it, saved one per file under `.scratch/<feature-slug>/tickets/`.
- **[implement](./implement/SKILL.md)**: Build the work described by a spec or its tickets: parallel implementer sub-agents, one per unblocked ticket, each in its own worktree using the tdd skill at pre-agreed seams, merged into an integration branch, then closed out with the code-review skill, at a level sized to the work's complexity, and the code-review-stds-and-spec skill.
- **[rewrite-docs](./rewrite-docs/SKILL.md)**: Audit every doc, agent instruction file (`AGENTS.md`, `CLAUDE.md`), and code comment in scope against the code, then fix what's stale, wrong, conflicting, missing, or bloated, to the technical-writing, writing-for-agents, and unslop rules. Small fixes are applied; big ones (deleting, adding, restructuring, or changing what agents are told) are asked about first. A doc that disagrees with code that may be wrong is reported as a possible bug.
- **[interrogate](./interrogate/SKILL.md)**: Adversarial review by two model families: a Claude reviewer and a Codex reviewer (models set in one table in its `SKILL.md`, effort per run, `medium` by default) review the same change with the same prompt, each through its tool's CLI, read-only, then the lead judges their findings into Act on, Consider, Noted, and Dismissed, with a map of where the models agreed. Runs from either Claude Code or Codex.

## Model-invoked

Model- or user-reachable (rich trigger phrasing so the model can reach for them).

- **[research](./research/SKILL.md)**: When you ask for research, investigate a question against primary sources in a background agent and save the cited answer, findings, and open questions at `.scratch/research/<research-slug>.md`.
- **[tdd](./tdd/SKILL.md)**: Test-driven development with a red → green loop. Builds features or fixes bugs one vertical slice at a time, and leaves refactoring to code review.
- **[code-review](./code-review/SKILL.md)**: Bug review at a level from `low` to `max`, optionally narrowed with `--focus` (such as `security`, `docs`, or `tests`): finder sub-agents look at the change from separate angles (line by line, removed behavior, callers, language pitfalls, wrappers and proxies, security, reuse, simplification, efficiency, altitude, the repo's rules, stale docs and comments, and tests), a verifier sub-agent tries to disprove each candidate, and the survivors are reported as P0 to P3 findings with a verdict. Can apply fixes (`--fix`) or post PR comments (`--comment`). Replaces Claude Code's built-in `/code-review`.
- **[code-review-stds-and-spec](./code-review-stds-and-spec/SKILL.md)**: Two-axis review of a change: **Standards** (does it follow the repo's coding standards, plus a Fowler smell baseline?) and **Spec** (does it faithfully implement the spec?), run as parallel sub-agents.
- **[diagnosing-bugs](./diagnosing-bugs/SKILL.md)**: Disciplined diagnosis loop for hard bugs and performance regressions: build a feedback loop that goes red on this bug → minimise → hypothesise → instrument → fix → regression-test.
- **[wizard](./wizard/SKILL.md)**: Generate an interactive bash wizard that walks a human through steps only they can perform: provisioning infrastructure, setting up credentials or CI secrets, walking an unfamiliar third-party dashboard, or running a one-off migration or cutover.
