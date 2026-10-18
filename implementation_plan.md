# Implementation plan: review findings

**For:** an independent agent that implements every finding in the review report on a local branch, using sub-agents in parallel where the work allows it.

**Inputs:**
- Report: `/Users/gpahal/.t3/worktrees/dotfiles/t3-0fe7e446/final_report.md` (finding numbers `#1` to `#58`, the P4 nits, simplifications `S1` to `S7`).
- This plan, at the same location (`implementation_plan.md`).
- The repo's `AGENTS.md`, which every agent must read first.

Where this plan and the report differ, **this plan wins**. The user settled every design question in "Decisions" below. Line numbers refer to commit `932abc7`. If the code has moved, find the spot by symbol name.

---

## 1. Ground rules

### Git and delivery
- In your own worktree, create the branch `fix/review-findings` from local `main`. First check that `main` is at `932abc7`. If it isn't, re-check each finding against the new code before you change anything.
- **Commit locally only.** Don't push, don't open a PR, and don't tag. The user reviews locally and pushes. Each commit message ends with the Co-Authored-By trailer your harness specifies.
- Make one commit per logical change, at least one per work package (WP). Use an imperative subject, and list the finding numbers in the body. A docs change that describes a code change goes in the same commit as the code (AGENTS.md).
- Copy `final_report.md` and `implementation_plan.md` into your worktree's `.scratch/`, which is gitignored, so sub-agents can read them. Never commit them.

### Safety
These come from AGENTS.md and the user, and are not negotiable.
- Never run `setup.sh`, `ai_tools/setup.sh`, or any `install.sh` against the real `$HOME` or the real machine.
- Never run `sudo`, `defaults write`, `launchctl`, `systemctl` (on the Mac), `brew install`/`upgrade`, or anything that changes this Mac.
- Don't kill the orphaned test processes already on this Mac; the user will.
- To exercise a step, use AGENTS.md's temp-HOME recipe:
  ```sh
  T="$(mktemp -d)"; env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME HOME="$T" TMUX_TMPDIR="$T" bash setup.sh <step> </dev/null
  ```
  Use it only for steps whose header says they change nothing outside `HOME`, and read the header first.
- **Ubuntu checks:**
  - Allowed: throwaway `ubuntu:26.04` containers via OrbStack's `docker` (`/usr/local/bin/docker`). Run the step as a non-root user, after `apt-get install sudo-rs`.
  - Allowed: **one** `just test-ubuntu` run near the end, which uses a throwaway OrbStack machine. Re-run it only after fixing a failure it found.
  - Not allowed: anything that touches the user's real Ubuntu server.
- No changes to `.github/`. Changes to `tests/`, `scripts/check-*.sh`, and the `justfile` are in scope as listed below.

### Conventions
All from AGENTS.md:
- `/bin/bash` 3.2: no `mapfile`, `declare -A`, `${x,,}`, or `[[ -v`. Guard empty arrays under `set -u`.
- Every step stays idempotent, and a declined `confirm` doesn't fail it.
- No migration code for older versions of this repo.
- `require_cmd` before changing anything.
- Reuse `lib/common.sh` helpers.
- Load the `writing-for-agents` skill before editing a skill or `AGENTS.md`. Keep invocation in step across `SKILL.md`, `agents/openai.yaml`, and the category README heading.
- Run the prose you write in READMEs through the `unslop` skill.
- Comments say why, not what. Match the surrounding comment density.

### Gates
After each merge into `fix/review-findings`, run `just check` and `just test`. Both must pass before the next phase starts. At the end of every WP, the sub-agent also runs `just test <its tests>`, then the full `just test`.

### When to stop and ask the user
Ask the user (through the lead) only if one of these happens:
- A decision below turns out to be infeasible, or would need a different user-visible behavior.
- A finding no longer matches the code.
- A fix needs a new external dependency not named here.
- A test shows a decided behavior conflicts with another feature.

Otherwise, decide and record the choice in the WP's hand-back.

---

## 2. Decisions

### Made by the user

