# AGENTS.md

Dotfiles for macOS 27 and an Ubuntu 26.04 desktop used over SSH, the only supported OSes. `setup.sh` installs tools and configs; `ai_tools/setup.sh` sets up Claude Code, the Claude desktop app, Codex, T3 Code, and the skills in `ai_tools/skills`.

- **Steps.** Runners only run steps. A step is an `install.sh` beside the files it installs (the two `manual-steps.sh` are exceptions). It sources `lib/common.sh` through `${BASH_SOURCE[0]}` and calls `main` only when run directly. Helper files it sources (`<step>/lib/`, or `ai_tools/lib/` when AI steps share them) only define things.
  - **Shape.** A step defines `status` and `apply`; the default `main` in `lib/common.sh` runs `status` under `--status` and `apply` otherwise. `status` is read-only, uses the `status_*` helpers, and ends with `status_result`. Under `--quick` (`status_quick`), it skips its slowest checks.
  - **Config-only steps.** A `*_files` function passes each source and destination to the function it's given; `apply` is `copy_step "<message>" <files-fn>` and `status` is `copy_status <files-fn>`. See `editorconfig/install.sh`, and `vim/install.sh` for a step that does more.
  - **Items.** List each simple thing a step sets up with `item [--sudo] [--hint <text>] "<status text>" "<pending text>" <check-fn> <fix-fn>`, in a function that starts with `items_reset` and that `status` and `apply` both call. Drive them with `items_status`, `items_ok`, `items_pending`, and `items_apply [--no-sudo]`. See `docker/install.sh`.
  - **sudo.** Helpers for root-owned files and apt repos are in `lib/system.sh`, and cask helpers in `lib/casks.sh`; source them after `lib/common.sh`. Mark items whose fix needs sudo `--sudo`, and ask once with `confirm_sudo_changes` for the list `items_pending` builds.
- **New step.**
  1. Add it to `MACOS_STEPS`, `UBUNTU_STEPS`, or both.
  2. Write `<step>/install.sh`: a header whose first line is one sentence saying what it does (`--help` lists it), then `*_files` functions, `status`, and `apply`.
  3. Add a test in `tests/`. A config-only step joins the list in `tests/test-config-steps.sh`.
  4. Update the docs **Docs change with the code** names.
- **Copied, not linked.** Setup copies configs into `$HOME`, so a repo edit applies only when its step re-runs; `just copy-back` copies differing installed configs back. Every function named `*_files` is treated as a files function, so name nothing else that way. Run the scripts or touch `$HOME` only when asked. `--status` (`just status`) only reads.
- **Testing a step by hand.** The step's header says whether it changes the system regardless of `HOME`, and where to test it instead. Run a macOS step that does so only when asked. Otherwise: `T="$(mktemp -d)"; env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u MISE_DATA_DIR -u MISE_CONFIG_DIR -u MISE_GLOBAL_CONFIG_FILE -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u BASH_ENV HOME="$T" TMUX_TMPDIR="$T" bash setup.sh <step> </dev/null`, also unsetting anything else `setup_sandbox` in `tests/lib.sh` unsets that your shell sets. A second run changes nothing, and `--status` then reports nothing needing attention beyond what needs a person, such as the GitHub login.
- **Per-machine stays out.** `copy_file` replaces a differing copied file with no backup, including Zed's `settings.json` and `keymap.json`, `~/.claude/CLAUDE.md`, and `~/.codex/AGENTS.md`. Files other tools also edit (shell startup files, `~/.ssh/config`, `~/.gitconfig`, app settings) only get settings merged or the repo's lines added; each startup file gets one line sourcing a file the `zsh` step copies. Only a merge offers a backup, through `maybe_backup` (`--backup`, `--no-backup`). One-machine settings, such as commit signing (`git/setup-signing.sh`), get their own script that setup doesn't run.
- **Both OSes.** Every step runs on either OS. Branch on `is_macos` or `is_ubuntu` (`$OSTYPE` in zsh), and skip with a message what one OS lacks. A step only one OS runs by default goes in that OS's step list. A step only one OS supports sets `STEP_OS=macos` or `STEP_OS=ubuntu`, as `chrome/install.sh` does. Use apt and Ubuntu's paths directly. Test Ubuntu as a non-root user in an `ubuntu:26.04` container after `apt-get install sudo-rs`, or, for systemd, in an Ubuntu VM such as an OrbStack machine.
- **Scripts** target `/bin/bash` 3.2 and reuse `lib/common.sh`. A step that breaks a rule below says why in its header, as `homebrew` does.
  - Every step is idempotent: when applied, it says so and changes nothing.
  - `confirm` says no without a terminal unless `DOTFILES_ASSUME_YES=1`. A declined `confirm` doesn't fail the step.
  - No migration code for files older versions left, but keep user edits to files the step merges into.
  - A state that could still break something is reported by `--status`, or fails the step before it changes anything.
  - A missing prerequisite fails the step before it changes anything (`require_cmd <cmd> || return 1`), and `STEP_NEEDS="homebrew"` names the step that installs it. Exception: when only an optional integration lacks a command, such as the worktree hook without `git wt`, set up the rest, then fail, with status reporting the integration missing.
  - A failed install fails the step after it does what else it can.
