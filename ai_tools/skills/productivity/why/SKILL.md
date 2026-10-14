---
name: why
description: "Answers 'why does X work this way' with cited evidence from git, PRs, and the history MCPs connected in this session."
disable-model-invocation: true
---

# Why

Reading the code answers what it does and how it works. `why` answers what forces led to its shape, which the code cannot tell you.

## Operating posture

Operate as a **precise investigator**. Be honest about what you know vs what you're inferring. Read `references/epistemics.md` for the full confidence framework and phrasing guide. The answer must follow it.

## Step 1. Understand the target and the question

Parse what the user is asking. The **target** is usually a chunk of code, a pattern, a feature, or a named design decision. The **question** is usually a design rationale, a tradeoff, a motivating edge case, an external constraint, dead code, or a broad history sweep.

If the target is vague ("why do we do it this way?" with no clear referent), make your best guess from conversation context (open files, recent edits, cursor location, what was just discussed). State your interpretation briefly so the user can redirect if you're off, then proceed.

## Step 2. Establish the code anchor

Before investigating, anchor the investigation in concrete code. Using the commands in `references/sources/code-archaeology.md`, collect the seed context:

- The relevant file path(s) and line range(s)
- The key symbols (function names, class names, constants)
- An initial commit list: the last few commits touching the target
- PR numbers from merge commits (pattern `(#1234)` in the subject line)
- Ticket IDs mentioned in commit messages and PR bodies

## Step 3. Investigate

### Source control: you

Dig through source control yourself, following `references/sources/code-archaeology.md`: trace the history back past the last commit, and read the PR discussions, linked issues, code comments, and tests. Add `references/sources/incident-postmortem.md` if the target code looks defensive (null checks, retry logic, timeout handling, rate limiting, feature flags, egress guards, OOM handlers).

Skip to Step 4 only when all of these hold: the target came from a single commit, its PR or commit message states the complete answer, nothing in source control contradicts it, and for each other category you can name why searching it would add nothing. This should be rare. Record each category you skip this way in Sources consulted as "skipped: answered by <citation>".

### Other sources: one investigator per MCP

List the MCP servers available in this session and map each to one evidence category. If an MCP fits two categories, use its primary category.

1. **Issue / ticket tracker** (e.g. Linear, Jira). Surfaces *the product or business forcing function*. You already read GitHub issues linked from PRs through `gh`, so GitHub Issues needs no investigator.
2. **Long-form documents** (e.g. Notion, Confluence, Google Docs). Surfaces *design rationale written out before it became code*.
3. **Real-time team chat** (e.g. Slack, Discord, Teams). Surfaces *deliberation that never reached a doc*. Matters most when the paper trail is thin.
4. **Infrastructure observability** (e.g. Datadog, Grafana, Honeycomb). Surfaces *the runtime reality the code reacts to*: timeouts, retries, rate limits, circuit breakers.
5. **Error / exception tracking** (e.g. Sentry, Rollbar). Surfaces *the exceptions that motivated defensive code*: catch blocks, null guards, retries.
6. **Product analytics warehouse** (e.g. Databricks, Snowflake, BigQuery). Surfaces *product and data reality*: flag-gated code, experiments, "where did this number come from".

Start one read-only investigator sub-agent per MCP that could bear on the question, all at once, with your tool access so it can reach its MCP. Each gets `references/investigator-prompt.md`, its category's playbook from `references/source-playbook.md` (adapted to the actual MCP), `references/sources/incident-postmortem.md` when the code looks defensive, the seed context, and the user's question. A category with no MCP, or one that can't bear on the question (error tracking for a build-time script), gets no investigator. Record it, with the reason, for Sources consulted. Without a sub-agent tool, do each investigator's work yourself in this session, one MCP at a time.

Each investigator lists cross-source references under Additional Leads. Chase every lead that points into source control yourself. If a lead points into another MCP's source and bears directly on the question, follow it yourself with that MCP's read-only tools. Record every other lead as a gap in What we don't know.

Done when you hold your source-control evidence, every investigator's findings, and a result or a recorded gap for every lead.

## Step 4. Synthesize

Write the answer yourself from `references/answer-guide.md`, following `references/epistemics.md`: weigh the evidence, surface contradictions, tier every claim, and spot-check any citation you're unsure of before you rely on it. You may add context from the conversation, but every claim keeps its tier.

The tier hedges ("appears to", "likely", "suggests") are required. When you apply the unslop skill to the answer, keep every hedge that marks a claim's tier.

## Output format

The output structure is the one in `references/answer-guide.md`: The question, The code in question, What we found, What we can reasonably infer, Competing hypotheses, What we don't know, Sources consulted, Confidence summary. You may drop the sections the guide marks as skippable and add a section for evidence that fits none of them. Keep the confidence separation intact, and keep Sources consulted as one line per evidence category, including the ones that returned nothing or were skipped, with the reason.

After the Sources consulted block, if the user's `why` question is a precursor to actually changing this code, convert the lineage findings into a Preserve / Change / Avoid / Risk constraint set suitable for planning the change.

## Common failure modes to avoid

- **Recency bias**. Assuming the most recent commit is authoritative. The current shape is often the accretion of many earlier decisions. Trace back.

## Reference files

- `references/epistemics.md`. Confidence tiers and phrasing guide. The answer must follow it.
- `references/investigator-prompt.md`. Base prompt template for investigator subagents.
- `references/source-playbook.md`. Index pointing at the category playbooks below.
- `references/sources/*.md`. One self-contained example playbook per category, plus cross-cutting `incident-postmortem.md`. Give an investigator the single file that matches its category and adapt it to the available MCP.
- `references/answer-guide.md`. How to synthesize the answer, including the output format.