| ID | Topic | Decision |
|----|-------|----------|
| D1 | Tests | In scope: tests that fixes and refactors need, a regression test per bug fix, the #14 sandbox leaks, all of S6, and #54 to #57. Out of scope: `.github/`. |
| D2 | Delivery | Local commits on `fix/review-findings`. No push, PR, or tag. |
| D3 | Ubuntu checks | Containers, plus one `just test-ubuntu` run near the end. |
| D4 | Scope | Every P1 to P4 fix and every S1 to S7 simplification, including loosening `stage_doc` in `scripts/check-docs.sh` and trimming the README "Updating" section. |
| D5 | #7 Docker → SSH | Remove `172.16.0.0/12` from `SSH_RANGES`, and fix the comment at `docker/install.sh:33-35`. No migration: on existing servers, status flags the old ufw rule as broad. |
| D6 | #18 Apt keys | Pin fingerprint constants. Docker: `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`. Tailscale: take it from Tailscale's docs or repo if published. Otherwise compute it from the key `pkgs.tailscale.com` serves, say so in the commit message, and add a hand-off item asking the user to confirm it on the server with `gpg --show-keys /usr/share/keyrings/tailscale-archive-keyring.gpg`. A mismatch fails the step before it changes anything. |
| D7 | #19 ntfy file | Keep 0644. Reword the comments (`ubuntu/setup-alerts.sh:65-71`, `ubuntu/lib/ntfy.sh:9-11`) to say argv hiding only keeps the URL out of `ps` listings and diagnostics. |
| D8 | #20 Root-only checks | Document the gap in README's alerts text. When any root-only item is unverified, the health alert adds one line saying those checks (ufw rules, sshd overrides, SMART, NUT files) run only in `just status` with sudo cached. No root timer, no sudoers entry. |
| D9 | #16 Hotkeys | `MODS = { "ctrl", "alt", "cmd" }` for all six Hammerspoon hotkeys. **Also stop disabling** macOS's Ctrl+Opt+Space "select next input source" shortcut in the `macos` step, since nothing needs it now. No migration: the hand-off tells the user to re-enable it by hand if they want it. |
| D10 | #17 Dato | Keep Dato in the Brewfile. Add an `OPTIONAL_MAS` list (Dato) in `homebrew/install.sh`, and report a missing optional app as `info` (not `missing`) in status and in the step's warning. README first-run step 2 is reworded to match. |
| D11 | #13 Cowork | Keep every claude-desktop setting as it is. Document them all in `ai_tools/README.md`, saying plainly that Cowork browser tools drive the signed-in Chrome, and how to turn them off in the app. Also document the ChatGPT app keys `ai_tools/README.md:141` omits. |
| D12 | #4 please | Show the command, then run it with no prompt: `please() { local c; c="$(fc -ln -1)"; print -r -- "sudo: $c"; sudo zsh -c "$c"; }`. Replace the alias with this function. |
| D13 | Deliberate settings | Change only one: add a status check, on Ubuntu, that flags Codex's `.credentials.json` (plaintext tokens, from `mcp_oauth_credentials_store = "file"`) when its mode isn't 600, with the `chmod` fix. Keep every other deliberate setting unchanged. |
| D14 | Reversals | (a) When `systemctl --user show -p Result --value t3code.service` is `start-limit-hit`, the t3-code step runs `systemctl --user reset-failed t3code.service` before starting it. Update `tests/test-t3-service.sh:218` and the README manual instruction. (b) #34: when ufw is already on, add the missing allow rules instead of refusing because an outside session exists. The refusal stays for turning ufw on. Update `tests/test-ufw-recheck.sh:350`. (c) #24: ask about the docker group with its own `confirm`, separate from the other docker items. |
| D15 | #48 code-review | It is adapted from both OpenAI Codex's review prompt and Claude Code's `/simplify`. Document that in a single line in `ai_tools/skills/README.md`, replacing "The code-review and rewrite-docs skills started in this repo" with code-review's origin plus rewrite-docs having started here. No license file. Fix AGENTS.md's "every skill is an upstream copy" wording. |
| D16 | S5 zsh PATH | Make `zsh/path.zsh` the single PATH source, with no migration code. The hand-off lists, word for word, the old managed lines to delete by hand from `~/.zprofile`, `~/.zshenv`, and `~/.profile` on the Mac and on the Ubuntu box. |
| D17 | S1 item table | Two texts per item: `sudo_item "<status text>" "<pending text>" <check-fn> <fix-fn>`. Status output and the sudo prompt stay word for word. |
| D18 | S3 step entry | `lib/common.sh` defines a default `main`: `step_args`, then `--status` goes to the step's `status`, and anything else to the step's `apply`. Steps define `status` and `apply`. Any step may still define its own `main`. The footer is unchanged, so the 256 test calls to `main` keep working. Config-only steps use `copy_step` and `copy_status` helpers. |
| D19 | Skills state | Merge `SKILLS_STATE` and `SKILLS_HASHES` into one `<hash\|->  <name>` file under `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/`. Accept the reset on existing machines (the hand-off says what to expect). |
| D20 | Tailscale fingerprint | See D6. |

### Made by the planner
These are implementation calls on small items. Each one is final unless it proves infeasible.

- **#1 atomic copy:**
  - Copy to a temp file in the destination's directory, then `mv -f` it into place.
  - When the destination is a symlink, write to its resolved target (`readlink -f`, which macOS 27 and uutils both support), so the link survives.
  - Mode: an existing file keeps its mode, and a new one gets 755 if the source is executable, otherwise 644.
  - Record the hash only after the `mv` succeeds.
  - Don't call `write_back` with a repo file, since it deletes its input. Factor out a shared "replace atomically" helper instead.
- **#2:** in `is_clean`, compare file types first. Symlinks match only if their `readlink` values are equal; regular files use `cmp -s`.
- **#3:** write the T3 drop-in through `write_back`. Move the telemetry LaunchAgent into the repo as `ai_tools/t3-code/dotfiles.t3code-telemetry-off.plist` and handle it with `copy_file` and `status_file` (S5). Make its bytes identical to what the current `printf` writes, so on existing Macs the first run records it silently instead of asking about a backup.
- **#5:** set a trap in `run_steps` (`RUN_INTERRUPTED=1` on INT, TERM, and HUP), and stop after any step once it's set. `install_cask` exits with brew's status when that is above 128, and `try_install_cask`'s special case goes. `interrupted_status` stays for `scripts/upgrade.sh`.
- **#8:** replace the `FETCH_HEAD` check with a per-branch stamp file that the hook writes only after its own fetch of that branch succeeds, at `"$(git rev-parse --git-common-dir)/dotfiles-worktree-hook/fetched-<branch, with / encoded>"`. It counts as fresh when its mtime is under 10 minutes old. This gives up skipping after the user's own `git fetch`; that is accepted, because parsing `FETCH_HEAD` URLs is fragile.
- **#10:** pull out full-line comments that sit outside `"""` or `'''` strings with awk, toggling a flag on lines with an odd number of delimiters. Pass only when the edited copy's comment list contains the source's (`comm` on sorted, trimmed lines). For the trailing-comment placement nit: if inserting the tail before the first table the edit added fits in about 15 lines with a test, do it; otherwise document the behavior in a code comment.
- **#11:** add a warning in `interrogate/SKILL.md`: the Codex reviewer can read any file you can, so don't run it on untrusted diffs. `run-reviewer.sh` also rejects an out-file under the repo root (`$root`).
- **#15:** match the stable prefix `a t3 serve started by hand (`, and add a lightweight test that runs the real formatter against the smoke test's regex.
- **#21:** report `IPV6=yes` missing from `/etc/default/ufw` as a status item only. Don't edit the file.
- **#22:** a status item from `docker ps --format '{{.Names}}\t{{.Ports}}'`, flagging ports bound on `0.0.0.0` or `::` as `missing`, with a fix text. It's `unverified` when the daemon can't be reached without sudo.
- **#25:** write `IgnoreUnknown UseKeychain` as the first line of the Host * block, and add it to `host_star_missing` in the order ssh needs (it must come before `UseKeychain`).
- **#26:** reject a base starting with `-`.
- **#27:** print each Claude Code plugin's and marketplace's version before and after updating. Updating stays automatic.
- **#28:** compare `fs.inotify.*` with `>=`, and `kernel.panic` exactly. When a key still differs after `sysctl --system`, name the file that sets it.
- **#29:** when the source file already held the new content at the start (`previous == content`), treat it as having no known-good copy. On failure, remove the file and key, and say the source still fails.
- **#30:** per-range prefix floors. With 172.16/12 gone: 10/8 needs at least 8, 192.168/16 at least 16, fd00::/8 at least 8, fe80::/10 at least 10.
- **#31:** save `/proc/sys/kernel/random/boot_id` in the alerts state dir, and skip the boot push when it hasn't changed.
- **#32:** an optional fourth argument for `install_root_file` and `write_root_file` that sets the group (`sudo install -g`). `write_nut_file` uses it, and `nut_files_current` checks the group too.
- **#33:** accept either `ssh.socket` or `ssh.service` being enabled.
- **#35:** document only (the README Power cuts manual step, plus a code comment). No code change.
- **#36:** the awk header filter in `run_steps` records whether it saw a `missing` or `unknown` item. A step exit of 3 counts as needing attention only if it did; otherwise it's a failure. Use `PIPESTATUS`.
- **#41:** `pbpaste 2>/dev/null | grep '[^[:space:]]' >/dev/null`. grep without `-q` reads all of its input, so pbpaste never gets SIGPIPE.
- **Production paths:** hard-code them; don't read test variables such as `APT_SOURCES_DIR`. `TAILSCALE_LIST` matches docker. Tests re-point the constants.
- **Skipped on purpose:**
  - `pam.sh` version-and-hash hardening: not a real escalation, and it adds state.
  - The unslop banned-words overlap.
  - Caching `uname -s`.