- **Verify** with `just check` and `just test` (or `just test <name>...`). Before writing a test, read the headers of `tests/lib.sh`, `tests/sentinels.sh`, and `tests/run.sh`, and `setup_sandbox`. A test stubs every command in `SENTINELS` it reaches, changes repo functions only with `replace_fn`, the OS with `as_os macos|ubuntu`, and `confirm` with `answer yes|no`, and reuses shared helpers such as `git_commit`, `stub_login_shell_zsh`, and `tests/ubuntu-sandbox.sh`. Mark a timing-sensitive test `# serial`. `just test-ubuntu` runs full setup in a throwaway OrbStack machine; run it only when asked. Only on a throwaway machine: `DOTFILES_ASSUME_YES=1`, `DOTFILES_SSH_KEY_ONLY=1` (turns off SSH passwords without a key login), and `DOTFILES_ALLOW_WORKTREE=1` (installs health alerts from a worktree).
- **Docs change with the code**, in the same commit. `just check` covers README's step table, `ai_tools/README.md`'s step list, step header lines, local links, skill metadata, and the keys in `scripts/claude-settings-keys.txt` (add a key only after checking it against Claude Code). Update by hand:
  - Claude and Codex models in the `claude-code` and `codex` steps → the reviewer table in `ai_tools/skills/engineering/interrogate/SKILL.md`
  - app keys rechecked against a new version → the version table in `ai_tools/README.md` "Maintenance"
  - what `ai_tools/setup.sh` steps do → the **(script)** marks in `ai_tools/README.md`
  - `upgrade` → README "Updating"; `upgrade-ai-tools` → `ai_tools/README.md` "Updating"
  - manual steps → the "Manual steps" section of README or `ai_tools/README.md`, which the `manual-steps` steps print

  READMEs keep to what a user does and sees; how a step handles a case goes in a comment or a test. Run prose through `unslop`.
- **Skills**: load `writing-for-agents` before editing one or this file. Most are modified upstream copies (see the skills README's Acknowledgements), so port upstream diffs by hand and keep our changes. The `skills` step owns `~/.agents/skills` and `~/.claude/skills` and deletes every entry it didn't install, apart from Claude Code's `synced` and dot-entries.

## Code layout

Projects live at `~/Dev/<group>/<project>`, such as `~/Dev/go/envl`; this repo is `~/Dev/setup/dotfiles`. `ts` in zsh and `prefix+f` in tmux open a tmux session for a project.

Worktrees go beside projects, not inside them:

| Tool | Worktrees |
| :- | :- |
| `git wt`, the `implement` skill, and Claude Code's `--worktree`, subagents, and background sessions | `~/.worktrees/<group>/<project>/<name>`, or `~/.worktrees/_/<project>-<hash>/<name>` outside `~/Dev/<group>/<project>` |
| T3 Code | `~/.t3/worktrees/<repo>/<worktree>` |
| The Codex app | `~/.codex/worktrees` |
