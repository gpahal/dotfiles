# Dotfiles review: final report, 2026-10-18

This report combines two independent, read-only reviews of commit `932abc7`: one by Claude Code, one by Codex. Duplicate findings are merged into one entry, and each entry says which review found it. Neither review changed anything in the repo.

**Bottom line:** neither review found credential exposure, remote code execution, or privilege escalation. The most important problems are:

- Two ways setup can lose data: config copies that overwrite in place, and `git wt prune` deleting a worktree whose ignored symlink points elsewhere.
- A truncated systemd drop-in could expose T3 Code on every interface.
- `please` can run the wrong command as root.
- Ctrl-C doesn't stop a run during a cask install.
- An Ubuntu status abort that silences the daily health alert.

The runner and step architecture should stay. The biggest simplification is to list each check once instead of three times, and to route every file write through one atomic helper. Both changes keep every feature.

**Priority scale**
- **P1:** fix first. Can lose data, weaken a security boundary, run something as root by mistake, or break a core path (setup, `--status`, the daily alert).
- **P2:** real defect, fix soon.
- **P3:** low impact or narrow trigger.
- **P4:** nit.

**Status:** *Confirmed* means reproduced, or traced through the code with no ambiguity. *Plausible* means the mechanism is clear, but the trigger depends on outside state. **Found by:** Both, Claude, or Codex.

---

## Summary of P1 and P2

| # | Pri | Finding | Where | Found by |
|---|-----|---------|-------|----------|
| 1 | P1 | Copied configs are overwritten in place; a failed copy leaves a broken file with no backup | `lib/common.sh:434-440` | Both |
| 2 | P1 | `git wt prune` deletes a worktree whose ignored symlink points to a different target | `git/bin/git-wt:292,337` | Codex |
| 3 | P1 | T3's systemd drop-in, the only thing keeping the server on loopback, is written non-atomically | `ai_tools/t3-code/install.sh:536-539` | Claude |
| 4 | P1 | `please` can run the wrong command as root | `zsh/aliases.zsh:54` | Claude |
| 5 | P1 | Ctrl-C during a cask install doesn't stop the run | `lib/common.sh:1352-1358`, `run_steps` | Claude |
| 6 | P1 | Ubuntu `--status` and the daily alert abort when `reboot-required` exists without `.pkgs` | `ubuntu/lib/health.sh:224-226` | Claude |
| 7 | P2 | Docker containers can reach the host's sshd while password logins are on | `ubuntu/install.sh:131` | Claude |
| 8 | P2 | The worktree hook skips refreshing `origin/main` after an unrelated fetch | `ai_tools/claude-code/worktree-hook.sh:64-68` | Codex |
| 9 | P2 | macmon spawn errors crash the whole Stream Deck plugin, and an exit race orphans processes | `stats.js:90-120` | Both |
| 10 | P2 | The Codex step refuses a valid config for good when a multi-line string has a `#` line | `ai_tools/codex/install.sh:170-172,202-210` | Claude |
| 11 | P2 | interrogate's Codex reviewer can read any file you can | `interrogate/scripts/run-reviewer.sh:89-95` | Claude |
| 12 | P2 | Skills tell agents to commit without being asked | `wizard/SKILL.md:44` and others | Claude |
| 13 | P2 | The Claude app's Cowork browser tools are turned on and undocumented | `ai_tools/claude-desktop/install.sh:38-50` | Claude |
| 14 | P2 | The test sandbox leaks onto the host (orphaned processes, `TMPDIR`, real tools, real system paths) | `tests/lib.sh`, several tests | Claude |
| 15 | P2 | `just test-ubuntu` fails on correct behavior: its assertion doesn't match the status message | `scripts/test-ubuntu.sh:352` | Codex |
| 16 | P2 | Hammerspoon's Ctrl+Opt+T/C/E clash with Rectangle's default shortcuts | `hammerspoon/init.lua:19,111-113` | Claude |
| 17 | P2 | Skipping Dato, which the README allows, means `just status` is never clean | `homebrew/install.sh:274-276` | Claude |

---

## P1: fix first

### 1. Copied configs are overwritten in place, with no backup on failure
**P1 · data loss / robustness · Confirmed · Both** · `lib/common.sh:434-440` (`_copy_and_record`); backup choice at `:452`

- **What:** `_copy_and_record` runs `cp "$src" "$dest"` against the live destination, which truncates and rewrites the same inode. A file that still matches its recorded hash is replaced without a backup.
- **Scenario 1, partial write:** if the copy fails after truncating, the step reports failure but leaves a broken config with no backup. Codex reproduced this with the real `record_installed` and `copy_file` and a copy that wrote partial output, then failed: `copy status=1 dest=partial backup_count=0`. This affects ordinary configs such as the zsh files. On a later run, the cut-short file is taken for a hand edit and backed up.
- **Scenario 2, running scripts:** bash reads a script while it runs, so rewriting one mid-run makes it execute fragments of the new text (a demo printed `er: command not found`). Affected: `statusline.sh` (runs every 5 s while Claude Code is open), `git-wt`, `worktree-hook.sh`, and `tmux-sessionizer`, for example a sessionizer popup waiting in fzf while `bash setup.sh tmux` runs in another pane.
- **Related:** `copy_file` says "already up to date" when only the exec bit is missing, while `status_file` (`:1243`) reports it missing. That's why git, tmux, and claude-code each `chmod 755` after `copy_file` (`git/install.sh:184`, `tmux/install.sh:137`, `ai_tools/claude-code/install.sh:246`).
- **Fix:**
  - Stage the copy in a temp file beside the destination, and rename it into place only after the copy succeeds, as `write_back` (`:968`) already does.
  - Keep: symlink targets, existing permissions, the source's exec bit for new files, the backup choices, and hash recording after success.
  - Don't pass a repo source straight to `write_back`; it removes its input file.
  - Have `_copy_up_to_date` check the exec bit too, then drop the three `chmod 755` lines.
  - Extend the copy-failure tests to check that the old destination survives a partial write.

### 2. `git wt prune` deletes a worktree whose ignored symlink points elsewhere
**P1 · data loss · Confirmed · Codex** · `git/bin/git-wt:292` (`is_clean`); deletion at `:337`

- **What:** automatic pruning treats an ignored file as disposable when its contents match the main checkout's. `cmp -s` follows symlinks. A main checkout with `.env -> environment-a` and a worktree with `.env -> environment-b` therefore compare equal when the two environment files happen to have the same bytes. The worktree's different environment choice is lost when it's deleted. This can happen in the hook's session-end cleanup, with no forced removal.
- **Verified** with real git in a temp repo: both environment files tracked and identical, `.env` ignored, the hook's ownership marker present, and the branch contained in another branch. `git wt prune` removed the worktree and the branch despite the different link targets.
- **Fix:** compare file types first. For symlinks, compare `readlink` values; for regular files, compare bytes. Keep the existing exception for identical copied files. Add a regression test with equal target contents and different link destinations.

### 3. T3's drop-in (and telemetry LaunchAgent) are written non-atomically
**P1 · security / robustness · Plausible · Claude** · `ai_tools/t3-code/install.sh:536-539`; the same pattern at `:265-266` for the LaunchAgent

- **What:** the drop-in is written with `printf … > "$T3_CODE_SERVICE_DROP_IN"`. It carries `T3CODE_TELEMETRY_ENABLED=false`, `T3CODE_PORT`, and `T3CODE_HOST=127.0.0.1`, and it's the only thing keeping the server on loopback. ufw lets the tailnet reach every port. T3 0.1.0 reads `T3CODE_HOST` (precedence: flag, then env, then bootstrap), and the launcher passes its environment to `serve`, so the env approach works.
- **Scenario:** a full disk or I/O error cuts the file short after the port line. The step reports failure and doesn't start the service. But the unit is enabled and linger is on, so at the next boot systemd starts the server listening on every interface. `install_root_file`'s own comment (`lib/common.sh:78-82`) warns about exactly this for drop-ins.
- **Fix:** write both through `write_back` (temp file in the same directory, then `mv`).

### 4. `please` can run the wrong command as root
**P1 · security / correctness · Confirmed · Claude** · `zsh/aliases.zsh:54`

- **What:** `alias please='sudo zsh -c "$(fc -ln -1)"'` with `hist_ignore_space` on (`zsh/history.zsh:10`). A line typed with a leading space is dropped from history when the next line is entered.
- **Scenario:** `echo first`, then ` echo spaced` (leading space, as typed to hide a secret), then `please`. This runs `echo first` as root without showing it. Reproduced under ZLE through a pty.
- **Fix:** make it a function that prints the command and asks first:
  ```zsh
  please() { local c; c="$(fc -ln -1)"; print -r -- "sudo: $c"; read -q "?Run as root? [y/N] " && { echo; sudo zsh -c "$c"; }; }
  ```

### 5. Ctrl-C during a cask install doesn't stop the run
**P1 · correctness · Confirmed · Claude** · `lib/common.sh:1352-1358` (`interrupted_status`), `:1393-1395` (`run_steps`); triggered at `ai_tools/claude-desktop/install.sh:94` and `ai_tools/codex/install.sh:411`

- **What:** `run_steps` spots an interrupt only from the step's exit code (129, 130, or 143). brew catches SIGINT and exits 130, which is a normal exit, so the step's bash carries on, and `install_cask … || result=1` turns the 130 into 1. The runner also got SIGINT, but bash assumes a child that exited normally handled it, so the runner carries on too. `homebrew/install.sh:200-205` (`try_install_cask`) already works around this by hand; the other callers don't.
- **Scenario:** Ctrl-C during `brew install --cask claude` in `bash ai_tools/setup.sh`. claude-desktop goes on to copy files and run `configure_claude_desktop`, which may offer to quit Claude, then exits 1. The runner then starts `codex`, which runs `brew install --cask chatgpt`.
- **Verified** under `/bin/bash` 3.2 with a SIGINT-catching child that exits 130, and `kill -INT` sent to the process group. With `trap 'interrupted=1' INT` in the runner, the run stopped with 130.
- **Fix:** set `trap 'RUN_INTERRUPTED=1' INT TERM HUP` in `run_steps` and stop after any step once it's set. Keep `interrupted_status` for `scripts/upgrade.sh`. Move `try_install_cask`'s `[ "$status" -le 128 ] || exit "$status"` into `install_cask`, then delete the special case.

