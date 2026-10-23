# AGENTS.md

Dotfiles for macOS 27 and an Ubuntu 26.04 desktop used over SSH, the only supported OSes. `setup.sh` installs tools and configs; `ai_tools/setup.sh` sets up Claude Code, the Claude desktop app, Codex, T3 Code, and the skills in `ai_tools/skills`.

- **Steps.** The runners, `setup.sh` and `ai_tools/setup.sh`, only run steps. A step is an `install.sh` beside the files it installs (the two `manual-steps.sh` are exceptions). It sources `lib/common.sh` through `${BASH_SOURCE[0]}` and calls `main` only when run directly. Helper files it sources (`<step>/lib/`, or `ai_tools/lib/` when AI steps share them) only define things.
  - **Shape.** A step defines `status` and `apply`; the default `main` in `lib/common.sh` runs `status` under `--status`, ending it with `status_result`, and `apply` otherwise. `status` is read-only and uses the `status_*` helpers. Under `--for-alerts` (`status_for_alerts`), which the daily health alert runs, it skips its slowest checks.
  - **Config-only steps.** A `*_files` function passes each source and destination to the function it's given; `apply` is `copy_step "<message>" <files-fn>` and `status` is `copy_status <files-fn>`. See `editorconfig/install.sh`, and `vim/install.sh` for a step that does more.
  - **Items.** List each simple thing a step sets up with `item [--sudo] [--hint <text>] "<status text>" "<pending text>" <check> <fix>`, in a function that starts with `items_reset` and that `status` and `apply` both call. A check or fix is a function, or a quoted command and its arguments split on spaces (`"apt_installed ddcutil"`). An empty status text makes an apply-only item, which `items_status` leaves out. A check may set `ITEM_DETAIL`, which status shows after the text, and `ITEM_STATE`, which status shows instead of `ok` or `missing`; `skipped` and `info` count as done. Drive them with `items_status`, `items_ok`, `items_apply [--no-sudo]`, and `items_apply_confirmed [--done <message>] [--note <line>]...`. See `docker/install.sh`.
  - **sudo.** Helpers for root-owned files and apt repos are in `lib/system.sh`, cask helpers in `lib/casks.sh`, and GNOME extension and shortcut helpers in `lib/gnome.sh`; source them after `lib/common.sh`. Mark items whose fix needs sudo `--sudo`. `items_apply_confirmed` asks once for the pending sudo items, plus each `--note`, applies them, and prints the result. Within one memo scope, later calls reuse the answer, and a check reads it with `sudo_confirmed`. A step that asks about changes that aren't items passes `confirm_sudo_changes` its own list.
  - **Caching.** `memo <var> <cmd...>` runs a command once per memo scope. A function opens a scope, or joins its caller's, with `local MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"`. A call inside `$( )` caches only in that subshell, so call it once outside one first; after a fix changes what a cached check reads, `memo_forget <var>`.
- **New step.**
  1. Add it to `MACOS_STEPS`, `UBUNTU_STEPS`, or both.
  2. Write `<step>/install.sh`: a header whose first line is one sentence saying what it does (`--help` lists it), then `*_files` functions, `status`, and `apply`.
  3. Add a contract test in `tests/`: a second apply changes nothing, `--status` reports what apply set, and a missing prerequisite fails before any change. A config-only step joins the list in `tests/test-config-steps.sh`.
  4. Update the docs **Docs change with the code** names.
