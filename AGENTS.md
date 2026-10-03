# AGENTS.md

macOS dotfiles. `setup.sh` installs tools and configs; `ai_tools/setup.sh` sets up Claude Code, Codex, T3 Code, and the skills in `ai_tools/skills`.

- **Copied, not linked.** Setup copies configs into `$HOME` and skills into each agent's skills dir, so a repo edit takes effect only when its setup script re-runs. Run the scripts or touch `$HOME` only when asked: they change the real machine.
- **Verify** shell edits with `bash -n` or `zsh -n`. There are no tests.
- **Scripts** target `/bin/bash` 3.2, since `setup.sh` runs before Homebrew. Every step is idempotent: skip silently when already applied, and finish sensibly when `confirm` says no (it always does without a terminal). Reuse the helpers at the top of `ai_tools/setup.sh`.
- **Docs change with the code**, in the same commit: brew packages → README "What's included"; `ai_tools/setup.sh` steps → `ai_tools/README.md`, marked **(script)**; `upgrade*` functions in `zsh/aliases.zsh` → its "Updating" section. Run prose through `unslop`.
- **Skills**: load `writing-for-agents` before editing one or this file. Keep invocation in step across `SKILL.md`, `agents/openai.yaml`, and the category README heading. They're modified upstream copies, so port upstream diffs by hand and keep our changes.