### 6. Ubuntu `--status` and the daily alert abort on `reboot-required` without `.pkgs`
**P1 · correctness · Confirmed · Claude** · `ubuntu/lib/health.sh:224-226`; called at `ubuntu/install.sh:259-261`

- **What:** `reboot_packages` is `sort -u "$REBOOT_REQUIRED.pkgs" 2>/dev/null | join_lines ', '`. Under `set -euo pipefail`, a missing `.pkgs` makes `sort` exit 2, and the bare assignment `packages="$(reboot_packages)"` kills `status` with exit 2. The `${packages:+…}` that follows shows the empty case was meant to work. Reproduced under `/bin/bash`.
- **Scenario:** `notify-reboot-required` runs outside dpkg (without `DPKG_MAINTSCRIPT_PACKAGE`), or something just touches the file. `just status` reports "The ubuntu step failed". Every item after that point is dropped: openssh, the drop-in, effective sshd settings, password logins, Tailscale, ufw and broad-rule checks, Wake-on-LAN, disk space, and firmware. The same happens in the daily health alert, so the security checks go silent.
- **Fix:** start `reboot_packages` with `[ -f "$REBOOT_REQUIRED.pkgs" ] || return 0`, and add a test. Only the case with `.pkgs` present is tested (`tests/test-ubuntu-step.sh:307`).

---

## P2: fix soon

### 7. Docker containers can reach the host's sshd
**P2 · security · Confirmed (rule semantics) · Claude** · `ubuntu/install.sh:131` (`SSH_RANGES`); `docker/install.sh:33-35`

- **What:** `SSH_RANGES` allows SSH from 172.16.0.0/12, which contains Docker's bridges (172.17/16 for the default bridge, 172.18 and up for user networks). The docker comment "ufw also blocks containers from reaching ports on the host" is wrong for SSH.
- **Scenario:** until a key login is proven, password logins are on. Any container, such as an agent-run image, can brute-force `172.17.0.1:22` for your password.
- **Fix:** add `ufw deny in on docker0 to any port <ssh>` (and the same for `br-+`) ahead of the range rules, or document that containers can reach sshd.

### 8. The worktree hook branches from a stale `origin/main` after an unrelated fetch
**P2 · correctness · Confirmed · Codex** · `ai_tools/claude-code/worktree-hook.sh:64-68` (`fetched_recently`), called at `:85`

- **What:** any recent, non-empty `FETCH_HEAD` counts as proof the default branch is fresh. Fetching a feature branch or another remote therefore suppresses the refresh of `origin/main`, even when that ref is days old, and frequent unrelated fetches keep satisfying the check. This is different from accepting 10 minutes of staleness after fetching the right branch.
- **Verified** with local repos only: advance the remote's main, fetch just its feature branch, then run the real `fetch_default_branch` and `fresh_base`. The hook skipped the refresh and picked the old main commit; `FETCH_HEAD` named the feature branch.
- **Fix:** accept the cached timestamp only when it records a successful fetch of the selected origin branch. Either check that entry in `FETCH_HEAD`, or keep a small record for that fetch. Keep the existing deadline and offline fallback. Add a recent-unrelated-fetch case to the worktree-hook tests.

### 9. macmon process handling: spawn errors crash the plugin, and an exit race orphans processes
**P2 · robustness · Confirmed · Both** · `stream-deck/com.gpahal.dotfiles.sdPlugin/stats.js:90-120` (spawn at `:97`)

- **(a) Spawn errors crash the plugin.** Confirmed by Codex. The sampler checks that macmon exists, then spawns it with no `'error'` listener. A binary that exists but isn't executable, or one removed between the check and the spawn during an upgrade, raises an async error. That error kills the whole Stream Deck plugin, including the unrelated app-launch keys. The `try/catch` around `await sampler.sample(...)` can't catch it. Verified with Node's real `spawn` against a non-executable temp file: Node exited 1 with `Unhandled 'error' event` / `EACCES`.
- **(b) An exit race orphans processes.** Confirmed by Codex, found by both. Stopping kills macmon and clears its reference at once. If sampling restarts before the old process emits `exit`, the old exit callback clears the *replacement's* reference. The next sample starts a third process, and cleanup can't stop the untracked one. Verified through the plugin's real appear and disappear handlers with controlled timers: `{"spawned":3,"killed":[true,false,true]}`, which left the middle process running.
- **(c) "needs macmon" never clears.** Once macmon is installed, the GPU, temperature, and power keys keep showing "needs macmon" until Stream Deck restarts. Claude, confirmed.
- **(d) A crashing macmon respawns and logs every 2 s.** Claude, confirmed.
- **Fix:**
  - `const child = spawn(...)`, and change shared state only while `macmon === child`, including in stale data callbacks.
  - Add `child.on("error", …)` that logs and clears only that child's state, leaving room for a later retry.
  - Re-check `existsSync` on each start, and log the missing binary once.
  - Back off after repeated non-zero exits.
  - Add sampler tests for an async spawn failure and for an old exit delayed past the replacement's start.

### 10. The Codex step refuses a valid config for good when a multi-line string has a `#` line
**P2 · correctness · Confirmed · Claude** · `ai_tools/codex/install.sh:170-172` (`comment_lines`), `:202-210`

- **What:** the "yq dropped comments" check counts every line matching `^\s*#`, including lines inside `"""` and `'''` strings, which yq turns into one-line `"...\n..."` strings. The edited copy has fewer "comments", re-appending the tail can't make up the difference, and the step refuses on every run with a misleading message.
- **Scenario,** reproduced in a temp `HOME`. Markdown headings in `developer_instructions` are a realistic case:
  ```toml
  developer_instructions = """
  # Style
  Be brief.
  """
  ```
  Every run fails with "yq would drop comments from …/config.toml while editing it; leaving it unchanged." The multi-line test at `tests/test-codex-config.sh:118` has no `#` line.
- **Related weakness:** the check compares counts, not content. If a future yq kept the tail but dropped a mid-file comment, re-appending the tail would even out the counts. One comment would be lost, the tail duplicated, and the check would pass.
- **Fix:** extract full-line comments outside triple-quoted strings with a small awk (toggle a flag on lines with an odd number of `"""` or `'''`). Then check that the edited file's list equals the source's, or contains it, with `comm`/`sort` on trimmed lines. Add the heading-inside-`"""` case to the test.

### 11. interrogate's Codex reviewer can read any file you can
**P2 · security · Confirmed · Claude** · `ai_tools/skills/engineering/interrogate/scripts/run-reviewer.sh:89-95`

- **What:** the script runs `codex exec … -c 'approval_policy="never"' … --sandbox read-only`. Its own comment says instructions planted in a reviewed diff could get a secret quoted into the answer. The Claude reviewer is confined (`--restricted`, only Read/Grep/Glob, `dontAsk`); the Codex one isn't. `interrogate/SKILL.md:69` says only "runs that family's CLI read-only". `show-me-your-work --check` uses the same runner.
- **Fix:** say this in SKILL.md, tell the lead not to run it on untrusted PRs, or run it with a scrubbed `HOME` or in a container.
- **Related, P4:** only an out-file under the prompt directory is rejected (`:60-66`). One under the repo root isn't, so with misuse, reviewers could read each other's answers. Consider rejecting paths under `$root` too.

### 12. Skills tell agents to commit without being asked
**P2 · safety · Confirmed · Claude** · `ai_tools/skills/engineering/wizard/SKILL.md:44`; also `diagnosing-bugs/SKILL.md:116,134` and `architect/SKILL.md:50`

- **What:** wizard says "If it's a repeatable setup path, commit it and link it from the README". That breaks `ai_tools/user-instructions.md:4` ("Commit, push, or open a pull request only when the user asks"). wizard is model-invoked, so this can happen without anyone typing `/wizard`, though line 12 of the skill is more careful. diagnosing-bugs ("Record it in … the commit message") and architect ("can ship as its own commit") assume a commit gets made too.
- **Fix:** "If the user wants it kept, link it from the README and offer to commit it." In the other two, add "if the user asks you to commit".

### 13. The Claude app's Cowork browser tools are on and undocumented
**P2 · security / docs · Confirmed · Claude** · `ai_tools/claude-desktop/install.sh:38-50`; `ai_tools/README.md:104`

- **What:** the step sets `coworkBrowserToolsEnabled = true` with `coworkPreferredBrowser = "chrome"`. It also sets `ccKeepAwakeOnBattery`, `ccdScheduledTasksEnabled`, `coworkScheduledTasksEnabled`, `coworkWebSearchEnabled`, and `quickEntryShortcut`. The README lists only dock bounce, keep-awake, archiving, and the menu bar. With the Cowork setting, agents act in your signed-in Chrome, and nothing says so.
- **Fix:** document all of them, the browser tools and scheduled tasks above all, or make the browser tools opt-in.
- **Related, P3:** `ai_tools/README.md:141` also omits several ChatGPT app keys `ai_tools/codex/install.sh` writes: `worktree-upstream-refresh-mode = never`, `ambient-suggestions-enabled`, `conversationDetailMode`, `show-context-window-usage`, and `enabled-reasoning-efforts`.

### 14. The test sandbox leaks onto the host
**P2 · test safety / hygiene · Confirmed · Claude**