- **Copied, not linked.** Setup copies configs into `$HOME`, so a repo edit applies only when its step re-runs; `just copy-back` copies differing installed configs back. Every function named `*_files` is treated as a files function, so name nothing else that way. Run setup against your real `$HOME` only when asked; a temp `HOME`, as below, is fine. `--status` (`just status`) only reads.
- **Testing a step by hand.** The step's header says whether it changes the system regardless of `HOME`, and where to test it instead. Run a macOS step that does so only when asked. Otherwise, run `T="$(mktemp -d)"; env -u <var>... HOME="$T" TMUX_TMPDIR="$T" bash setup.sh <step> </dev/null`, unsetting each variable `setup_sandbox` in `tests/lib.sh` unsets that your shell sets. A second run changes nothing, and `--status` then reports nothing needing attention beyond what needs a person, such as the GitHub login.
- **Per-machine stays out.** `copy_file` replaces a differing copied file with no backup, including Zed's `settings.json` and `keymap.json`, `~/.claude/CLAUDE.md`, and `~/.codex/AGENTS.md`; `just touch-id` likewise writes `/etc/pam.d/sudo_local` whole. Files other tools also edit (shell startup files, `~/.ssh/config`, `~/.gitconfig`, app settings) only get settings merged or the repo's lines added; each startup file gets one line sourcing a file the `zsh` step copies. Only a merge offers a backup, through `maybe_backup` (`--backup`, `--no-backup`). One-machine settings, such as commit signing (`git/setup-signing.sh`), get their own script that setup doesn't run.
- **Both OSes.** Every step can be run on either OS, and skips with a message what doesn't apply there. Branch on `is_macos` or `is_ubuntu` (`$OSTYPE` in zsh). A step only one OS runs by default goes in that OS's step list. A step only one OS supports sets `STEP_OS=macos` or `STEP_OS=ubuntu`, as `chrome/install.sh` does. Use apt and Ubuntu's paths directly. Test Ubuntu as a non-root user in an `ubuntu:26.04` container after `apt-get install sudo-rs`, or, for systemd, in an Ubuntu VM such as an OrbStack machine.
- **Scripts** target `/bin/bash` 3.2 and reuse `lib/common.sh`. A step that breaks a rule below says why in its header, as `homebrew` does.
  - Every step is idempotent: when everything is already set up, it says so and changes nothing.
  - `confirm` says no without a terminal. A declined `confirm` doesn't fail the step.
  - Write no code that cleans up after older versions of the repo, but keep user edits to files a step merges into.
  - A state that could still break something is reported by `--status`, or fails the step before it changes anything.
  - A missing prerequisite fails the step before it changes anything (`require_cmd <cmd> || return 1`), and `STEP_NEEDS="homebrew"` names the step that installs it. The runner reads `STEP_OS` and `STEP_NEEDS` without sourcing, so each is a literal on its own line. Exception: when only an optional integration lacks a command, such as the worktree hook without `git wt`, set up the rest, then fail, with status reporting the integration missing.
  - A failed install fails the step after it does what else it can.
- **Verify** with `just check` and `just test` (or `just test <name>...`). Test only a step's contract, a non-obvious edge case, or an edge case that could harm the machine or your data; leave external tools and what the code makes obvious untested. The live checks CI runs (`scripts/check-brew-packages.sh`, `check-ai-settings.sh`, and `check-t3-settings.sh`) cover external tools' behavior. Before writing a test, read the headers of `tests/lib.sh`, `tests/sentinels.sh`, and `tests/run.sh`. `just test-ubuntu` runs full setup in a throwaway OrbStack machine; run it only when asked. Only on a throwaway machine: `DOTFILES_ASSUME_YES=1` (`confirm` says yes) and `DOTFILES_SSH_KEY_ONLY=1` (turns off SSH passwords without a key login). Both take effect only where `systemd-detect-virt -q` succeeds; a test that sets them stubs it.
- **Docs change with the code**, in the same commit. `just check` covers README's step table, `ai_tools/README.md`'s step list, step header lines, the Manual steps sections, local links, skill metadata, and the keys in `scripts/claude-settings-keys.txt` (add a key only after checking it against Claude Code). Update by hand:
  - When you change the Claude or Codex models in the `claude-code` or `codex` step, update the reviewer table in `ai_tools/skills/engineering/interrogate/SKILL.md`.
  - When you recheck app keys against a new version, update the version table in `ai_tools/README.md` "Maintenance".
  - When you change what an `ai_tools/setup.sh` step does, update the **(script)** marks in `ai_tools/README.md`.
  - When you change `scripts/upgrade.sh`, which zsh's `upgrade` and `upgrade-ai-tools` (`zsh/aliases.zsh`) run, update README "Updating" for `upgrade`, and `ai_tools/README.md` "Updating" for `upgrade-ai-tools`.
  - When you change a manual step, update the "Manual steps" section of README or `ai_tools/README.md`, which the `manual-steps` steps print.

  READMEs keep to what a user does and sees; how a step handles a case goes in a comment, or in a test when the case is non-obvious or harmful. Run prose through `unslop`.
- **Skills.** Load `writing-for-agents` before editing one or this file. Most are modified upstream copies (see the skills README's Acknowledgements), so port upstream diffs by hand and keep our changes. The `skills` step owns `~/.agents/skills` and `~/.claude/skills` and deletes every entry it didn't install, apart from Claude Code's `synced` and dot-entries.

## Code layout

Projects live at `~/Dev/<group>/<project>`, such as `~/Dev/go/envl`; this repo is `~/Dev/setup/dotfiles`.

Worktrees go beside projects, not inside them:

| Tool | Worktrees |
| :- | :- |
| `git wt`, the `implement` skill, and Claude Code's `--worktree`, subagents, and background sessions | `~/.worktrees/<group>/<project>/<name>`, or `~/.worktrees/_/<project>-<hash>/<name>` outside `~/Dev/<group>/<project>` |
| T3 Code | `~/.t3/worktrees/<repo>/<worktree>` |
| The Codex app | `~/.codex/worktrees` |
