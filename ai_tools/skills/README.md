# Skills

Agent skills for Claude Code and Codex: [engineering](./engineering/README.md) and [productivity](./productivity/README.md). `bash ai_tools/setup.sh skills` installs them ([details](../README.md#skills)).

Each skill is a folder with a `SKILL.md` and an `agents/openai.yaml` for Codex. [`EXAMPLES.md`](./EXAMPLES.md) has one example of use per skill.

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
    tickets/<NN>-<ticket-slug>.md   # to-tickets, worked by build
```

`build` makes its worktrees with `git wt` ([Code layout](../../README.md#code-layout)).

## Acknowledgements

Most skills are modified copies from these repos, used under the MIT License. Licenses are in [`THIRD_PARTY_LICENSES`](./THIRD_PARTY_LICENSES) and each copied skill's `LICENSE`.

- [mattpocock/skills](https://github.com/mattpocock/skills) by [Matt Pocock](https://github.com/mattpocock): build (upstream `implement`), diagnose (upstream `diagnosing-bugs`), grill (upstream `grilling`), handoff, research, simpler (upstream `wait-what`), spec-check (upstream `code-review`), tdd, to-spec, to-tickets, walkthrough (upstream `wizard`), and write-agent-docs (upstream `writing-for-agents`)
- [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack) by [poteto](https://x.com/poteto): architect, best-of (upstream `arena`), catch-up (upstream `ketchup`), code-review-council (upstream `interrogate`), decisions (upstream `show-me-your-work`), simpler (upstream `bro`), unslop, why, and write-docs (upstream `technical-writing`)
- [t3dotgg/tstack](https://github.com/t3dotgg/tstack) by [Theo Browne](https://github.com/t3dotgg): code-review-loop and code-review-council-loop (upstream `sol-loop`)

code-review adapts OpenAI Codex's review prompt, used under the Apache License 2.0 (in `THIRD_PARTY_LICENSES`), and Claude Code's `/simplify`. fix-docs is original to this repo.

Thank you, Matt, poteto, and Theo!
