# Skills

Agent skills for Claude Code and Codex, grouped by category:

- [engineering](./engineering/README.md): skills for code work
- [productivity](./productivity/README.md): general workflow tools, not code-specific

## Installation

`bash ai_tools/setup.sh` installs every skill globally for Claude Code and Codex with the
[skills CLI](https://skills.sh). Re-run it after changing a skill. See
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
`done`. `code-review-stds-and-spec` reads the spec from the same place. Decide per repo whether
to commit `.scratch/` or add it to `.gitignore`; the skills work either way.

## Layout of a skill

Each skill is a folder with a `SKILL.md` (the instructions, with frontmatter for Claude Code)
and an `agents/openai.yaml` (Codex display name, short description, and whether Codex may
invoke the skill on its own). Some skills carry extra reference files or scripts beside
`SKILL.md`.

## Acknowledgements

These skills are copied and modified from these repos:

- [mattpocock/skills](https://github.com/mattpocock/skills)
  by [Matt Pocock](https://github.com/mattpocock), used under the MIT License
- [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack)
  by [poteto](https://x.com/poteto), used under the MIT License

Thank you, Matt and poteto!
