# AGENTS.md

Dotfiles for macOS 27 and an Ubuntu 26.04 desktop used over SSH, the only supported OSes. `setup.sh` installs tools and configs; `ai_tools/setup.sh` sets up the AI tools and the skills in `ai_tools/skills`.

## Steps

- The runners, `setup.sh` and `ai_tools/setup.sh`, only run steps. A step is an `install.sh` beside the files it installs, with a read-only `status` and an `apply`. Copy the shape of `editorconfig/install.sh` (config only), `vim/install.sh`, or `docker/install.sh` (items). Files a step sources only define things.
- Before writing a step, read the comments on `item`, `items_apply_confirmed`, and `memo` in `lib/common.sh`, and the other `lib/*.sh` headers.
- A new step goes in its runner's `MACOS_STEPS`, `UBUNTU_STEPS`, or both. Its header's first line is one sentence saying what it does, and the header says so if the step changes the system regardless of `HOME`.
- A new step gets a contract test: a second apply changes nothing (`assert_idempotent`), `--status` reports what apply set, and a missing prerequisite fails before any change. A config-only step joins `tests/test-config-steps.sh`.
- Every function named `*_files` is treated as a files function, so name nothing else that way.

## Rules for steps

A step that breaks a rule says why in its header, as `homebrew/install.sh` does.

- Scripts target `/bin/bash` 3.2.
- Every step is idempotent: when everything is set up, it says so and changes nothing.
- Ask before any sudo change: mark the item `--sudo` and apply it with `items_apply_confirmed`, or pass the change to `confirm_sudo_changes`. A declined `confirm`, the answer without a terminal, doesn't fail the step.
- A missing prerequisite fails the step before any change (`require_cmd <cmd> || return 1`), with `STEP_NEEDS="<step>"` as a literal on its own line. When only an optional integration lacks a command, set up the rest, then fail, with `status` reporting it.
- A state that could still break something is reported by `--status`, or fails the step before any change. `status` skips its slowest checks under `status_for_alerts`.
- A failed install fails the step after it does what else it can.
- No code cleans up after older versions of the repo, but user edits to files a step merges into stay.
- Copied configs are replaced whole, with no backup, so nothing per-machine goes in one. Files other tools also edit (shell startup files, `~/.ssh/config`, `~/.gitconfig`, app settings) only get settings merged or lines added. A one-machine setting gets its own script that setup doesn't run, such as `git/setup-signing.sh`.
- Every step runs on either OS and skips with a message what doesn't apply there. Branch on `is_macos` or `is_ubuntu`. A step only one OS supports sets `STEP_OS`, as `chrome/install.sh` does.
- `vim/plug.vim` is vendored, and the vim and tmux plugin pins change only through `just bump-plugins`.

## Running and testing

- Run setup against your real `$HOME`, a step whose header says it changes the system regardless of `HOME`, or `just test-ubuntu` only when asked. `--status` only reads.
- To try a step, run `T="$(mktemp -d)"; env -u <var>... HOME="$T" TMUX_TMPDIR="$T" bash setup.sh <step> </dev/null`, unsetting the variables `setup_sandbox` in `tests/lib.sh` unsets. A second run changes nothing.
- Try Ubuntu as a non-root user in an `ubuntu:26.04` container after `apt-get install sudo-rs`, or in an OrbStack VM for systemd.
- Verify with `just check` and `just test [name...]`. Before writing a test, read the headers of `tests/lib.sh`, `tests/sentinels.sh`, and `tests/run.sh`.
- Test a step's contract and the edge cases that are non-obvious or could harm the machine or data. CI's live checks (`scripts/check-*-settings.sh`, `check-brew-packages.sh`) cover external tools.
- `DOTFILES_ASSUME_YES=1` and `DOTFILES_SSH_KEY_ONLY=1` act only where `systemd-detect-virt -q` succeeds, so a test that sets them stubs it or replaces `on_test_machine`.

## Docs

Docs change with the code, in the same commit, and `just check` catches most drift. By hand:

- The Claude or Codex models in `claude-code` or `codex`: the reviewer table in `ai_tools/skills/engineering/interrogate/SKILL.md`.
- An app's keys rechecked against a new version: the version table in `ai_tools/README.md` "Maintenance".
- What an `ai_tools/setup.sh` step does: the **(script)** marks in `ai_tools/README.md`.
- `scripts/upgrade.sh`: "Updating" in README for `upgrade`, and in `ai_tools/README.md` for `upgrade-ai-tools`.
- A manual step: "Manual steps" in README or `ai_tools/README.md`.
- A key added to `scripts/claude-settings-keys.txt`: check it against Claude Code first.

READMEs say what a user does and sees; how a step handles a case goes in a comment or a test. Run prose through `unslop`.

## Skills

Load `writing-for-agents` before editing a skill or this file. Most skills are modified upstream copies (see the skills README's Acknowledgements), so port upstream diffs by hand and keep our changes. The `skills` step deletes every entry in `~/.agents/skills` and `~/.claude/skills` it didn't install, apart from Claude Code's `synced` and dot-entries.