- **(a) Real system paths in `test-ubuntu-step`.** `tests/test-ubuntu-step.sh:663-686` re-points 11 constants after its second `load_script ubuntu/install.sh`, but not `REBOOT_REQUIRED` or `NTFY_URL_FILE`. They go back to `/var/run/reboot-required` and `/etc/dotfiles/ntfy-url`. On an Ubuntu host with a pending reboot (routine after kernel updates), the `status` assertions at lines 779, 892, 916, 956, 962, and 969 get 3 or 2 instead of the expected code; pointing the default at an existing file failed line 779. `test-status.sh:68` also loads the step without `SBIN_PATH`, so `sbin_cmd` resolves `sysctl` and `smartctl` by absolute path, bypassing their sentinels. That's harmless today only because the calling functions are replaced.
- **(b) Orphaned processes.** `tests/test-run-reviewer.sh:27,57-69` starts the runner under `set -m` (its own process group) with sleeps of `7$$` and `8$$` seconds, which is 8 to 10 days. `run.sh`'s watchdog and Ctrl-C handler kill only the test's own group, and `_sandbox_exit` stops only tmux servers, so a timeout or Ctrl-C leaves them running. These leftovers are live on this Mac now (see Housekeeping).
- **(c) `TMPDIR` isn't sandboxed.** `setup_sandbox` (`tests/lib.sh:61`) leaves `TMPDIR` alone. `write_back` keeps its temp file on failure by design, and `test-write-back.sh:75-89` never removes it, so each run leaves a 4-byte file in the real `$TMPDIR` (72 now). Every `mktemp` in step code under test lands there too.
- **(d) Login-shell zsh tests run real host tools.** `zsh -l` runs `/etc/zprofile`'s `path_helper`, which puts `/etc/paths` (including `/opt/homebrew/bin`) ahead of the stub dir. `setup_sandbox` also keeps the inherited `HOMEBREW_PREFIX=/opt/homebrew`, which `zsh/main.zsh:58` moves to the front. In `test-zsh-config.sh:31-41`, `whence -p mise` was `/opt/homebrew/bin/mise` and `stub mise` (line 24) was never used. Only read-only init runs today, against the sandbox `HOME`, but any sentinel command the zsh config ran at startup would run for real. `test-zsh-guards.sh:41,56,62` has the same shape.
- **(e) sudo stubs that exec their arguments** refuse only `/etc/*`, `/run/*`, and `/dev/*` (`test-ubuntu-step.sh:40-41,885-887`); the one in `test-step-failures.sh:71-73` refuses nothing. `UPS_NOTIFY` and `NTFY_LIB` (`/usr/local/...`), `UPOWER_HWDB` and `UPS_RTC_HOOK` (`/usr/lib/...`), and `TAILSCALE_KEYRING` fall outside those prefixes. A missed re-point like (a) would run `install …` as you wherever `/usr/local` is writable.
- **(f) Stale sandboxes.** The sandbox lives outside `run.sh`'s per-test directory (`tests/lib.sh:42`, `tests/run.sh:110-117`), so a test killed by the watchdog's SIGKILL leaves `/tmp/dotfiles-test.*` behind (13 from Oct 10 to 18).
- **Fix:**
  - One helper that points all 19 system-path constants of `ubuntu/install.sh`, `SBIN_PATH` included, into the sandbox. Call it after every `load_script`, and fail if any constant still starts with `/etc`, `/var`, `/usr`, `/run`, or `/dev`.
  - An `on_exit` hook list in `tests/lib.sh` that `_sandbox_exit` runs (tests can't set their own EXIT trap). `test-run-reviewer` registers `"$PKILL" -f "$SLEEP_PATTERN"` and `kill -- -$runner` there.
  - `export TMPDIR="$SANDBOX/tmp"`. All 78 tests pass with it, and `test-upgrade.sh`'s own `TMPDIR` handling can go.
  - Export `HOMEBREW_PREFIX="$SANDBOX/no-homebrew"`; all tests pass with it, but on its own it doesn't beat `path_helper`. Also append `path=("$STUB_DIR" $path)` to the sandbox `~/.zprofile` in those tests, and assert `whence -p mise` is the stub.
  - A shared sudo-exec stub that refuses any absolute path outside `$SANDBOX`, except `/dev/null`, `$STUB_DIR`, and `$REPO_DIR`.
  - Have `run.sh` export a per-test base dir, run `setup_sandbox`'s `mktemp -d` under it, and have `clean_test_dirs` remove it. This stays well under tmux's socket path limit.

### 15. `just test-ubuntu` fails on correct behavior
**P2 · test correctness · Confirmed · Codex** · `scripts/test-ubuntu.sh:352`; message from `ai_tools/t3-code/install.sh:336-340`

- **What:** the VM smoke test greps for `a t3 serve started by hand;`, but the status line is `PID <pid>, a t3 serve started by hand (<command>); to fix it, …`. A correctly detected hand-started server fails the assertion and sets the VM run's failure flag. Codex ran the real formatter against the exact regex, without a VM: no match. The unit test at `tests/test-t3-service.sh:193` already expects the parenthesized command, which is why it passes.
- **Fix:** match the stable prefix, or include the command part. Exercise the assertion against the real formatter in a lightweight test, so an output change doesn't need a full VM run to surface.

### 16. Hammerspoon hotkeys clash with Rectangle
**P2 · correctness · Confirmed overlap; which app wins is plausible · Claude** · `hammerspoon/init.lua:19` (`MODS = { "ctrl", "alt" }`), `:111-113`; `README.md:411`

- **What:** Rectangle's "Recommended" set binds Ctrl+Opt+C (Center), Ctrl+Opt+E (First Two Thirds), and Ctrl+Opt+T (Last Two Thirds). The homebrew step installs Rectangle (`homebrew/install.sh:44`). This Mac has `alternateDefaultShortcuts = 1` with no overrides, and Rectangle is running, so both apps hold these keys. Each key goes to whichever app registered first, so either the Terminal, T3 Code, and Editor hotkeys or Rectangle's actions silently do nothing.
- **Fix:** move `MODS` to `{ "ctrl", "alt", "cmd" }` (Rectangle uses that only with arrows), or tell the user in manual step 8 to pick Rectangle's Spectacle preset or clear those three keys.

### 17. Skipping Dato means `just status` is never clean
**P2 · docs / correctness · Confirmed · Claude** · `homebrew/Brewfile:89`, `homebrew/install.sh:274-276`, `README.md:28,412,477`

- **What:** `README.md:28` says "Buy it only if you want Dato … `--status` lists them as missing". `:477` says the check passes when `just status` prints no **Needs attention** line. But the Brewfile lists `mas "Dato"` unconditionally, and status reports it with `status_item missing`, which sets `STATUS_NEEDS_ATTENTION`. Anyone who skips Dato can never pass the check. Manual step 9 (`:412`) also assumes Dato.
- **Fix:** report an unowned paid App Store app as `info` or `skipped` (or make Dato opt-in per machine), or say plainly that Dato is required for a clean status.

---

## P3: low impact or narrow trigger

Ordered: security first, then correctness, then docs, then tests and tooling.

### Security

18. **Apt signing keys and Chrome's first `.deb` are trusted on TLS alone.** Confirmed (by design), Claude. `add_apt_repo` (`lib/common.sh:862-871`), used by `docker/install.sh:17-18,76-78` and `ubuntu/lib/tailscale.sh:42-45`, re-downloads the key on every re-add (for example after a release upgrade) with no fingerprint check. Chrome's first install is an unsigned `.deb` over HTTPS (`chrome/install.sh:42-57`). Signed-By scoping limits the blast radius to that repo, but a CDN or key-URL compromise at re-add time swaps the trusted key, and unattended-upgrades then installs from it as root. **Fix:** pin each repo's fingerprint and check it before `install_root_file`, e.g. `gpg --show-keys --with-colons "$key" | grep -q "^fpr:::::::::$FPR:"`. Docker's is `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`; check Tailscale's against its docs.
19. **The ntfy URL file is world-readable.** Confirmed, Claude. `ubuntu/setup-alerts.sh:65-71` writes `/etc/dotfiles/ntfy-url` 0644, while `ubuntu/lib/ntfy.sh:9-11` keeps the URL out of argv "since any user can read a process's arguments". Any local account or service (`www-data`, a compromised daemon) can read the topic and then read or spoof alerts, which describe security posture ("ufw rule lets SSH in from anywhere", "password logins on"). **Fix:** `0640 root:<group>` with you and `nut` in the group (or `setfacl u:$USER:r,u:nut:r`), or reword the comments to say argv hiding only keeps it out of `ps` and diagnostics.
20. **The daily health alert can't see any sudo-only check.** Plausible, Claude. sudo timestamps don't reach a systemd user service (`ubuntu/lib/alerts.sh:17-21`), so the `sudo_cached`-gated checks (`ubuntu/install.sh:276,286,328`, `ubuntu/lib/health.sh:92`, `ups.sh`'s `nut_read`) come back `unverified` in the timer run, which never alerts. That covers broad ufw SSH rules, sshd settings overridden by another file, SMART health, and the NUT files. A `sudo ufw allow 22/tcp` or a package's sshd override goes unreported. **Fix:** a small root system timer that writes a root-only summary the user alert reads, or a NOPASSWD sudoers entry limited to `ufw status`, `sshd -T -C …`, and `smartctl -H`. Otherwise, document the gap.
21. **ufw counts as "on" even when it isn't filtering IPv6.** Plausible (needs non-default config), Claude. `ufw_enabled` (`ubuntu/lib/firewall.sh:8-12`) checks only `ENABLED=yes` and the IPv4 default policy. With `IPV6=no` in `/etc/default/ufw`, sshd is reachable on the global IPv6 address while status says "ufw on, denying incoming connections". **Fix:** also require `IPV6=yes`, or report `missing`.
22. **Docker networks created before setup still publish on 0.0.0.0**, bypassing ufw, and status doesn't check. Confirmed (the comment at `docker/install.sh:36-38` says so), Claude. **Fix:** a read-only status item listing container ports bound to `0.0.0.0` or `::` from `docker ps --format '{{.Names}} {{.Ports}}'` while the daemon runs.
23. **Operator rights let any process running as you turn on Tailscale SSH.** Plausible (depends on tailnet policy), Claude. As operator, any such process can `tailscale set --ssh`, which bypasses sshd's AllowUsers and key-only settings, and Tailscale's default policy allows `root` in check mode. `ubuntu/lib/tailscale.sh:5-8` mentions only `funnel`. **Fix:** mention `--ssh` in the comment and the manual step, and suggest a tailnet policy without `root` in `users`.
24. **The docker group can't be declined on its own.** Confirmed, Claude. One yes/no covers every item in `docker/install.sh:311,333`, though the pending text calls the group root-equivalent. **Fix:** give the group its own `confirm`, so you can install Docker and use `sudo docker`.
25. **`UseKeychain yes` without `IgnoreUnknown UseKeychain`.** Plausible (the failure is certain; the trigger is outside the repo), Claude. `ssh/install.sh:44,62`. Only Apple's ssh knows `UseKeychain`. With `brew install openssh` (say, for security keys), Homebrew's bin comes before `/usr/bin`, and portable OpenSSH stops with "Bad configuration option: usekeychain", breaking ssh and git over SSH for every host. **Fix:** write `IgnoreUnknown UseKeychain` before it; `host_star_missing` already skips lines that are present.
26. **`git wt add <name> <base>` passes an option-looking base straight to git.** Confirmed, Claude. `git/bin/git-wt:191`. `check_name` rejects `-*` names, but not `$base`, and git takes options after positionals. `git wt add foo --lock` exits 0 and makes a locked worktree that `git wt rm -f foo` can't remove (that needs `--force` twice) and `prune` can't either; `--force` and `--detach` get through too. **Fix:** `case "$base" in -*) die …; esac`, or `--end-of-options` before `"$path"`.
27. **upgrade-ai-tools updates every Claude Code plugin and marketplace unreviewed.** By design, Claude. `scripts/upgrade.sh:200-231` also runs `codex plugin marketplace upgrade`. Plugins can add hooks that run as you. By contrast, `bump-plugins` pins SHAs and prints compare links, and its result is committed. **Fix:** print each plugin's version before and after, or make plugin updates opt-in.

### Correctness and robustness

28. **The sysctl check never settles when another file sets a different value.** Confirmed, Claude. `sysctl_in_effect` (`ubuntu/lib/power.sh:22-30`; `ubuntu/install.sh:231-236,397-401,475-478`) requires an exact match. A JetBrains `/etc/sysctl.d/idea.conf`, or any `9x-*.conf`, setting `fs.inotify.max_user_watches`, even higher, makes every run list "Put … in effect", ask for sudo, run `sysctl --system` to no effect, and print "Applied". Status says "re-run the ubuntu step" forever, and the daily alert nags. **Fix:** compare the inotify keys with `>=`. When a key still differs after `--system`, name the file that sets it (`grep -rl <key> /etc/sysctl.d /usr/lib/sysctl.d /etc/sysctl.conf`).
29. **`add_apt_repo` can roll back to an unverified source.** Confirmed, Claude. `previous` is whatever's on disk at the start (`lib/common.sh:854-856`), and on a held lists lock the new file and key are kept (`:886-890`). On a fresh install where Docker isn't installed yet, `add_docker_repo` runs every time. Run 1: the lock stays held through all 20 tries (or Ctrl-C during the wait), so the untested `docker.sources` stays. Run 2: `previous` is now that file, so a real failure "restores" the same broken file and says "so the old one is back". **Fix:** when `previous == content`, treat it as having no known-good copy (remove it, as for a new source), or at least say the source still fails.
30. **Narrower ranges inside a private block are reported as public.** Confirmed, Claude. `private_source` (`ubuntu/lib/firewall.sh:138-153`) uses a flat /16 floor for IPv4 and /10 for IPv6, so `10.0.0.0/12`, `172.16.0.0/13`, and `fd00::/9` come back not private, and `22/tcp ALLOW 10.0.0.0/12` nags daily as "outside the private ranges". **Fix:** a per-range floor: 10/8 needs at least 8, 172.16/12 at least 12, 192.168/16 at least 16, fd00::/8 at least 8, fe80::/10 at least 10.
31. **The boot notice fires when the user manager restarts.** Confirmed, Claude. `ubuntu/lib/alerts.sh:28-33` is `WantedBy=default.target` with no boot identity. The docker step tells you to run `sudo systemctl restart user@$(id -u)` (`docker/install.sh:343-345`), which pushes a false "<host> started". So does the first login before linger is on. **Fix:** save `/proc/sys/kernel/random/boot_id` in the state dir, and skip the push when it hasn't changed.
32. **A failed `chgrp nut` is never retried.** Confirmed, Claude. `ubuntu/lib/ups.sh:262-264,294-299`; `nut_files_current` at `:160-172`. The write and the `chgrp` are separate. After one failed `chgrp`, the next run sees matching content and skips the file, leaving it `root:root 0640`. upsd and upsmon can't read it, and later runs keep restarting NUT without fixing it. **Fix:** an optional group argument on `install_root_file` (`sudo install -g nut -m 0640`), or check the group in `nut_files_current`.
33. **sshd counts as enabled only through `ssh.socket`.** Plausible, Claude. `ubuntu/lib/ssh.sh:11-13`; `ubuntu/install.sh:49-51,418-422,491-493`. On a machine switched back to `ssh.service`, as Ubuntu's docs describe, `systemctl enable --now ssh.socket` can't bind :22, so every run fails. **Fix:** accept either unit.
34. **ufw refuses to add missing allow rules when it's already on.** Confirmed, Claude; deliberate per `tests/test-ufw-recheck.sh:350`. With ufw on and a DROP policy, `configure_ufw` (`ubuntu/lib/firewall.sh:243-261`) would only add allow rules, which can't cut anyone off, yet it refuses with "the firewall would cut them off". A user on from a public IP through a hand-added broad rule never gets the tailscale0 and 41641 rules. **Fix:** skip the outside check when `ufw_enabled`, or reword the message.
35. **The RTC wake can loop on battery.** Plausible, Claude. `ubuntu/lib/ups.sh:130-136`. After a low-battery FSD, if the UPS ignores the kill command while mains is still out, the alarm boots the machine on battery 15 minutes later. upsmon sees OB LB and shuts down again, re-arming the alarm, until the battery dies. **Fix:** skip the alarm when the driver last reported OB (save the status before shutdown), or at least mention the loop in the Power cuts manual step.
36. **Exit status 3 is ambiguous in status mode.** Plausible, Claude. `lib/common.sh:1396`. A status function killed under `set -e` by a command exiting 3 (jq on a filter compile error, `systemctl is-active` for an inactive unit) is listed under "Needs attention" with a cut-short report, not "Failed steps". Current code guards every such call found. **Fix:** have the awk header filter note whether it saw a `missing` or `unknown` line, and use `PIPESTATUS` to count a 3 as attention only then.
37. **The worktree hook's `timeout`/`type` drift is never corrected, and status says ok.** Confirmed, Claude. `add_hook` (`ai_tools/claude-code/install.sh:158-161`) only checks that some group runs our command. A hand-edited 5 s timeout kills the hook mid-fetch (the fetch deadline is 15 s), so `claude -w` fails. **Fix:** when our command is present, set the fields: `map(.hooks |= map(if .command == $command then .type = "command" | .timeout = $timeout else . end))`.
38. **`generate_key` reports success when `ssh-keygen` fails.** Confirmed, Claude. `git/setup-signing.sh:92-99`, called as `generate_key || return 1` (`:158`), so `set -e` is off inside it. On the signing-key branch, the trailing `echo "  Generated $KEY"` returns 0. `mkdir -p` and `chmod 700` failures are ignored too. `main` then says "$PUB is missing. Recreate it with: ssh-keygen -y -f $KEY > $PUB", but `$KEY` doesn't exist. **Fix:** `mkdir -p … && chmod 700 … || return 1`, and `ssh-keygen … || return 1` on both branches.
39. **Stream Deck is a pkg cask missing from `CASK_PKG_APPS`.** Confirmed, Claude. `lib/common.sh:729` (cask listed at `homebrew/install.sh:49`). `elgato-stream-deck` has only a `pkg` artifact, so `cask_state` never learns its app path. A brew-installed Stream Deck deleted from /Applications still reports `brew`, and one installed from Elgato's site reports `missing`, so setup reruns the pkg over it. `install_cask`'s comment that brew "would fail on the existing app" isn't true for pkg casks. **Fix:** add `"elgato-stream-deck=/Applications/Elgato Stream Deck.app"`.
40. **The Stream Deck network key spikes by about 100 GB/s after Wi-Fi comes back.** Parser confirmed; counters persisting across down/up is plausible. Claude. `stats.js:38` matches `/^en\d+$/`, but `netstat -ibn` marks a down interface `en0*`, so when Wi-Fi goes off its counters drop out of the total (the drop is clamped to 0). When it comes back, the total jumps by en0's lifetime counter (about 200 GB on this Mac). **Fix:** `/^en\d+\*?$/`, or per-interface deltas.
41. **Large multi-line clipboard text isn't pasted by the New Tab key.** Both; a substitute producer returned 141, but real `pbpaste`'s SIGPIPE behavior wasn't checked. `bin/open-app:39-41`: `pbpaste | grep -q '[^[:space:]]'` runs under `pipefail`. With a clipboard over about 64 KB across many lines, grep exits early, the producer gets SIGPIPE, the pipeline returns 141, and the function reports no text. **Fix:** a consumer that reads all input, such as `grep '[^[:space:]]' >/dev/null`, or `[[ "$(pbpaste 2>/dev/null)" == *[![:space:]]* ]]`. Keep the empty and whitespace behavior, add a large-producer test, and confirm in a disposable macOS session.
42. **The New Tab key can paste into the wrong app.** Plausible (timing window), Claude. `bin/open-app:58-62` sends Cmd+V and Cmd+A 0.15 s after Cmd+T without checking that Chrome is still frontmost; Hammerspoon re-checks (`init.lua:83`). **Fix:** re-check the frontmost bundle ID before `keystroke "v"`.
43. **`~/.zprofile` runs mise to get a path the other files compute without running anything.** Confirmed, Claude. `zsh/install.sh:33` (`ZPROFILE_MISE_LINE`): every non-interactive login shell runs `mise activate zsh --shims` (about 10 ms), whose only output is the shims `export PATH`, which `ZSHENV_LINES` (`:75`) and `PROFILE_LINES` (`:62`) build statically. Codex and T3 start `zsh -lc` per command, so each pays for it (plus `brew shellenv` when `HOMEBREW_PREFIX` isn't inherited). **Fix:** `path=("${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims" $path)`, guarded by `[[ -o interactive ]] ||` as now. With no migration, machines already set up keep the old line until it's removed by hand.

### Docs

44. **The phone checklist omits Remote Control.** Confirmed against config and docs (no live delivery tested), Codex. `ai_tools/README.md:278` says to ask for a notification in an ordinary interactive Claude Code session. But setup sets `remoteControlAtStartup = false` (`ai_tools/claude-code/install.sh:174`), and the README's own notifications section (`:70`) and [Anthropic's docs](https://code.claude.com/docs/en/remote-control#mobile-push-notifications) say pushes need a connected Remote Control session, so a correct setup looks broken. **Fix:** start that item with `/remote-control` and finishing the connection. Keep Remote Control's default off.
45. **The Ubuntu Server advice misses Zed.** Confirmed, Claude. `README.md:104` says to leave out `ghostty`, `logitech`, and `chrome`, but the homebrew step installs the `zed` cask and font regardless (`UBUNTU_CASKS`, `homebrew/install.sh:55-58`), and the `zed` step copies configs. **Fix:** also leave out `zed` and say the cask still installs, or skip GUI casks without a desktop.
46. **T3 worktree cleanup is described twice, with different numbers.** Confirmed, Claude. `ai_tools/README.md:164` says 15 days after a thread settles; `:168` says 30 days idle. Neither mentions `worktreeCleanup.rules.worktreeUnchanged = true` (`ai_tools/t3-code/install.sh:155`). **Fix:** one list of rules.
47. **AGENTS.md says every skill is an upstream copy.** Confirmed, Claude. `AGENTS.md:21` ("They're modified upstream copies") contradicts `skills/README.md:63` (code-review and rewrite-docs started here). **Fix:** "Most are modified upstream copies (see the skills README's Acknowledgements)."
48. **code-review may be adapted from Apache-2.0 sources.** Plausible (upstream not fetched), Claude. `code-review/SKILL.md:93-129` (its bar, P0 to P3 levels, "quote at most 3 lines", suggestion blocks, correct/incorrect verdict) closely tracks OpenAI Codex's `review_prompt.md`, and `references/angles.md` matches Claude Code's `/simplify` wording. **Fix:** confirm the source. If adapted, credit it, add an Apache-2.0 entry and LICENSE, and fix `skills/README.md:63`.
49. **The yq version reads as guaranteed but isn't checked.** Confirmed, Claude. `ai_tools/README.md:135` says the step edits with yq 4.54.1 or later, but the step only runs `require_cmd yq` (`ai_tools/codex/install.sh:268`); only CI's `check-tool-versions.sh` checks it. **Fix:** check the version in the step, or say "needs yq 4.54.1 or later".
50. **The README lists a Ghostty default but not the repo's own bindings.** Confirmed, Claude. `README.md:204` lists Cmd+Shift+Enter (Ghostty's default) but not Cmd+Ctrl+arrows (resize split) or Cmd+Shift+= (equalize) from `ghostty/config.ghostty`. The Zed section (`:216-220`) omits `zed/keymap.json`'s only binding: Shift+Enter in the terminal sends ESC+CR, a newline for the agent CLIs.
51. **The Downloads paragraph leaves out sources.** Confirmed, Claude. `README.md:84` omits the skills CLI that `npx` runs (`skills@1.7.1`, pinned by version, not hash; `ai_tools/skills/install.sh:16`) and the Ghostty snap.
52. **The AGENTS.md "Docs change with the code" list misses couplings.** Confirmed, Claude. `AGENTS.md:12-19`. The Codex model (`ai_tools/codex/install.sh:43`) and the Claude model must match the reviewer table in `interrogate/SKILL.md`; only `ai_tools/README.md:133` says so. `UBUNTU_CASKS`, `UBUNTU_PACKAGES`, and the Mac-only formulae map to README "Ubuntu" (`check-docs` enforces this, but the list doesn't say it). The "checked against <version>" notes (`ai_tools/README.md:92,104,141,164`) need updating when a step's keys change.
53. **AGENTS.md's "exception" and "no guard" wording.** Confirmed or plausible, Claude.
    - `:7` calls Zed's `settings.json` and `keymap.json` "the exception" to never replacing a file, but `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` are also replaced whole through `copy_file_ask` (`lib/common.sh:529-531`).
    - `:9`'s "no guard against hand-made files" sits oddly next to code that protects hand edits on purpose: `copy_file` backups (`:445-476`), the ssh step never editing your own `Host *` block, claude-code refusing to register its hook beside another WorktreeCreate hook (`ai_tools/claude-code/install.sh:79-90`), and the codex step refusing a yq rewrite that drops comments. Say it means no code for files left by older versions of this repo, and that user edits are still preserved.

### Tests and tooling

54. **`TEST_JOBS=0` hangs `run.sh` forever.** Confirmed, Claude. `tests/run.sh:107,193`. Zero starts no workers, and the polling loop never ends; `TEST_JOBS=abc` prints "integer expression expected" 43 times in 5 s. **Fix:** reject anything but a positive integer.
55. **`pgrep` isn't a sentinel.** Confirmed, Claude. `tests/sentinels.sh:22-26` has `lsappinfo` but not `pgrep`, though `ensure_app_quit`, `upgrade.sh`, `t3-code`, and `stream-deck` all decide things by `pgrep`, and ten tests stub it by hand. Adding it breaks only `test-run-reviewer`, which can save the real path before `setup_sandbox`, as it already does for `pkill`.
56. **Coverage gaps.** Confirmed, Claude. `logitech/install.sh` has no test (AGENTS.md requires one). `reboot-required` without `.pkgs` is untested (#6). The 16 `# os: ubuntu` tests are skipped on macOS but all pass there when named, so a Mac edit to `ubuntu/` gets no local signal. The regressions named under #1, #2, #8, #9, #10, and #15 are absent today, so the existing suite passing doesn't show those fixed.
57. **`test-ubuntu-step.sh` is the slowest test by far.** Confirmed, Claude. It takes 34 s and runs `main`/`status` 84 times, which makes it the critical path on the Ubuntu CI leg. Splitting it into 3 or 4 files would bring a full named run from about 46 s to about 30 s (estimate).
58. **`brew cleanup` runs too early.** Confirmed, Claude. `scripts/upgrade.sh:251` runs it before the self-updating cask upgrades (`:259,263`), `mas`, and upgrade-ai-tools' cask upgrades (`:324`), so their old versions stay until the next run. **Fix:** move cleanup later.

---

## P4: nits

- **Core:**
  - `confirm_sudo_changes` (`lib/common.sh:117`) says "Run this step from a terminal to apply them" even when you answered N at one; say it only when `! is_interactive`.
  - `just check` (`justfile:13`) fails on a tracked script deleted but not yet staged, because `git ls-files --cached` still lists it (`tests/run.sh` already skips these with `[ -f "$f" ] || continue`).
  - `DOTFILES_STATUS_QUICK` is tested with `-n` in `docker/install.sh:142` and `ubuntu/lib/health.sh:141`, but with `== 1` in homebrew and t3-code.
  - `BACKUP_PATH` (`:502-503`) "callers read it", but only `tests/test-copy-file.sh:249` does.
  - `json_applied` (`:786`) breaks if a filter's last line is a `# comment`, since `) == .` becomes part of the comment; use `"($2"$'\n'") == ."`.
  - Nothing catches bash-4-only features (`mapfile`, `declare -A`, `${x,,}`, `[[ -v`) unless a macOS test reaches the line; none exist today. A one-line grep in `just check` would keep it that way.
- **Ubuntu:**
  - `{ n++ }` is never read (`ubuntu/health-alert.sh:65`).
  - `TAILSCALE_LIST` honors `APT_SOURCES_DIR` in production (`ubuntu/install.sh:138`), while `docker/install.sh:19` hard-codes its path.
  - When a key login is proven, two pending items describe the same write ("Write $SSHD_DROP_IN: …PasswordAuthentication no…" and "Turn off SSH password logins…", `ubuntu/install.sh:423,426-429`).
- **AI tools:**
  - The Codex step re-appends the trailing comments yq drops at the very end, after any table the edit adds, so a commented-out key under `[profiles.fast]` ends up under `[desktop]` (`codex/install.sh:202-205`). Insert before the first added table, or document it.
  - `.preferences.quickEntryShortcut = {...}` replaces the whole object (`claude-desktop/install.sh:45`). If Claude adds a key there, the step never settles and asks to quit Claude every run. Set `.accelerator` instead.
  - `scripts/check-t3-settings.sh:64-67`'s `keys_of` scans jq comments, so "e.g." would yield a phantom key `g`. Strip `#…` first.
  - `SKILLS_STATE` and `SKILLS_HASHES` (`skills/install.sh:29-34`) live in `~/.agents` and ignore `XDG_STATE_HOME`, unlike skill backups and `INSTALLED_FILES`.
  - When T3's unit hits its start limit (say, another server held port 3773) and you re-run within 5 minutes as the fix text says, `systemctl --user start` is refused, and the step says only "Check …boot-service.log". The README (`:211`) gives the manual `reset-failed`, and `tests/test-t3-service.sh:218` asserts the step doesn't run it. Consider running it when `Result` is `start-limit-hit`.
  - `rm -rf "$HOME/.agents/skills/$name"` (`skills/install.sh:295-296,324`) uses frontmatter names without validation, so a name like `../../Documents` would delete outside the skills dir after one confirm. The `for name in $(stale_skill_names …)` loop also glob-expands. Reject names not matching `^[a-z0-9][a-z0-9-]{0,63}$`, and read with `while read`. Defense in depth; it needs bad repo data.
- **macOS and apps:**
  - `plugin.js:34,83`: an unmapped action (`scripts[target]` undefined) or malformed JSON throws in an EventTarget listener and exits the plugin; latent, since every current action is mapped. Guard `scripts[target]` and wrap `JSON.parse`.
  - `sampler.reset()` keeps sparkline history across gaps (`stats.js:126-129`); clear `cpuHistory` and `gpuHistory`.
  - `bin/open-app:109` and Hammerspoon: `open -b` on a running Chrome with no windows sends a reopen event, which opens a New Tab window, and Cmd+T then adds a second tab. Use `tell application id … to activate`.
  - Hammerspoon overwrites `dotfiles.newTab`, `dotfiles.paste`, and `dotfiles.openIn` on each press (`init.lua:67,81,105`), so a second press can double-fire or lose the first timer to GC. Stop the old timer, and keep tasks in a table.
  - `stream-deck/build-profile.sh:19`: `cp -R "$DIR/profile/" "$tmp/"` copies contents only under BSD cp; macOS-only today, but `profile/.` is portable.
  - Files deleted or renamed in the repo's plugin stay installed, and status can't see them (`stream-deck/install.sh:24-36`).
  - Ghostty's `global:super+backquote` (`ghostty/config.ghostty:55`) takes Cmd+\` in every app, so macOS's "Move focus to next window" stops working. Probably intended; note it in the README.
  - `pam.sh:153-154` trusts Homebrew's user-writable `pam_reattach.so` at copy time and prompts to re-copy when it differs. Not a real escalation, since such a process could edit the repo's scripts just as easily. Optional hardening: record the Homebrew version beside the copy, and warn when the hash changes without a version change.
- **Shell and dev tools:**
  - `typeset -U path` runs only when `HOMEBREW_PREFIX` is set (`zsh/install.sh:27,75`), so a `zsh -c` under a systemd user service (the T3 server), where environment.d already set PATH, adds 6 dirs per nesting level. Start the zshenv line with `typeset -U path;`.
  - `SAVEHIST` (10000) is below `HISTSIZE` (50000) (`zsh/history.zsh:3-4`), so with `share_history`, history is effectively 10000; atuin keeps the full history anyway.
  - The `zsh/main.zsh:47-49` comment's example (a tmux pane from the boot-time server) doesn't happen: PATH starts with `~/.local/bin` there, and `~/.zprofile` has already set `HOMEBREW_PREFIX`. Reword it, or apply the `PATH=/usr/bin:/bin` override to `ZPROFILE_BREW_LINE` too.
  - `vim/vimrc` has no `syntax on` outside `plug#end()`, so the no-vim-plug fallback loses highlighting; add it beside `filetype plugin indent on`.
- **Skills:**
  - `research/SKILL.md:6,12` asks a background agent to write a findings file, which Claude Code subagents are told not to do. Have the lead write it.
  - code-review-stds-and-spec, rewrite-docs, and show-me-your-work never remove the `mktemp -d` dir from `code-review/references/scope.md:48`.
  - `show-me-your-work:10` says "write no file", but `--check` writes `prompt.md` (`:42`). Say "no file in the repo".
  - code-review's `--comment` checks lines against a `-U10` diff (`scope.md:62`) and deletes it before commenting (`SKILL.md:53`). GitHub returns 422 for a line outside its own hunks, which fails the whole review. Check against `gh pr diff`.
  - `tdd/SKILL.md:24` expects to-spec to record "the agreed seams under Testing decisions", but `to-spec/SKILL.md:57-63` has no slot, and implement's sub-agents can't ask. Its check-in to confirm seams with the user (`:20`) also conflicts with `user-instructions.md:3` (no check-ins). Make it an explicit exception, or skip it when the spec records the seams.
  - Serial implementers aren't given the feature-checkout path (`implement/SKILL.md:27`), so when the user declines to commit they could build in the user's checkout. The closing review scope `<base-branch>` (`:41`) is right only from the feature checkout; use `<base>...<feature-slug>`.
  - `interrogate/SKILL.md:25` says "Both models accept all five" efforts, but Codex's documented values end at `xhigh`. Verify, or map `max` to `xhigh`.
  - Nothing checks the CLI flags and tool names the skills use against the real CLIs: `claude --restricted` and `codex --ignore-rules --disable multi_agent` in `run-reviewer.sh`, and `ReportFindings` and `spawn_agent` `fork_turns` in code-review. They do exist in claude 2.1.302 and codex-cli 0.163.0 today, but the tests stub the CLIs and assert only argv.
  - `engineering/README.md:25` says "Every level checks every angle", but at `low` code-review looks only at the diff.
  - The skills README doesn't mention the Codex-only install when `CLAUDE_CONFIG_DIR` points elsewhere.
  - unslop bans "surface" and "scaffolding", which architect, implement, and interrogate use on purpose.
- **AGENTS.md:**
  - `:5` says a step sources `<step>/lib/` "as `ubuntu` does" via `BASH_SOURCE`, but `ubuntu/install.sh:22-38` uses `$DOTFILES_DIR` (`git/install.sh:15` is the one using `BASH_SOURCE`), and `ssh/lib/hosts.sh` defines `SSH_CONFIG_AWK`, though the rule says lib files define only functions.
  - `:6`'s list of status states omits `info`, which FileVault and the firewall print (`macos/install.sh:213-245`).
  - `:8` says "Every step runs on macOS and Ubuntu", then "a step only one OS runs"; "can run on either OS" is clearer.
  - It doesn't mention `just test <name>`.
- **Docs:**
  - "Top CPU" (`README.md:245`) is "Top Process" in `manifest.json` and the profile.
  - The skills README's `## Acknowledgements` should be updated if #48 holds.
- **Tests:**
  - `upgrade.sh:90` builds a `pgrep -af` regex from an app's path and name without escaping, unlike `ensure_app_quit` (`lib/common.sh:642-646`), so `+`, `.`, or `[` would make the check wrong. Share one escape helper.
  - `scripts/lib/markdown.sh:7-9` doesn't check reference-style links (`[ref]: ./x.md`), flags `(path "title")` as broken when the file exists, and checks links inside code fences, unlike `anchors()`. Confirmed by mutation.
  - `check-docs.sh:228` picks steps with `find`, not `git ls-files`, so an untracked `.scratch/x/install.sh` with a `_files()` function would be sourced.
  - `test-diagnostics-{macos,ubuntu}.sh` (6 places): `( …; exit "$TEST_FAILURES" ) || TEST_FAILURES=$((TEST_FAILURES + $?))` double-counts (2 plus no new failures gives 4); pass/fail is unaffected. The tests use three different subshell patterns.
  - `test-upgrade.sh:174` and `test-homebrew-main.sh:34` hard-code the Brewfile's App Store IDs; derive them with `mas_app_ids`.
  - `check-docs.sh`'s fixed English anchors ("The steps, in order, are", "Of the casks, Ubuntu gets") fail with an unclear "The doc: (empty)" when the prose is reworded; improve that message. In `check-skills.sh`, `check_skill_paths` (three heuristic passes per .md file) is the fragile part, and the dated field allowlists will go stale.

---

## Simplification and resilience (ordered by payoff)

Both reviews agree on what to keep: the runner and step structure, the shared helpers, bash 3.2 support, copied (not linked) configs, the read-only `--status` reports, explicit manual steps, and `check-docs.sh`, which caught every mutation tried against it. Most of the complexity protects those contracts or handles real platform differences. Everything below keeps every feature. The gains come from consistent reuse of mechanisms that already exist, and from skipping work already proven unnecessary.

### S1. List each check once in the sudo-change steps (largest win)
In `ubuntu/install.sh`, each simple item appears three times: in the pending list (`check || pending+=(desc)`), the apply block (`check || fix || result=1`), and `status` (`status_check desc check`). For example, `sleep_masked` is at lines 228, 395, and 470, and `lingering` at 238, 402, and 479. The docker and macos steps follow the same pattern.

A small item table in `lib/common.sh`, `item "<desc>" <check-fn> <fix-fn>`, plus one driver that builds the pending list for `confirm_sudo_changes`, applies fixes, and prints status lines, would give each simple item one home, so status can't drift from install. Keep custom code for items with branching (ufw, sshd, Tailscale, UPS). About −100 to −150 lines in `ubuntu/install.sh`, plus cuts in docker and macos.

The smaller Ubuntu cleanups fit on top, about −55 more:
- Move the SSH and ufw status blocks into the libs as `status_sshd` and `status_ufw`, matching `status_ups` and `status_smart`. Have `ufw_broad_ssh_rules` print `<source>\t<rule>`, so `status()` stops re-parsing rules (`install.sh:339-348`). `status()` shrinks from about 145 lines to about 70.
- One root-copy helper pair, `root_copy_current` and `install_root_copy`, replacing the three smartd, UPS-notifier, and ntfy-lib pairs.
- One `restore_sshd_drop_in` for the two rollback copies (`ssh.sh:215-222,228-232`).
- `nmcli -t -e no` in `nm_connections`, which removes the 7-line unescape loop.
- Merge `main()`'s three "already set up" messages (`install.sh:458-467`) and the two password-login pending items.
- Compute `ups_state` once (the udev DB dump runs twice per run), and cache `in_vm` and `key_login`. Status forks `systemd-detect-virt` 4 or more times and runs `ssh-keygen` per `authorized_keys` line 3 times.
- Share `SMARTD_HOOK`, `UPS_NOTIFY`, and `NTFY_URL_FILE` from one `ubuntu/lib/paths.sh` (they're duplicated in `setup-alerts.sh:21-24`); the root hooks keep their hard-coded copies.
- Inline `smartctl_cmd` into `sbin_cmd smartctl`.

### S2. Atomic writes and a few shared primitives (resilience)
These fix P1 bugs as a side effect:
1. Route every file write through one atomic path (temp file beside the destination, then `mv`): `_copy_and_record`, the T3 drop-in, and the LaunchAgent. This fixes #1 and #3 and removes the chmod-after-copy convention.
2. An interrupt trap in `run_steps`, and `install_cask` exiting on codes above 128. This fixes #5, and `try_install_cask`'s special case goes.
3. A group argument on `install_root_file` (`install -g`). This fixes #32, and `write_nut_file` drops its `chgrp`.
4. Fingerprint pinning in `add_apt_repo`, one constant per repo (#18).
5. Small checks that remove never-settling or false-alarm states: a boot-id check for the boot notice (#31), `>=` for the sysctl limits (#28), `IPV6=yes` in the ufw check (#21), and `reset-failed` on `start-limit-hit` for T3.

### S3. One step entry point
Every step repeats the same roughly 10-line `main` (`step_args`, status dispatch, the work) and the `BASH_SOURCE` guard. A `step_main "$@"` that calls the step's `status` or `install` cuts that from every step. Copy-only steps (lazygit, editorconfig, most of vim, ghostty, hammerspoon) shrink to about 10 lines with a `copy_step "<message>" <files-fn>` helper. It's also the single place for the interrupt trap. About −8 lines × 25 steps, and AGENTS.md's step description gets shorter.

### S4. Merge near-duplicates in `lib/common.sh` (about −70 to −80 lines, about 30 moved out)
- Merge `copy_file`, `copy_file_ask`, and `_copy_up_to_date` (`:424-456,538-555`) into one body with an ask mode, keeping `copy_file_ask() { _copy_file ask "$@"; }` since it's passed as an action name, and keeping the `-e` vs `-s` difference (−15).
- Merge `backup_edited` and `maybe_backup` (`:461-476,615-626`) into one helper taking the question and the no-terminal default, keeping `maybe_backup`'s shortcut when `.bak` already matches (−10).
- Drop the `CASK_APP_CACHE` layer (`:699-719`). Its one caller (`ai_tools/t3-code/install.sh:697-699`) can look the path up once and pass it on (−12).
- Derive `step_args`'s path from `${BASH_SOURCE[1]}`, which is always the step's `install.sh`, whether run directly or sourced by a test. The usage line then names the step under tests too, and the re-exec workaround in `tests/lib.sh:15-21` goes (−6). Check first that no test asserts on an absolute `$0`.
- Move the source-time flag loop (`:170-184`) into `check_args`, so the flag list lives in one place (−8). No step calls brew at load time before `step_args`, so `HOMEBREW_NO_AUTO_UPDATE` is still set in time.
- Inline single-use helpers: `runner_args` and `_add_runner_step` into `runner_main`, `unknown_step` into `run_steps`, `listed_cask_app` into `cask_state`, and `restore_apt_key` into `add_apt_repo` (−15).
- Move step-only helpers out of the file about 30 scripts source: `periodic_daily` and `unattended_upgrades_on` (`:926-950`) to `ubuntu/lib/updates.sh`, and `mas_app_ids` (`:353-355`) to homebrew (about 30 lines move).
- Print the runners' shared usage lines (`setup.sh:23-33`, `ai_tools/setup.sh:22-32`) from `runner_main`, with each runner passing only its `--quick` sentence (−6).
- Add a `status_quick` helper (fixes the `-n` vs `== 1` nit), drop `BACKUP_PATH` (−2), and drop the redundant `CDPATH=''` at `:7` and `:244`. Optionally cache `uname -s` inside `is_macos` and `is_ubuntu`.

### S5. Per-area cuts
- **AI tools:**
  - **Keepable values:** one mechanism shared by claude-code and codex. The `*_KEEP_*` arrays, `*_keepable`, `_keep_applies`, `_keep_wanted`, and their configure and status loops are duplicated, and `claude_code_keep_wanted` and `codex_unquote` are the same JSON-unquote helper. A table with a tool column plus `keepable_choose` and `keepable_status` (−40).
  - **T3 telemetry plist:** move the LaunchAgent into a repo file handled by `copy_file` and `status_file` in a `*_files` function, as claude-desktop does. It gains edit detection and backup (today a hand edit is silently overwritten), and the Maintenance list covers it (−12).
  - **Worktree hook:** have it call `git wt base` (factored out of `cmd_add`), so the origin/HEAD → main → master → HEAD order lives in one place (−10). Move its "delete the hook-created branch if another branch contains it" block (`worktree-hook.sh:276-289`) into `git wt rm` behind a flag, reusing `is_merged` (−8).
  - **Skills reinstall** (Codex): when one skill changes, unchanged skills still enter the add list, and a run without backup failures replaces it with `--skill '*'`. With 21 skills, changing one reinstalls 20 current copies (`skills/install.sh:218-228`). Collect only names with a non-empty `skill_problem` and pass them through the existing selective `--skill` path. Keep:
    - edited-copy backups and backup-failure exclusions
    - Claude symlink repair and executable-bit checks
    - custom Claude-home handling and post-install verification
    - stale-skill removal
  - **Skills scan:** find the skill list once in `skills/install.sh`. It runs `find … -name SKILL.md` six times and hashes each repo skill 3 or 4 times per add (no LOC change, about half the hashing).
  - **Skills state:** merge `SKILLS_STATE` and `SKILLS_HASHES` into one `<hash|->  <name>` file, which also fixes the XDG nit (−15).
  - Drop the `T3_CODE_SERVER_FILTER` global and call `t3_code_server_filter` where it's used (−3).
  - **macOS notification settings** (Codex): `notifications_pending` (`ai_tools/manual-steps.sh:19-23`) runs `plutil` once for the count, once per registered app's ID, and once per match's flags; with 100 entries and 4 matches, that's 105 launches. Extract `apps` once and filter locally. Keep the requested-ID order, all three flag checks, and the unreadable / Full Disk Access behavior. The manual step has no hard jq prerequisite today, so keep a fallback when jq is missing.
- **zsh:**
  - One `zsh/path.zsh` as the single PATH source. PATH logic lives in seven places today (`ZPROFILE_LINES`, `ZSHENV_LINES`, `main.zsh:46-58`, `basic-settings.zsh:11`, `plugins.zsh:46-48`, `PROFILE_LINES`, environment.d), and two copies have already drifted (#43 and the `typeset -U` nit). `zsh_files` already copies `*.zsh`; source it from one managed line each in `~/.zprofile` and `~/.zshenv`, and from `main.zsh`. Only `~/.profile` still needs `merge_lines`. Existing machines keep their old lines (harmless under `typeset -U`) until cleaned by hand, and the AGENTS.md note and `tests/test-zsh-path.sh` need updating (−30).
  - Fold `setup_zprofile`, `setup_profile`, and `setup_zshenv` (`zsh/install.sh:182-213`) and their `*_set_up` wrappers into one `setup_lines <file> <ok-msg> <changed-msg> <line…>` (−20).
  - Inline `srcif` (`main.zsh:6-8`), which is used once (−3).
- **tmux:** read `plugins.lock` once with `while read -r repo sha …`, as `bump-plugins.sh` does, instead of two awk runs per plugin per pass (three in status). Keep the `sync_tmux_plugins` name, which `upgrade.sh:282` calls (−8).
- **ssh and git:** `status_host_star` (`ssh/install.sh:68-78`) runs `host_star_missing` twice; capture it once (−2). Add a `git_file` helper in `git/lib/config.sh` for the `git --git-dir=/dev/null config --file …` call repeated five times, so the "broken checkout" comment lives in one place.
- **Stream Deck:**
  - Merge `bin/open-app` into `bin/open-in`. open-app repeats the PATH setup, `log`, `notify`, and the error-flattening and permission-code matching twice (`open-app:115-124,138-147`). One script also removes `plugin.js`'s 11-line `scripts` map. Pair this with removing files deleted from the repo's plugin (−45).
  - One SVG frame helper in `stats.js` for `card`, `overview`, `top`, and `network` (−12).
  - Cache the last image per context and skip `setImage` when the SVG is unchanged; the System page sends about 11 images every 2 s, and Disk and Swap rarely change. Read pressure and swap with one `sysctl -n` call (+4, less work).
  - Pass the bundle ID through `run(argv)` in open-in's JXA instead of hard-coding `com.t3tools.t3code` a second time.
- **ghostty and stream-deck:** have `_copy_and_record` set a `COPIED` flag, which replaces `copy_config`/`CONFIG_CHANGED` and `copy_plugin_file`/`PLUGIN_CHANGED`, and makes "changed" mean a copy actually happened (−10).
- **homebrew:**
  - In `install_bundle`, compute the "formulae and App Store apps" label once.
  - Pass `install_casks`' known state to `install_cask`, so it doesn't call `cask_state`, `brew list`, and `brew info` again for each missing cask (−6).
  - In `pam.sh`, compute `reattach_source` once per run; it shells out to `brew --prefix` up to about five times.
- **docker:** restore `daemon.json` from the in-memory `current` with `write_root_file` instead of managing `$DOCKER_DAEMON_CONFIG.dotfiles-bak` in `/etc/docker` (−10).

### S6. Tests (about −60 to −80 lines, faster CI)
- Sandbox `TMPDIR` and `HOMEBREW_PREFIX` in `setup_sandbox` (+2, −2 from `test-upgrade`).
- One Ubuntu sandbox-paths helper with the outside-path guard, replacing hand-kept blocks in test-ubuntu-step (two of about 20 lines), test-status, test-ufw-recheck, test-diagnostics-ubuntu, and test-ubuntu-ups (+25, net −40 to −60).
- An `on_exit` hook in `tests/lib.sh` (+5).
- A shared sudo-exec stub with the sandbox-only check (+8, −6).
- One shared skills CLI test double (Codex): `tests/test-skills-exclusions.sh:22-52` and `tests/test-skills.sh:34-64` are identical mocks of skill selection, copy exclusions, agent links, failures, and removal. Extract the mock into one helper, keeping fixtures and assertions in each test (about −30).
- A `subtest` helper for the diagnostics tests (+6, −12).
- Split `test-ubuntu-step.sh` into 3 or 4 files (about +60 lines of headers, no logic change), then consider dropping the `# os:` filter.
- In check-docs: a `section <file> <heading>` awk helper replacing about 8 inline extractions (−15), `git ls-files` to pick steps, and a `runner_steps` helper shared with `test-run-steps.sh:119-124` (−6).
- Validate `TEST_JOBS` (+2), and derive the App Store IDs in the two tests.

### S7. Docs (shorter without losing anything a user needs)
Several of these sections break AGENTS.md's own rule that the READMEs keep to what a user does and sees.

- **`README.md`** (6,900 words):
  - Cut Stream Deck (`:222-250`, 643 words) to its two tables plus one paragraph. Move the log path, the profile caching, and `build-profile.sh` to Maintenance, and drop the hostname and permission details that repeat manual step 13.
  - Cut Hammerspoon (`:265`) to its table plus one line; it repeats Stream Deck and manual step 14.
  - Make macOS "Check it works" (`:482-484`) one short check per device.
  - Explain Full Disk Access once (it appears in first-run step 4, manual step 1, and `:387`).
  - Trim internals (`HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS`, `mise hook-env`) from Updating (`:497-516`); this needs a looser `stage_doc`.
- **`ai_tools/README.md`** (4,200 words):
  - Turn the T3 settings wall of text (`:164-168`, 314 words) into bullets, merging the cleanup paragraphs (#46), and move "documented only in its source" to Maintenance or a code comment.
  - Cut Codex's "Rewritten file" (`:135`) to one sentence.
  - Replace the four "checked against <version>" notes with one Maintenance table (app, version, where its keys live), which also fixes #52.
  - Drop first-run macOS step 2 (quitting apps that don't exist yet; `:47` already offers to quit them).
  - Move `:92`'s maintainer detail to Maintenance.
- **`AGENTS.md`:** split the "Scripts" bullet (about 12 rules in one paragraph) into sub-bullets. Add a numbered new-step checklist: runner list, `install.sh` with `*_files`/`status`/`main`, a test, the `test-config-steps` list, the README table, the copy-back list. Give the temp-`HOME` test command its own bullet.

**Total:** S1 to S6 remove roughly 600 to 800 lines, mostly repetition. They fix #1, #3, #5, #31, and #32 along the way, and leave fewer places where status and install can drift apart.

### Suggested order
1. Protect data and boundaries: #1, #2, and #3 (one atomic-write change covers #1 and #3), then #4, #5, and #6, each with a targeted regression test.
2. The remaining P2 items. #9 (both macmon fixes together), #8, #15, and #14 are mostly local changes.
3. S1, S3, and S4, as separate small changes, with tests passing after each.
4. The P3 items by area, then the docs trims in S7.

---

## Deliberate choices worth re-confirming

These are intentional or documented, not new bugs, but each widens what an agent or another process can do. They'd need revisiting before moving this setup to a shared machine.

- **Claude Code:** `permissions.defaultMode = "auto"` is rewritten every run, so a mode changed in `/config` reverts.
- **Codex:**
  - `approvals_reviewer = "auto_review"` sends escalations, network included, to a model reviewer instead of you.
  - On Ubuntu, `mcp_oauth_credentials_store = "file"` keeps tokens in plaintext in `~/.codex/.credentials.json`, and status doesn't check that file's mode.
- **T3:** `defaultRuntimeMode = "auto"` on a server the tailnet and T3 Connect can reach.
- **Docker:** the docker group gives agents root-equivalent access.
- **Tailscale:** the operator can expose services, subject to tailnet policy.
- **Claude app:** Cowork browser tools run in your real Chrome (#13).
- **Skills CLI:** `npx -y skills@1.7.1` pins the top-level version only; dependencies resolve at install time.
- **tmux:** `set-clipboard on` with `allow-passthrough all` (`tmux/tmux.conf:54,57`) lets any pane, hidden ones included, write the Mac clipboard and send raw escape sequences to Ghostty (for example, `cat` of a hostile file). This is documented in the config; Ghostty's paste protection and bracketed paste limit the damage.
- **Prompt and editor plugins:** starship, gitgutter, and fugitive run git in untrusted directories. starship already passes `-c core.fsmonitor=`, but a repo extracted from an archive with a hostile `.git/config` can still reach git's filter and diff drivers. Every git-aware prompt has this risk; nothing here makes it worse.
- **Native installers and self-updates** trust their publishers. The Rust `curl | sh` installer downloads first and is https-only; `brew "rustup"` would avoid it, but the zsh and ubuntu steps assume `~/.cargo/bin`.

---

## Checked and sound

Keep these through any simplification.

- **SSH and firewall:**
  - The sshd drop-in sorts first and is validated with `sshd -t`, with rollback. Password logins go off only after a proven key login, and effective settings are checked with `sshd -T -C`.
  - An isolated `sshd -T` check emitted one `AllowUsers` entry per user, matching the parser.
  - ufw refuses to turn on while a logged-in SSH session comes from outside, reads ports from both sshd and `ssh.socket`, and checks for rules that broaden SSH access.
- **Root-run hooks** are root-owned copies outside the repo with fixed paths. Event strings reach curl as arguments, never through a shell.
- **Secrets in transit:** the ntfy topic stays out of argv, logs, and units.
- **Loopback binding:** Docker publishes on 127.0.0.1 (with the existing-network limit documented), and T3's Ubuntu service binds to loopback.
- **Atomic system writes:** `install_root_file` replaces root-owned files atomically, settings merges keep unrelated values, and failed apt source changes roll back.
- **PAM:** `sudo_local` orders the header, `pam_reattach.so ignore_ssh` (a root-owned copy), then `pam_tid.so sufficient`; the password fallback still applies. It's written via temp-and-rename, mode 444, root-owned. The module is copied before `sudo_local` names it, and the script refuses when the copy or any parent is writable by anyone but root. macOS 27's `install(1)` writes through a temp file, so a suspected module-overwrite issue was rejected. No lockout path found.
- **Injection:** every AppleScript and JXA script takes dynamic values through `on run argv`. `plugin.js` uses `execFile` with no shell, and the T3 thread ID is UUID-checked before SQL. Hammerspoon builds no shell or AppleScript strings. The `sudo bash -c "$(declare -f file_mode)"` in `install_root_file` passes `dest` as `$1`, and sudo drops `BASH_ENV`. Both `eval`s are safe (`brew shellenv` from fixed paths, `apt-config shell`). Temp files all come from `mktemp`, and `fetch`'s `--proto =https` applies to redirects.
- **git, worktrees, and tmux:**
  - No `safe.directory`, `hooksPath`, or URL rewrites; `transfer.fsckObjects` is on; fsmonitor is the built-in daemon, limited to `~/Dev`.
  - git-wt paths all come from names that pass `check-ref-format`. It never runs `rm -rf`, only `git worktree remove` and `rmdir`.
  - The worktree hook parses JSON only with jq, guards the `.worktreeinclude` copy against symlinked parents, and registers no PreToolUse or PostToolUse hooks.
  - tmux-sessionizer never passes input through a shell.
  - tmux and vim plugins are pinned by full SHA over HTTPS, and status verifies HEAD.
- **SSH client:** no ForwardAgent or StrictHostKeyChecking changes. `~/.ssh` is 700 and the config 600; ControlPersist is 1m, with the risk noted.
- **zsh:** startup order traced on both OSes. An interactive start is about 90 ms, and the init caches work. `%~` renders control characters, so hostile directory names can't inject escapes.
- **Configs and inputs:** Ghostty's config validates on 1.3.1. The Zed keys exist in the installed binary. Every Brewfile formula and cask exists with no duplicates, and `HOMEBREW_BUNDLE_MAS_SKIP` is honored. `CASK_APP_JQ`'s `.target` matches brew's JSON. The stats.js parsers are correct on this Mac's `vm_stat`, `netstat`, `sysctl`, and `ps`. macmon 0.10.0 emits the fields read. Both plists pass `plutil -lint`.
- **bash 3.2 and `set -e`:** no bash 4 constructs anywhere. Empty arrays are guarded under `set -u`. `run_bounded`'s perl fallback returns 124 on macOS 27. Ctrl-C in `--status` mode stops the run. `apt_lists_locked`'s `grep | grep -q` can't hit SIGPIPE.
- **Other checks:**
  - **Statusline:** one jq and one git per render, every 5 s.
  - **Skills:** `dir_sha256` matches across `sha256sum` and `shasum`, and skills status takes about 0.85 s.
  - **App names:** the `ensure_app_quit` names match each app's `CFBundleExecutable`.
- **CI and tests:**
  - CI actions are commit-pinned, and downloaded tool binaries are checksum-verified.
  - Sentinels block package installs, network calls, and system changes in tests (apart from the leaks in #14).
  - `run.sh`'s status aggregation, output ordering, and bash 3.2 handling are sound.
- **Docs that match the code:** step lists, "What's included", Ubuntu packages and casks, the Maintenance copy-back list, both Updating sections, justfile lines, aliases and key bindings, tmux, vim, Hammerspoon, Stream Deck layout, macOS defaults, and the round-the-clock Ubuntu claims.
- **Skills:**
  - All 22 skills keep invocation consistent across SKILL.md, `openai.yaml`, and the README headings, with valid frontmatter and resolving links.
  - LICENSE files match `THIRD_PARTY_LICENSES`.
  - No skill pushes or skips permissions, and `user-instructions.md` doesn't conflict with AGENTS.md.
- **Secrets:** a pattern scan of tracked text found no private-key blocks or common GitHub, AWS, or service token formats. This wasn't a full secret scan or a history audit.

---

## Housekeeping on this Mac

These are outside the repo, and nothing has been cleaned up.

- **Orphaned test processes** from earlier `just test` runs in other worktrees are still running: PIDs 17222, 50028, 50772, 51503, 67352, 80405, 80574, 80577, 80598, and 83702 (Oct 9 to 16). They're harmless sleeps and stubs; `kill` clears them. #14(b) explains the cause.
- **Leftover files:**
  - 72 four-byte files from `test-write-back.sh` in `$TMPDIR`
  - about 13 stale `/tmp/dotfiles-test.*` dirs
  - a few temp `HOME` dirs from the Claude review, kept because a safety check blocked `rm -rf`
- **One slip during the Claude review:** a `tmux -L` probe ran against `/tmp/tmux-501` without `TMUX_TMPDIR`. It left a dead socket, which was removed after checking that no server used it.

---

## Verification and coverage

- **Static checks:** `just check` passes (11 s): ShellCheck at every severity, `zsh -n`, docs consistency, skills metadata and paths, and Claude settings keys. Beyond that, `shellcheck -o all` (minus style-only checks) is clean on the framework files, and `bash -n` passes on every script. `scripts/check-tool-versions.sh` passes.
- **`just test`:** passes in 28 s wall (61 passed, 1 skipped for no `lua`, 16 left out as Ubuntu-only). Run by name on macOS, 77 of 78 pass (the Hammerspoon test skips), in 46.5 s; one at a time they sum to 234 s. Codex's first run under its own OS sandbox had eight failures, from restricted sockets and process inspection, and all passed on rerun outside it.
- **Slowest tests:** ubuntu-step 34.3 s, worktree-hook 18.2 s, skills 15.0 s, t3-service 10.0 s, diagnostics-ubuntu 8.8 s, ufw-recheck 8.3 s, upgrade 7.6 s. `run.sh`'s `bash -n` over 153 scripts costs about 0.35 s.
- **AI CLIs:** `scripts/check-ai-settings.sh` passes with Claude Code 2.1.302 and Codex CLI 0.163.0, including config acceptance, reviewer CLI flags, negative controls, and a real Codex sandbox command run from an isolated home.
- **Reproductions:** the partial copy (#1), symlink pruning (#2), the `please` history gap (#4), the Ctrl-C carry-on (#5), the `reboot-required` abort (#6), the stale-fetch cache (#8), the macmon spawn error and exit race (#9), the Codex comment count (#10), the VM regex mismatch (#15), the `git wt` option base (#26), the private-range floor (#30), and `generate_key` (#38) were each reproduced in isolation. Clipboard handling (#41) used a substitute producer only.
- **Scope:**
  - Codex inventoried 349 tracked files: 297 text and source files, totaling 34,756 lines.
  - Generated images, binary assets, the packaged Stream Deck profile, and vendored `vim/plug.vim` were excluded from line review; their install and build paths were reviewed.
  - Claude used seven area reviewers; Codex used four review passes plus two verifiers.
- **Not exercised:**
  - a full Ubuntu install and reboot in a VM
  - real package installs and upgrades
  - live firewall and PAM changes
  - physical UPS and disk behavior
  - GUI automation and phone delivery
  - live upstream T3 schema and Homebrew catalog checks
  - dependency source and Git history audits
