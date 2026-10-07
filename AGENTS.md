# AGENTS.md

macOS dotfiles. `setup.sh` installs tools and configs; `ai_tools/setup.sh` sets up Claude Code, Codex, T3 Code, and the skills in `ai_tools/skills`.

- **Steps.** Both runners only run steps. A step is an `install.sh` beside the files it installs (`ai_tools/manual-steps.sh` is the exception). Each one sources `lib/common.sh` through `${BASH_SOURCE[0]}`, so it works when run directly and when sourced, and calls `main` only when run directly. A new step goes in the runner's `STEPS` and its `step_script` case.
- **Copied, not linked.** Setup copies configs into `$HOME` and skills into each agent's skills dir, so a repo edit takes effect only when its step re-runs. Run the scripts or touch `$HOME` only when asked: they change the real machine. To test a step, run it with `HOME` set to a temp dir and stdin from `/dev/null`.
- **Per-machine stays out.** Files other tools also edit (`~/.zshrc`, `~/.zprofile`, `~/.ssh/config`, `~/.gitconfig`, app settings) get missing lines appended or settings merged, never replaced. Settings specific to one machine, such as commit signing (`git/setup-signing.sh`), get their own script that setup doesn't run.
- **Scripts** target `/bin/bash` 3.2, since `setup.sh` runs before Homebrew. Every step is idempotent: skip silently when already applied, and finish sensibly when `confirm` says no (it always does without a terminal). Reuse the helpers in `lib/common.sh`.
- **Verify** with `just check` (shellcheck at every severity, plus `zsh -n`). There are no tests.
- **Docs change with the code**, in the same commit:
  - brew packages → README "What's included"
  - `setup.sh` steps → README "Quick setup"
  - new config files → README "Maintenance" copy-back list
  - `ai_tools/setup.sh` steps → `ai_tools/README.md`, marked **(script)**
  - `upgrade` → README "Updating"; `upgrade-ai-tools` → `ai_tools/README.md` "Updating"

  Run prose through `unslop`.
- **Skills**: load `writing-for-agents` before editing one or this file. Keep invocation in step across `SKILL.md`, `agents/openai.yaml`, and the category README heading. They're modified upstream copies, so port upstream diffs by hand and keep our changes.