- **S1 table storage:** parallel arrays (`SUDO_ITEM_STATUS`, `SUDO_ITEM_PENDING`, `SUDO_ITEM_CHECK`, `SUDO_ITEM_FIX`). Drivers:
  - `sudo_items_pending`: appends to the caller's `pending` array, as the steps do now.
  - `sudo_items_apply`: re-checks each item, runs the fix only if the check still fails, and returns 1 if any fix failed.
  - `sudo_items_status`: one `status_check` per item.
  - `sudo_items_reset`.
  - Items with branching stay custom code: ufw, sshd, Tailscale, UPS, the sysctl "written but not in effect" case, and Wake-on-LAN.
- **S3 names:** the default `main` calls `apply`, which no command or function in the repo uses. Don't name it `install`, which would shadow `install(1)`.
- **S5 keepable values:** shared helpers in a new `ai_tools/lib/keepable.sh`, sourced by `ai_tools/claude-code/install.sh` and `ai_tools/codex/install.sh`, not in `lib/common.sh`.
- **S5 git-wt additions:**
  - `git wt base` prints the default base ref, in the order origin/HEAD → main → master → HEAD, factored out of `cmd_add`.
  - `git wt rm --delete-merged-branch` deletes the branch when another local or remote branch contains it, reusing `is_merged`.
  - The worktree hook calls both. Document them in `git wt --help` and the README.

---

## 3. Phases and parallelism

```
Phase 0  lead: branch, baseline
Phase 1  [WP1 core fixes] ∥ [WP2 test infrastructure] ∥ [WP3 P1 fixes outside core]
           merge order: WP3, WP1, WP2  → gate
Phase 2  [WP4 core refactors]  (serial: lib/common.sh is one file)  → gate
Phase 3  [WP5 Ubuntu] ∥ [WP6 macOS & apps] ∥ [WP7 shell & dev] ∥ [WP8 worktrees] ∥ [WP9 AI tools] ∥ [WP10 scripts]
           merge order: WP10, WP8, WP7, WP6, WP9, WP5 (smallest to largest), gate after each
Phase 4  [WP11 docs, AGENTS.md, check-docs]  (serial: shared docs)  → gate
Phase 5  lead: verification, Ubuntu VM run, hand-off
```

**How to run parallel WPs:**
1. Commit everything on `fix/review-findings` first, because worktree isolation copies committed state only.
2. Start each WP sub-agent in its own worktree (`Agent` with `isolation: "worktree"`, or T3 `delegate_task` with `isolation: "worktree"`), on a branch `wp/<n>-<slug>` from the current tip.
3. Give each sub-agent its WP section below, plus §1 and §2, as its brief.
4. Each sub-agent commits on its own branch and hands back.
5. The lead brings the branches in, in the stated merge order (`git rebase` onto the tip, then fast-forward, or `git cherry-pick`), resolving conflicts with the `resolving-merge-conflicts` skill. Run the gate after each merge.

**File ownership.** One owner per file per phase:
- In Phases 1 and 3, a WP touches only the files it owns.
- If a WP needs a change in a file it doesn't own, it writes the exact change in its hand-back under "Requests", and the lead applies it after merging.
- Nobody edits `lib/common.sh` or `tests/lib.sh` in Phase 3.
- `README.md` and `ai_tools/README.md` are split by section (see each WP). Edits to different sections merge cleanly.

**Hand-back format** (every sub-agent):
- **Commits:** subject lines and SHAs.
- **Findings:** each one done, skipped, or changed, with the reason.
- **Files touched.**
- **Tests:** added or updated.
- **Verification:** commands and results.
- **Requests:** changes needed in files the WP doesn't own.
- **Hand-off items:** anything the user must do by hand.

---

## 4. Work packages

### Phase 0: lead
1. Create the branch, check `main` is at `932abc7`, and copy the report and plan into `.scratch/`.
2. Run the baseline: `just check`, `just test`, and `time just test`. Record the results for the final hand-off. They should match the report: 61 passed, 1 skipped, 16 left out.

