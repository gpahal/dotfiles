# Productivity

General workflow tools, not code-specific.

## User-invoked

Reachable only when you type them (Claude Code: `disable-model-invocation: true`; Codex: `policy.allow_implicit_invocation: false` in `agents/openai.yaml`).

- **[bro](./bro/SKILL.md)**: Restate the last message in plain, everyday words, shorter and with no jargon. Use it when a message is too dense; use wait-what when it lacks context.
- **[handoff](./handoff/SKILL.md)**: Compact the current conversation into a handoff document at `.scratch/handoffs/<conversation-slug>.md` so another agent can continue the work.
- **[show-me-your-work](./show-me-your-work/SKILL.md)**: Reply with a numbered list of the decisions behind the work so far, each with its phase, reason, evidence, and result, audited against what happened, plus an Attention section on the items to check. `--check` adds a scan by a reviewer from the other model family. Writes no log file.
- **[technical-writing](./technical-writing/SKILL.md)**: Write or review docs, readmes, RFCs, PR descriptions, and commit messages to a layered standard: Diátaxis structure, Google developer style sentences, STE instruction rules, Global English syntax. Leaves word- and sentence-level rules to `unslop`, which it applies to everything it touches.
- **[why](./why/SKILL.md)**: Answer "why does X work this way" with cited evidence: spawns one investigator per available history source (git, issue tracker, docs, chat, observability, error tracking, analytics), then a synthesizer that separates what's known from what's inferred.
- **[wait-what](./wait-what/SKILL.md)**: Fire this the moment a message doesn't land. The agent re-pitches it with the context you're missing, in ASD-STE100 Simplified Technical English, using the project's vocabulary from `AGENTS.md` or `CLAUDE.md`.

## Model-invoked

Model- or user-reachable (rich trigger phrasing so the model can reach for them).

- **[grill](./grill/SKILL.md)**: Interview the user relentlessly about a plan, decision, or idea until every branch of the design tree is resolved.
- **[unslop](./unslop/SKILL.md)**: Cut AI tells from any writing: AI vocabulary, filler, hedging, em dashes, inline-header lists, chatbot phrases, mannered prose. Its rules are numbered so other skills can cite them.
- **[writing-for-agents](./writing-for-agents/SKILL.md)**: Writing documents for agents: skills, AGENTS.md/CLAUDE.md, and any doc an agent reaches by a pointer.
