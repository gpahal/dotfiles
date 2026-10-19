# Skills

Agent skills for Claude Code and Codex, grouped by category:

- [engineering](./engineering/README.md): skills for code work
- [productivity](./productivity/README.md): general workflow tools, not code-specific

## Installation

`bash ai_tools/setup.sh skills` installs every skill globally for Claude Code and Codex. When
`CLAUDE_CONFIG_DIR` points anywhere but `~/.claude`, it installs them for Codex only. Re-run it
after changing a skill. See
[ai_tools/README.md](../README.md#skills) for details.

## Scratch files

Skills that produce documents write them to a `.scratch/` directory at the root of the repo
you're working in. There's no per-repo setup and no issue tracker: the files are the system.

```
.scratch/
  research/<research-slug>.md       # research
  handoffs/<conversation-slug>.md   # handoff
  <feature-slug>/
    SPEC.md                         # to-spec
    DESIGN.md                       # architect (synthesized design and rationale)
    design/candidates/<n>/          # architect (independent candidate sketches)
    tickets/<NN>-<ticket-slug>.md   # to-tickets, worked by implement
```

A feature is a folder named by its slug. `to-spec` creates it, `architect` and `to-tickets`
reuse the slug so the design and tickets sit beside the spec, and `implement` works the
tickets in dependency order, updating each ticket's `Status` from `ready` to `in-progress` to
`done`. `code-review-stds-and-spec` reads the spec from the same place. The global gitignore
from this repo's `git/ignore` ignores `.scratch/`; to commit it in a repo, add `!.scratch/` to
that repo's `.gitignore`. The skills work either way.

`implement` keeps its worktrees outside the repo, under `~/.worktrees/<group>/<repo>/`: one per
parallel ticket, removed when merged, and one for the integration branch when the checkout has
changes you don't want committed. See [Code layout](../../README.md#code-layout).

## Layout of a skill

Each skill is a folder with a `SKILL.md` (the instructions, with frontmatter for Claude Code)
and an `agents/openai.yaml` (Codex display name, short description, and whether Codex may
invoke the skill on its own). Some skills carry extra reference files or scripts beside
`SKILL.md`.

## Acknowledgements

Most of these skills are modified copies of skills from these repos. Their licenses are in
[`THIRD_PARTY_LICENSES`](./THIRD_PARTY_LICENSES), and each copied skill carries its source's
notice in its own `LICENSE`, so the notice installs with it. `scripts/check-skills.sh` checks that
every skill listed here has that `LICENSE`.

- [mattpocock/skills](https://github.com/mattpocock/skills)
  by [Matt Pocock](https://github.com/mattpocock), used under the MIT License:
  code-review-stds-and-spec (upstream `code-review`), diagnosing-bugs, grill (upstream `grilling`),
  handoff, implement, research, tdd, to-spec, to-tickets, wait-what, wizard, and writing-for-agents
- [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack)
  by [poteto](https://x.com/poteto), used under the MIT License:
  architect, bro, interrogate, show-me-your-work, technical-writing, unslop, and why

code-review adapts OpenAI Codex's review prompt and Claude Code's `/simplify`, and rewrite-docs
started in this repo.

Thank you, Matt and poteto!