### WP1: core fixes (Phase 1)
**Owns:**
- `lib/common.sh`, `setup.sh`, `ai_tools/setup.sh`, `manual-steps.sh`, `justfile`
- `git/install.sh` and `tmux/install.sh`: only the `chmod 755` lines
- `ai_tools/claude-code/install.sh`: only the `chmod 755` line
- `homebrew/install.sh`: only `try_install_cask` and the gnupg prerequisite
- `docker/install.sh` and `ubuntu/lib/tailscale.sh`: only the fingerprint constants and the `add_apt_repo` calls
- Tests: `test-copy-file.sh`, `test-run-steps.sh`, `test-runner-flags.sh`, `test-apt-sources.sh`, `test-status.sh`, `test-just-status.sh`, `test-homebrew-install.sh`, and a new `test-root-file.sh` if needed

**Items:**
1. **#1 atomic copy**, per §2. Have `_copy_up_to_date` treat a missing exec bit as needing a copy, then remove the three `chmod 755` lines that follow `copy_file` (`git/install.sh:184`, `tmux/install.sh:137`, `ai_tools/claude-code/install.sh:246`), after checking that each exists only for the exec bit. Tests:
   - A `cp` stub that writes partial output and fails leaves the old destination whole.
   - The destination's inode changes after a copy.
   - A symlinked destination stays a symlink, and its target is updated.
   - A missing exec bit is restored.
   - An existing file's mode is kept.
