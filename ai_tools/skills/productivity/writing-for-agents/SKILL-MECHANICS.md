# Skill mechanics

The skill-specific branch of [`writing-for-agents`](SKILL.md): what changes when the document is a skill (frontmatter, `agents/openai.yaml`, the invocation choice, names, references to other skills, and router skills). Everything else about writing it is the universal reference in `SKILL.md`.

## Invocation

Two choices, trading the two loads:

- A **model-invoked** skill keeps a `description`, so the agent can fire it autonomously, and other skills can reach it. You can still type its name: model-invocation always _includes_ user reach; a description only ever adds agent discovery, never removes the human's. The description is the skill's top-level context pointer, forced to stay loaded at all times: permanent context load in exchange for discoverability. A model-invoked skill whose content is all reference is also one home for shared reference: another skill can invoke it, so reference needed by several skills lives in one place. Mechanics: omit `disable-model-invocation`, and write a model-facing description carrying the trigger branches (the pointer-writing rules in `SKILL.md` apply in full).
- A **user-invoked** skill strips the description from the agent's reach: only the human typing its name can invoke it, and no other skill can. Zero context load, but it spends cognitive load: you are the index that must remember it exists. Mechanics: set `disable-model-invocation: true` in `SKILL.md` and `allow_implicit_invocation: false` in `agents/openai.yaml`. The `description` becomes human-facing: a one-line summary, trigger lists stripped.

Pick model-invocation only when the agent must reach the skill on its own, or another skill must. If it only ever fires by hand, make it user-invoked and pay no context load.

Shared reference that two user-invoked skills both need can live in neither as a skill to fire: with no descriptions, neither can fire the other. Keep it as a file in one of them that the other reads by path (see _Referring to other skills_).

## Splitting by invocation

The invocation cut of splitting (the sequence cut lives in `SKILL.md`): split off a model-invoked skill when you have a distinct leading word that should trigger it on its own (a trigger word you actually use in your prompts), or another skill must reach it. You pay context load for the new always-loaded description, so that independent reach has to be worth it.

## Router skills

When user-invoked skills multiply past what you can remember, that piled-up cognitive load is cured by a **router skill**: one user-invoked skill that names the others and when to reach for each, so the human has one skill to remember instead of many. It can only hint, never fire them: user-invoked skills have no description, so nothing but the human can reach them.

## Frontmatter

Codex reads `name` and `description` and ignores the other fields below, which are Claude Code's. claude.ai uploads and the Skills API reject any field outside `name`, `description`, `license`, `compatibility`, `metadata`, and `allowed-tools`.

- `description`: write it in the third person, as "<What it does>. Use when …", with the trigger near the front. Both tools cap the skill listing (Claude Code at 1% of the context window, Codex at 2%) and shorten descriptions first when it overflows. Claude Code also cuts each description at 1,536 characters.
- `disable-model-invocation: true`: see _Invocation_.
- `argument-hint`: the hint autocomplete shows for the arguments, such as `[spec-path]`.
- `allowed-tools`: tools that run without a permission prompt during the turn that invokes the skill, such as `Bash(git add *) Bash(git commit *)`. The grant clears at the user's next message, and it restricts nothing: other tools stay available under the normal permission rules.
- `context: fork`: runs the skill as a sub-agent whose prompt is the skill body. The sub-agent doesn't see the conversation, so the body must carry the whole task, and a reference-only skill gives it nothing to do. `agent` picks the sub-agent type. It runs in the background unless `background: false` is set.
- `model` and `effort`: the model and effort level for the rest of the turn, or for the forked sub-agent with `context: fork`. Codex ignores both, so a skill that needs a model for its own sub-agents names it in the body.

Two substitutions work in the body, in Claude Code only:

- `$ARGUMENTS` becomes the text typed after the skill name, and `$0`, `$1`, … its shell-quoted words. With no placeholder, Claude Code appends `ARGUMENTS: <text>` to the body. Codex documents no substitution, so word the body to work either way: "If the user passed arguments, …".
- `${CLAUDE_SKILL_DIR}` becomes the skill's own directory, so a bundled script runs from any working directory: `${CLAUDE_SKILL_DIR}/scripts/check.sh`. Codex lists each skill's `SKILL.md` path, so there the agent resolves the same relative path against that.

## agents/openai.yaml

Codex's per-skill settings. Every string is quoted:

```yaml
interface:
  display_name: "Title Case Name"
  short_description: "What it does, in 25 to 64 characters"
policy:
  allow_implicit_invocation: false
```

- `display_name` is the title in Codex's skill lists.
- `short_description` is the blurb beside it, 25 to 64 characters.
- `allow_implicit_invocation` defaults to `true`. Set it to `false` for every skill with `disable-model-invocation: true`. The user can still invoke it as `$name`.
- Optional fields: `icon_small`, `icon_large`, `brand_color`, `default_prompt` (must name the skill as `$name`), and `dependencies.tools` for MCP servers the skill needs.

## Names

A skill's `name` can replace a built-in. In Claude Code, a personal skill named like a bundled skill or built-in command replaces it, but not its aliases: the `code-review` skill replaces `/code-review`, and the `/review` alias still runs the bundled review. Codex's built-in slash commands can't be replaced, so there the skill is reached only as `$name`, beside the built-in.

## Referring to other skills

Claude Code invokes a skill as `/name` and Codex as `$name`, so name another skill in words: "the tdd skill". A built-in command keeps its slash and names its tool: "Claude Code's `/simplify`". The agent can't start a user-invoked skill, so refer to one only as a suggestion for the user to run.

The installer puts every skill side by side in one directory, so a skill can use another skill's file at `../<skill>/<path>`, from either tool and whether the other skill is user-invoked or not. Name the skill in words beside the path: "the code-review skill's `references/scope.md` (installed beside this skill)". In the repo the path resolves only within one category folder, so for a skill in another category, write the path as code instead of a link, and the repo has no broken links. This is how several skills share one reference without a model-invoked home for it.
