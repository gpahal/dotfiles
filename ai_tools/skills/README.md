# Skills

Agent skills for Claude Code and Codex: [engineering](./engineering/README.md) and [productivity](./productivity/README.md). `bash ai_tools/setup.sh skills` installs them ([details](../README.md#skills)).

Each skill is a folder with a `SKILL.md` and an `agents/openai.yaml` for Codex.

## Scratch files

Skills that write documents put them in `.scratch/` at the repo root, which the global gitignore ignores. Add `!.scratch/` to a repo's `.gitignore` to commit it.

```
.scratch/
  research/<research-slug>.md       # research
  handoffs/<conversation-slug>.md   # handoff
  <feature-slug>/
    SPEC.md                         # to-spec
    DESIGN.md                       # architect
    design/candidates/<n>/          # architect
    tickets/<NN>-<ticket-slug>.md   # to-tickets, worked by implement
```

`implement` makes its worktrees with `git wt` ([Code layout](../../AGENTS.md#code-layout)).

## Acknowledgements

Most skills are modified copies from these repos, used under the MIT License. Licenses are in [`THIRD_PARTY_LICENSES`](./THIRD_PARTY_LICENSES) and each copied skill's `LICENSE`.

- [mattpocock/skills](https://github.com/mattpocock/skills) by [Matt Pocock](https://github.com/mattpocock): code-review-stds-and-spec (upstream `code-review`), diagnosing-bugs, grill (upstream `grilling`), handoff, implement, research, tdd, to-spec, to-tickets, wait-what, wizard, and writing-for-agents
- [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack) by [poteto](https://x.com/poteto): architect, bro, interrogate, show-me-your-work, technical-writing, unslop, and why

code-review adapts OpenAI Codex's review prompt and Claude Code's `/simplify`. rewrite-docs is original to this repo.

Thank you, Matt and poteto!