2. **#5 interrupt:** per §2. Add a test that leaves no processes behind: once WP2 lands, use its `on_exit` hook, or a self-contained `trap`.
3. **#36:** exit status 3 disambiguation, with a test.
4. **#18 / #29 `add_apt_repo`:**
   - Add an expected-fingerprint argument, and check the downloaded key with `gpg --show-keys --with-colons`. Take the first `fpr` record's field 10, uppercase, with no spaces.
   - On a mismatch, fail before writing anything, and print the expected and actual fingerprints plus what to update.
   - Apply the `previous == content` rollback fix (#29).
   - Inline `restore_apt_key`.
   - Add `DOCKER_KEY_FPR` and `TAILSCALE_KEY_FPR` (D6), and update both callers.
   - Add `gpg` to `UBUNTU_COMMANDS`, and its package to the homebrew step's apt list. In an `ubuntu:26.04` container, check which package provides `gpg` and that the `--with-colons` output parses as expected.
   - Tests: a mismatched key fails before any write, a matching key proceeds, and the rollback case.
5. **#32 primitive:** the optional group argument on `install_root_file` and `write_root_file`, with a test that sudo is called with `install -g <group>`.
6. **#39:** add `"elgato-stream-deck=/Applications/Elgato Stream Deck.app"` to `CASK_PKG_APPS`, and fix `install_cask`'s comment.
7. **`regex_escape` helper:** pull it out of `ensure_app_quit` (`:642-646`) for WP10.
8. **P4 core nits:**
   - `confirm_sudo_changes` says "Run this step from a terminal" only when `! is_interactive`.
   - `json_applied` wraps the filter with a newline.
   - `just check` skips tracked files deleted but not yet staged.
   - Add a bash-4-only grep guard (`mapfile|declare -A|\$\{[^}]*,,|\[\[ -v`) to the justfile's `check` recipe, over the same file list.

**Verify:** `just check`, then `just test copy-file run-steps runner-flags apt-sources status just-status homebrew-install`, then the full `just test`.

### WP2: test infrastructure (Phase 1)
**Owns:** `tests/lib.sh`, except lines 15-21 (WP4), plus `tests/run.sh`, `tests/sentinels.sh`, `tests/test-run-reviewer.sh`, `tests/test-write-back.sh`, `tests/test-step-failures.sh`, `tests/test-upgrade.sh` (the `TMPDIR` part only), `tests/test-zsh-config.sh`, `tests/test-zsh-guards.sh`, `tests/test-diagnostics-macos.sh`, and `tests/test-diagnostics-ubuntu.sh` (the subtest pattern only).

**Items:**
1. **#14(b):** an `on_exit` hook list in `tests/lib.sh` that `_sandbox_exit` runs. `test-run-reviewer.sh` registers `"$PKILL" -f "$SLEEP_PATTERN"` and `kill -- -$runner`. Check that a Ctrl-C or watchdog kill during `check_signal` leaves no processes.
2. **#14(c):** `export TMPDIR="$SANDBOX/tmp"` in `setup_sandbox`, created there. Remove `test-upgrade.sh`'s own `TMPDIR` handling.
3. **#14(d):** export `HOMEBREW_PREFIX="$SANDBOX/no-homebrew"`. In the zsh login-shell tests, append `path=("$STUB_DIR" $path)` to the sandbox `~/.zprofile`, and assert that `whence -p mise` is the stub.
4. **#14(e):** a shared sudo-exec stub helper that refuses any absolute path outside `$SANDBOX`, except `/dev/null`, `$STUB_DIR`, and `$REPO_DIR`. Adopt it in `test-step-failures.sh:71-73`. WP5 adopts it in the Ubuntu tests.
5. **#14(f):** `run.sh` exports a per-test base dir, `setup_sandbox` creates its sandbox under it, and `clean_test_dirs` removes it. Keep the path short enough for tmux's socket limit.
6. **#54:** reject a `TEST_JOBS` that isn't a positive integer.
7. **#55:** add `pgrep` to `SENTINELS`. `test-run-reviewer.sh` saves the real `pgrep` before `setup_sandbox`, as it does for `pkill`.
8. **S6 `subtest` helper** in `tests/lib.sh`, adopted in the six double-counting places in `test-diagnostics-{macos,ubuntu}.sh`.

**Verify:** the full `just test`. Then confirm `$TMPDIR` gained no files and that `ps` shows no new `sleep 7…`/`8…` or `run-reviewer.sh` processes.

### WP3: P1 fixes outside the core (Phase 1)
**Owns:** `git/bin/git-wt`, `tests/test-git-wt.sh`, `ai_tools/t3-code/install.sh` (drop-in write only), `tests/test-t3-service.sh` (drop-in cases only), `zsh/aliases.zsh`, `zsh/functions.zsh`, `ubuntu/lib/health.sh` (`reboot_packages` only), and `tests/test-ubuntu-step.sh` (the reboot case only).

Each item gets a regression test that fails before the change:
1. **#2 symlink compare** in `is_clean`, per §2. Test with real git, as the Codex reproduction did: equal target contents, different link targets, and `git wt prune` keeps the worktree.
2. **#3 drop-in** via `write_back`. The LaunchAgent moves to a repo plist in WP9. Test that a failed write leaves the old drop-in whole.
3. **#4 `please`**, per D12. Remove the alias, and add the function to `zsh/functions.zsh` next to the other functions. Update any README mention in Phase 4, or in WP7's zsh section.
4. **#6:** `reboot_packages` returns 0 when `.pkgs` is missing. Test `reboot-required` without `.pkgs`: status keeps going and reports the reboot.

### WP4: core refactors (Phase 2, serial)
**Owns:** `lib/common.sh`, `tests/lib.sh` (lines 15-21 and anything else needed), `setup.sh`, `ai_tools/setup.sh`, `editorconfig/install.sh` (reference conversion), `tests/test-config-steps.sh`, plus the cross-file moves listed below.

**Items:**
1. **S3:**
   - A default `main` in `lib/common.sh`, per D18.
   - `copy_step "<message>" <files-fn>`, which prints the message and runs the files function with `copy_file`.
   - `copy_status <files-fn>`, which runs the files function with `status_file`, then `status_result`.
   - Convert `editorconfig/install.sh` as the reference. Area WPs convert their own steps in Phase 3.
2. **S1:** `sudo_item` and its drivers, per §2, with a new unit test, `tests/test-sudo-items.sh`. The area WPs do the conversions.
3. **S4:**
   - Merge `copy_file`, `copy_file_ask`, and `_copy_up_to_date` into one `_copy_file <mode>`. Keep `copy_file` and `copy_file_ask` as thin wrappers, since they are passed as action names, and keep the `-e` vs `-s` difference.
   - Merge `backup_edited` and `maybe_backup` into one helper that takes the question and the no-terminal default. Keep the `.bak`-already-matches shortcut.
   - Drop `BACKUP_PATH`, and update `test-copy-file.sh:249`.
   - Drop the `CASK_APP_CACHE` layer. Update `ai_tools/t3-code/install.sh:697-699` to look the path up once and pass it to `t3_code_app_path` and `t3_code_renamed_app`.
   - **`step_args` path:** derive it from `${BASH_SOURCE[1]}`, and remove the re-exec workaround at `tests/lib.sh:15-21`. First grep the tests for assertions on an absolute `$0` or the usage line.
   - **Flag loop:** move the source-time loop (`:170-184`) into `check_args`. First grep that no step calls brew at load time before `step_args`.
   - **Inline single-use helpers:** `runner_args` and `_add_runner_step` into `runner_main`, `unknown_step` into `run_steps`, and `listed_cask_app` into `cask_state`.
   - **Move step-only helpers:** `periodic_daily` and `unattended_upgrades_on` to `ubuntu/lib/updates.sh`, and `mas_app_ids` to `homebrew/install.sh`. Update the tests that source them, including `test-unattended-upgrades.sh`.
   - **Shared usage text:** `runner_main` prints the runners' common usage lines, and each runner passes only its `--quick` sentence.
   - **`status_quick`:** add the helper, and convert all five `DOTFILES_STATUS_QUICK` checks (`docker/install.sh:142`, `ubuntu/lib/health.sh:141`, homebrew, t3-code, and any others found).
   - Drop the redundant `CDPATH=''` at `:7` and `:244`. Keep the ones in each script's own `source` line.
4. **`COPIED` flag:** `_copy_and_record` sets `COPIED=true` whenever it copies. Callers are converted in WP6.

**Verify:** the full `just test`. Also run `bash setup.sh --help` and `bash ai_tools/setup.sh --help`, which only print, and compare their usage output with before.

### WP5: Ubuntu, Docker, Chrome (Phase 3)
**Owns:**
- Code: `ubuntu/**`, `docker/**`, `chrome/**`
- Tests: `test-ubuntu-*.sh`, `test-ufw-*.sh`, `test-docker-*.sh`, `test-unattended-upgrades.sh`, `test-chrome.sh`, `test-status.sh` (`SBIN_PATH`), the Ubuntu parts of `test-diagnostics-ubuntu.sh`, and the new test files from the split
- README sections: "Ubuntu", "Running around the clock", "Manual steps → Ubuntu", "Check it works → Ubuntu"

**Items:**
- **Security and correctness:**
  - #7, per D5: update the README text that lists the ranges, and add a test that the old 172.16/12 rule now shows as broad.
  - #19 comments, per D7.
  - #20, per D8: the alert line and its test. The README alerts text goes in this WP's section.
  - #21, #22, and #23 (comment, plus the manual-step text about `tailscale set --ssh` and a tailnet policy without `root`).
  - #24, per D14(c).
  - #28, #30, #31, #32 (use the new group argument), #33, #34 per D14(b), and #35 (docs only).
  - **P4 Ubuntu nits:** drop the unused `{ n++ }`, hard-code `TAILSCALE_LIST`, and merge the duplicate password-login pending items.
- **S1:** convert the simple items in `ubuntu/install.sh` and `docker/install.sh` to `sudo_item`, keeping the output word for word, so the existing tests must pass unchanged. Then:
  - Move `status_sshd` and `status_ufw` into `ubuntu/lib/ssh.sh` and `ubuntu/lib/firewall.sh`.
  - Have `ufw_broad_ssh_rules` print `<source>\t<rule>`.
  - Add a root-copy helper pair for the smartd hook, UPS notifier, and ntfy lib.
  - Add `restore_sshd_drop_in`.
  - Use `nmcli -t -e no`.
  - Merge `main()`'s three "already set up" messages.
  - Compute `ups_state` once, and cache `in_vm` and `key_login` per run.
  - Add `ubuntu/lib/paths.sh` for `SMARTD_HOOK`, `UPS_NOTIFY`, and `NTFY_URL_FILE`, shared with `setup-alerts.sh`. The root hooks keep their hard-coded copies.
  - Inline `smartctl_cmd`.
- **S5 docker:** restore `daemon.json` from memory with `write_root_file`, so no `.dotfiles-bak` is left in `/etc/docker`.
- **S3:** convert the ubuntu, docker, chrome, and logitech steps (`logitech/install.sh` is shared with WP6; WP5 converts it, and WP6 writes its test).
- **#14(a) and S6 tests:**
  - Add `tests/ubuntu-sandbox.sh`, a helper that points all of `ubuntu/install.sh`'s system-path constants (`SBIN_PATH` included) into the sandbox. It fails if any constant still starts with `/etc`, `/var`, `/usr`, `/run`, or `/dev`.
  - Use it after every `load_script ubuntu/install.sh` in `test-ubuntu-step`, `test-status`, `test-ufw-recheck`, `test-diagnostics-ubuntu`, and `test-ubuntu-ups`.
  - Adopt WP2's sudo-exec stub (`test-ubuntu-step.sh:40-41,885-887`).
  - Split `test-ubuntu-step.sh` (#57) into 3 or 4 files by section, keeping the `# os: ubuntu` header.

**Verify:**
- The full `just test`, plus every Ubuntu test by name on macOS.
- In an `ubuntu:26.04` container: run the `ubuntu`, `docker`, and `chrome` steps as a non-root user, as far as a container allows without systemd (expect skips for systemd-only items), twice to show idempotency, then `--status`.
- Record what couldn't be exercised.

### WP6: macOS and apps (Phase 3)
**Owns:**
- Code: `homebrew/**`, `macos/**`, `hammerspoon/**`, `stream-deck/**`, `ghostty/**`, `zed/**`, `runtimes/**`. Not `logitech/install.sh`, which WP5 owns; WP6 only writes its test.
- Tests: `test-homebrew-*.sh`, `test-macos-*.sh`, `test-hammerspoon.sh`, `test-stream-deck*.sh`, `test-ghostty.sh`, `test-touch-id.sh`, `test-runtimes.sh`, and a new `test-logitech.sh` (#56)
- README sections: "First run → macOS", "What's included" (Brewfile-driven lists), "Fonts", "Ghostty", "Zed", "Stream Deck", "Hammerspoon", "Apps", "macOS defaults", "Touch ID for sudo", "Manual steps → macOS", "Check it works → macOS", "Runtimes"

**Items:**
- **#16 hotkeys,** per D9:
  - Before changing anything, read (never write) `defaults read com.apple.symbolichotkeys` to check that Ctrl+Opt+Cmd with Space, B, N, T, C, and E collide with nothing.
  - Update every README mention.
  - Stop the macos step disabling Ctrl+Opt+Space, and remove its status item.
- **#17 Dato,** per D10.
- **#9 macmon,** items (a) to (d): ownership by `child`, an `'error'` listener, an `existsSync` re-check with a single log line, and backoff after repeated non-zero exits. Add sampler tests for an async spawn error and for a delayed old exit.
- **Stream Deck and macOS fixes:**
  - #40 netstat regex `/^en\d+\*?$/`.
  - #41, per §2.
  - #42: re-check the frontmost app before the paste.
- **P4 macOS nits:**
  - `plugin.js` guards for unmapped targets and bad JSON.
  - `sampler.reset()` clears the sparkline history.
  - `tell application id … to activate` instead of `open -b` for a running Chrome.
  - Hammerspoon stops the old timer and keeps tasks in a table.
  - `build-profile.sh` uses `profile/.`.
  - Add a README note that Ghostty's global Cmd+\` is intended.
- **S5 Stream Deck:**
  - Merge `bin/open-app` into `bin/open-in`, and remove `plugin.js`'s `scripts` map.
  - The stream-deck step removes files in the installed plugin dir that the repo no longer has. Only inside that plugin dir, never anywhere else.
  - An SVG frame helper in `stats.js`.
  - Cache the last image per context and skip `setImage` when it's unchanged.
  - One `sysctl -n` call for pressure and swap.
  - The JXA takes the bundle ID through `run(argv)`.
  - Hammerspoon keeps copying `open-in`.
  - The profile manifests keep their action UUIDs.
- **S5 other:**
  - **Ghostty and Stream Deck copy flags:** use `COPIED` instead of `CONFIG_CHANGED` and `PLUGIN_CHANGED`.
  - **homebrew:** compute the `install_bundle` label once, and pass `install_casks`' known state to `install_cask`.
  - **pam.sh:** compute `reattach_source` once.
  - **App Store IDs:** derive them in `test-homebrew-main.sh:34` with `mas_app_ids`.
- **S1:** convert any of the macos step's simple items that follow the three-place pattern. Leave `set_default`/`status_default` alone if they don't.
- **S3:** convert these steps.

**Verify:**
- The full `just test`, and `node --check` on the JS.
- The temp-HOME recipe (twice, then `--status`) for `ghostty`, `zed`, `stream-deck`, and `hammerspoon`, but only where the step header says it doesn't change the system. Read the header first.
- `lua` isn't installed, so `test-hammerspoon` skips; say so in the hand-back.

### WP7: shell and dev tools (Phase 3)
**Owns:**
- Code: `zsh/**`, `tmux/**`, `git/**` except `git/bin/git-wt`, `vim/**`, `lazygit/**`, `editorconfig/**`, `ssh/**`
- Tests: `test-zsh-*.sh`, `test-tmux-*.sh`, `test-git-*.sh` except `test-git-wt.sh`, `test-signing.sh`, `test-ssh*.sh`, `test-vim.sh`
- README sections: "git" (except the `git wt` lines, which belong to WP8), "Commit signing", "lazygit", "SSH", "vim", "zsh", "tmux", "EditorConfig"

**Items:**
- **Fixes:**
  - #25 `IgnoreUnknown`, per §2.
  - #38 `generate_key`.
  - **P4 nits:** `typeset -U path;` at the start of the zshenv line, `SAVEHIST` matching `HISTSIZE` (50000), reword the `main.zsh:47-49` comment, and add `syntax on` in the vimrc.
- **S5 zsh PATH,** per D16:
  - First map today's effective PATH for each shell type and OS:
    - login and interactive shells
    - non-interactive login (`zsh -lc`)
    - `ssh host cmd`
    - `sh -lc`
    - a systemd user service
    - a tmux pane
  - Then make `zsh/path.zsh` produce the same PATH, deduplicated, with mise shims added statically for non-interactive shells (#43).
  - `~/.zprofile` and `~/.zshenv` (Ubuntu) get one managed line each. `~/.profile` keeps `merge_lines`. Leave `ubuntu/environment.d` alone.
  - Update `tests/test-zsh-path.sh`.
  - Write the exact old lines (from `main`'s `zsh/install.sh`) into the hand-back for the user to delete.
- **S5 other:**
  - **zsh setup functions:** replace `setup_zprofile`, `setup_profile`, and `setup_zshenv` with one `setup_lines`.
  - **zsh main.zsh:** inline `srcif`.
  - **tmux:** read `plugins.lock` once (keep the name `sync_tmux_plugins`).
  - **ssh:** compute `host_star_missing` once in `status_host_star`.
  - **git:** add a `git_file` helper in `git/lib/config.sh`, used by `git/install.sh` and `git/setup-signing.sh`.
- **S3:** convert these steps (lazygit and vim as config-only, using `copy_step`).

**Verify:**
- The full `just test`, and `zsh -n` on every `zsh/*.zsh`.
- The temp-HOME recipe (twice, then `--status`) for `zsh`, `vim`, `tmux`, `lazygit`, `editorconfig`, `git`, and `ssh` on macOS, with `TMUX_TMPDIR` set.
- The same in an `ubuntu:26.04` container.
- Print `zsh -lc 'echo $PATH'` and `zsh -ic 'echo $PATH'` before and after under the temp HOME, and show they're the same set.

### WP8: worktrees (Phase 3)
**Owns:** `git/bin/git-wt`, `ai_tools/claude-code/worktree-hook.sh`, `tests/test-git-wt.sh`, `tests/test-worktree-hook.sh`, and the `git wt` lines in README "git".

**Items:**
- #8 per-branch stamp, per §2, with a test where a recent unrelated fetch still triggers the refresh.
- #26: reject a base starting with `-`, with a test.
- S5: add `git wt base` and `git wt rm --delete-merged-branch` (§2), and have the hook use them. Remove the hook's own base-selection and branch-deletion code. Update `git wt --help` and the README lines.

**Verify:** `just test git-wt worktree-hook`, then the full `just test`.

### WP9: AI tools (Phase 3)
**Owns:**
- Code: `ai_tools/**` except `worktree-hook.sh`, plus `scripts/check-t3-settings.sh`, `scripts/check-claude-keys.sh`, and `scripts/claude-settings-keys.txt`
- Tests: `test-claude-*.sh`, `test-codex-*.sh`, `test-t3-*.sh`, `test-skills*.sh`, `test-statusline.sh`, `test-run-reviewer.sh` (after WP2), `test-wizard-env.sh`, `test-ai-*.sh`, `test-tool-homes.sh`
- Docs: all of `ai_tools/README.md` except "Check it works → Phone", and all skills READMEs

**Items:**
- **Fixes:**
  - #10, per §2, with a test for a heading inside `"""`.
  - #11, per §2.
  - #12: wizard says "offer to commit it"; diagnosing-bugs and architect add "if the user asks you to commit".
  - #37: correct the hook's `type` and `timeout` when our command is present, with a test.
  - D13: the Codex credentials mode check. Use the step's own Codex-home variable.
  - D14(a): T3 `reset-failed` on `start-limit-hit`. Update `test-t3-service.sh:218` and the README "T3 Code on Ubuntu" text.
- **P4 AI nits:**
  - The Codex trailing-comment placement, per §2.
  - `quickEntryShortcut.accelerator`.
  - `check-t3-settings.sh` strips `#…` comments before scanning.
  - Validate skill names against `^[a-z0-9][a-z0-9-]{0,63}$`, and read them with `while read`.
  - Drop the `T3_CODE_SERVER_FILTER` global.
- **Docs:**
  - D11: document every claude-desktop setting and the ChatGPT app keys.
  - #49: the yq wording.
  - #46: one list of T3 worktree-cleanup rules.
  - The skills README notes the Codex-only install when `CLAUDE_CONFIG_DIR` points elsewhere.
  - `engineering/README.md:25`: fix "every level checks every angle".
  - D15: the single line about code-review's origin.
- **Skills nits:**
  - `research`: the lead writes the findings file.
  - Clean up the `mktemp -d` dirs in code-review-stds-and-spec, rewrite-docs, and show-me-your-work.
  - show-me-your-work: say "no file in the repo".
  - code-review `--comment`: check lines against `gh pr diff`.
  - to-spec: add a "Testing decisions" seams slot.
  - tdd: skip the seams check-in when the spec records them, and mark it as an exception otherwise.
  - implement: pass the feature-checkout path to serial implementers, and use the review scope `<base>...<feature-slug>`.
  - interrogate: map effort `max` to `xhigh` for Codex, after checking Codex's documented values.

  Use the `writing-for-agents` skill, keep invocation in step, and run `scripts/check-skills.sh` through `just check`.
- **S5:**
  - **Keepable values:** put the shared code in `ai_tools/lib/keepable.sh`, per §2.
  - **T3 LaunchAgent:** move it into a repo plist, byte-identical to today's `printf` output.
  - **Skills reinstall:** pass only the skills with a non-empty `skill_problem` to `--skill`, run one `find` per run, and hash each skill once per run.
  - **Skills state:** merge it into one file, per D19.
  - **`notifications_pending`:** extract `apps` once and filter locally, keeping a fallback for when jq is missing.
- **S6:** one shared skills CLI test double, in `tests/skills-cli-stub.sh`, used by `test-skills.sh` and `test-skills-exclusions.sh`.
- **S3:** convert the AI tool steps.

**Verify:**
- The full `just test`.
- `bash scripts/check-ai-settings.sh`, which needs the real `claude` and `codex` CLIs. Run it only if its header says it doesn't touch the real `~/.claude` or `~/.codex`. Otherwise skip it and say so.

### WP10: scripts (Phase 3)
**Owns:** `scripts/upgrade.sh`, `scripts/test-ubuntu.sh`, `scripts/lib/markdown.sh`, `scripts/check-docs.sh` (everything except `stage_doc`), `scripts/lib/brew.sh`, `tests/test-upgrade.sh`, `tests/test-print-doc-section.sh`, a new `tests/test-smoke-patterns.sh`, and the README and `ai_tools/README.md` "Updating" sections (content changes only, no trim).

**Items:**
- #15, per §2.
- #27: print versions before and after.
- #58: run `brew cleanup` after the last cask, `mas`, and AI-tool upgrade.
- `upgrade.sh:90` uses WP1's `regex_escape`.
- `markdown.sh`:
  - Check reference-style links.
  - Accept `(path "title")`.
  - Skip links inside code fences.
- `check-docs.sh`:
  - Pick steps with `git ls-files`.
  - Add a `section <file> <heading>` helper.
  - Share a `runner_steps` helper with `test-run-steps.sh:119-124`.
  - Replace "The doc: (empty)" with a message naming the anchor it looked for.
- `test-upgrade.sh:174`: derive the App Store IDs.

**Verify:** `just check`, then the full `just test`.

### WP11: docs, AGENTS.md, check-docs (Phase 4, serial)
**Owns:** `README.md` (cross-cutting sections and the trims), `ai_tools/README.md` ("Check it works → Phone", the trims, Maintenance), `AGENTS.md`, `CLAUDE.md` if needed, and `scripts/check-docs.sh` (`stage_doc`).

**Items:**
- **Docs findings not done in Phase 3:**
  - #44: the Phone checklist starts with `/remote-control`.
  - #45: Ubuntu Server should also leave out `zed`, and the Zed cask still installs.
  - #47 and #52: AGENTS.md.
  - #50: Ghostty and Zed bindings.
  - #51: the Downloads sources.
  - #53: the AGENTS.md exception and "no guard" wording.
  - P4: "Top CPU" becomes "Top Process".
- **AGENTS.md** (load `writing-for-agents`):
  - Describe the new step shape (default `main`, `status`, `apply`, `copy_step`/`copy_status`), with the editorconfig or vim step as the template.
  - Describe `sudo_item`.
  - Replace the `rewrite_lines_in_order` mention to match `zsh/path.zsh`.
  - "Most are modified upstream copies."
  - Name both whole-file exceptions (Zed's JSONC files, and the copied CLAUDE.md and AGENTS.md).
  - "No migration code for files left by older versions of this repo; user edits are still preserved."
  - Add `info` to the status states.
  - "Can run on either OS."
  - Mention `just test <name>`.
  - Add the missing doc couplings (#52).
  - Split the "Scripts" bullet into sub-bullets.
  - Add a numbered new-step checklist.
  - Give the temp-HOME test command its own bullet.
- **S7 trims** (`README.md`, `ai_tools/README.md`):
  - Trim each section the report lists.
  - Explain Full Disk Access once.
  - Replace the "checked against <version>" notes with one Maintenance table.
  - Drop ai_tools first-run macOS step 2.
  - Loosen `stage_doc` in `scripts/check-docs.sh`, then trim both "Updating" sections, keeping every stage the user runs.
- Run the prose through `unslop`, and keep each README's first-run checklist to what a user does and sees.

**Verify:** `just check` (check-docs and check-skills must pass), then the full `just test`.

### Phase 5: lead
1. Run the full gate: `just check`, `just test`, and every test by name (`/bin/bash tests/run.sh $(ls tests/test-*.sh | xargs -n1 basename | sed 's/^test-//; s/\.sh$//')`).
2. Show idempotency for every config-only step on macOS with the temp-HOME recipe: a second run changes nothing, and `--status` reports `ok`, `skipped`, `unverified`, or `info`.
3. Run `just test-ubuntu` once. Fix what it finds, and re-run only after a fix.
4. Count the lines added and removed against `main` (`git diff --stat main`), and compare with the report's estimate.
5. Write the hand-off (below) in `.scratch/handoff.md`, and send it as the final message to the user. Don't commit it.

---

## 5. Hand-off for the user

The lead fills this in from the WP hand-backs.

**On machines already set up:**
- **zsh PATH:** delete the old managed lines, quoted word for word, from `~/.zprofile`, `~/.zshenv`, and `~/.profile` on the Mac and on the Ubuntu box (D16).
- **ufw on Ubuntu:** delete the old `172.16.0.0/12` SSH rule (`sudo ufw status numbered`, then `sudo ufw delete <n>`). Status flags it (D5).
- **ssh config:** add `IgnoreUnknown UseKeychain` above `UseKeychain yes` in `~/.ssh/config`'s Host * block. Status shows it as missing (#25).
- **Input source shortcut:** re-enable Ctrl+Opt+Space for "select next input source" in System Settings, if you want it back (D9).
- **Hotkeys:** the Hammerspoon hotkeys are now Ctrl+Opt+Cmd+Space, B, N, T, C, and E (D9).
- **Tailscale key:** confirm `TAILSCALE_KEY_FPR` on the server with `gpg --show-keys /usr/share/keyrings/tailscale-archive-keyring.gpg`, if it didn't come from Tailscale's docs (D6).
- **Skills state reset:** on the first skills run, each skill is re-recorded, a copy that doesn't match the repo is backed up before it's replaced, and any skill already removed from the repo is no longer offered for removal (D19).
- **Old orphaned test processes** from before WP2 are still running: PIDs 17222, 50028, 50772, 51503, 67352, 80405, 80574, 80577, 80598, and 83702. They're safe to `kill`.

**Also report:**
- **Results:** the test and `just test-ubuntu` results, plus anything that couldn't be exercised (systemd paths in containers, `test-hammerspoon` without `lua`, phone delivery).
- **Deviations:** every place the plan was departed from, and why.
