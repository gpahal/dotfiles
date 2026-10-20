# AI tools

Setup for [Claude Code](#claude-code), the Claude desktop app, [Codex](#codex) (CLI and ChatGPT app), and [T3 Code](#t3-code), on macOS and [Ubuntu](#ubuntu-1), with their [privacy](#privacy) settings, [user-level instructions](#user-level-instructions), and [skills](#skills).

## First run

### macOS

1. Run the main [`setup.sh`](../README.md#first-run) first, for `jq` and `yq`.
2. In Ghostty (not T3 Code, which the script quits), run `bash ai_tools/setup.sh`.
3. Do the macOS [manual steps](#macos-1).
4. Run the [checks](#check-it-works).

### Ubuntu

1. Run the main `setup.sh` first, including the `ubuntu` step.
2. Run `bash ai_tools/setup.sh`.
3. Do the Ubuntu [manual steps](#ubuntu-2).
4. Reboot once, then run the [checks](#check-it-works) over SSH from the Mac.

## Automated setup

```sh
bash ai_tools/setup.sh              # every step
bash ai_tools/setup.sh codex skills # only these
bash ai_tools/setup.sh --status     # report only
```

The steps, in order, are `claude-code`, `claude-desktop`, `codex`, `t3-code`, `skills`, and `manual-steps`. Ubuntu Server skips the desktop apps. Each is `ai_tools/<step>/install.sh`, except `ai_tools/manual-steps.sh`.

It works like the main [`setup.sh`](../README.md#how-setup-works). A model, effort, or footer you set is kept unless you agree to replace it. On macOS it asks to quit the Claude, ChatGPT, and T3 Code apps, which overwrite their settings, and skips their settings while they run. It adds no MCP servers.

**(script)** marks what the script does.

## Updating

`upgrade-ai-tools`, which `upgrade` runs, updates what's installed and lists failed stages:

- `claude update`.
- The Claude, ChatGPT, and T3 Code casks unless running, and the Codex CLI.
- Claude Code plugins, printing each marketplace commit and plugin version before and after for review, since plugins can add hooks.
- `t3 update` on Ubuntu, asking before restarting the service.
- `codex plugin marketplace upgrade`.

## Claude Code

Installed with the native installer, which auto-updates **(script)**.

### Notifications

Desktop notifications work in Ghostty, iTerm2, and kitty, inside tmux too. Elsewhere, set `"preferredNotifChannel": "terminal_bell"`. Phone pushes are on **(script)** but only reach a session connected with `/remote-control`. If `/config` shows **No mobile registered**, open the Claude app once.

### Browser (Claude in Chrome)

1. Install the [extension](https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn) and sign in with the same account.
2. Run `claude --chrome` once, then restart Chrome.
3. `/chrome` should show **Status: Enabled** and **Extension: Installed**.

### Computer use

1. In a session, `/mcp` → **`computer-use`** → **Enable**. It's per project.
2. Give the terminal **Accessibility** and **Screen Recording**, then **Try again**.

### Settings

- **(script)** Auto mode, auto memory off, transcripts kept 90 days, no permission rules added. The script resets its settings each run, so change them in [`claude-code/install.sh`](./claude-code/install.sh), not `/config`. T3 Code sets model, effort, mode, and sandbox per session.
- **Model (script).** Opus 5.5 at medium effort.
- **Interface (script).** Fullscreen TUI, normal key bindings.
- **Status line (script).** [`claude-code/statusline.sh`](./claude-code/statusline.sh): `Opus 5.5 · medium · ctx 43% · 5h 24% · main`.
- **Worktrees (script).** [`claude-code/worktree-hook.sh`](./claude-code/worktree-hook.sh) puts `--worktree`, subagent, and background session worktrees under `~/.worktrees` with [`git wt`](../README.md#git), and removes clean, merged subagent worktrees when a session ends, but not on `/clear`. It copies the ignored paths `.worktreeinclude` lists; name an ignored directory, not a file inside one.

### Desktop app

The Claude app opens at login through a LaunchAgent **(script)**, with no menu bar icon, Option+Space quick entry, keep-awake while working, 30-day session archiving, and Cowork's browser tools and scheduled tasks on. To keep the Cowork ones off, set `coworkBrowserToolsEnabled` or `coworkScheduledTasksEnabled` to `false` in [`claude-desktop/install.sh`](./claude-desktop/install.sh).

On Ubuntu it installs from Anthropic's apt repo, so `apt upgrade` updates it, and its own **open at login** setting is on **(script)**. The settings are the same, without quick entry, since GNOME uses Alt+Space for the window menu. Computer use and dictation aren't on Linux yet.

## Codex

The ChatGPT app holds the Codex app, browser, and computer use. Both it and the CLI install with brew **(script)**.

### Notifications

The app notifies on finished turns and requests **(script)**. The CLI notifies in Ghostty with no config. Don't overwrite the top-level `notify` key, which the Computer Use plugin sets.

### Browser

`Cmd+Shift+B` opens the built-in browser, which has no logins. For your Chrome, select **Chrome** in **Settings → Computer Use**, install the plugin and extension, and type `@Chrome`.

### Computer use

In the ChatGPT app, install and turn on the **Computer Use** plugin, give **Codex Computer Use** **Screen Recording** and **Accessibility**, and approve each app.

### Settings

In `~/.codex/config.toml` **(script)**:

- **Model.** `gpt-6.1-sol` at high effort, with concise output. Keep the interrogate skill's table in `ai_tools/skills/engineering/interrogate/SKILL.md` in step.
- **Permissions.** No prompts in the workspace; anything else goes to a reviewer agent. The sandbox has no network unless you set it under `[sandbox_workspace_write]`.
- **Rewrite.** Needs yq 4.54.1 or later. The step leaves the file alone if yq would change another value or drop a full-line comment.

The ChatGPT app **(script)** stays out of the menu bar, keeps the Mac awake for tasks and Codex Remote, squash-merges PRs, and steers mid-turn.

## T3 Code

[T3 Code](https://t3.codes/) runs the `claude` and `codex` CLIs, so their settings and skills apply there. The `t3-code` cask auto-updates **(script)**.

### Mobile

The phone app reaches the Mac through **T3 Connect**, which needs the Mac on, awake, and running T3 Code.

1. Install the phone app ([iOS](https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824), or **T3 Code** by T3 Tools on Google Play).
2. In T3 Code, **Settings → Connections**: sign in to T3 Connect, turn it on for the local environment, and turn on **Publish agent activity**.
3. Sign in on the phone and choose the Mac.
4. In the phone app, turn on **Settings → Notifications → Device Notifications**.
5. Optional: turn on **Live Activity Updates** (iOS) or **Ongoing Agent Activity** (Android).
6. Keep the Mac awake with Amphetamine or `caffeinate -i`.

A LaunchAgent opens T3 Code at login with telemetry off **(script)**.

### App settings

Merged into `~/.t3/userdata/settings.json` and `client-settings.json` **(script)**:

- New threads use Claude Opus 5.5 at medium effort with a 1M context window, in auto mode, each in a worktree under `~/.t3/worktrees`. T3 fetches the base branch first and branches from origin's copy, or from the local branch when origin lacks it. Your own model or effort is kept.
- Worktree setup actions that existed when the script ran block the agent; a later one needs `"async": false`.
- T3 removes its worktrees 30 days after last activity, 15 after settling, after merge, or when their last thread is deleted, skipping ones in use or with uncommitted or untracked files. Ignored files such as `.env` go too, unless **Settings → Storage → Keep worktrees with local changes** is **Any local files**.
- Projects auto-pull, threads settle after 10 idle days, and PRs squash-merge.

## Privacy

Turn off training by hand:

- **Claude.** [claude.ai → Settings → Privacy](https://claude.ai/settings/data-privacy-controls).
- **ChatGPT and Codex.** **Settings → Data controls → Improve the model for everyone**, and **Include environments** on chatgpt.com/codex.
- Don't rate replies: a rating sends the whole conversation.

The script turns off Claude Code's error reporting, Codex's analytics, and T3 Code's telemetry **(script)**. Claude Code's usage telemetry stays on, since features need its [feature flags](https://code.claude.com/docs/en/env-vars#features-that-need-feature-flag-fetching).

## User-level instructions

[`user-instructions.md`](./user-instructions.md) is copied to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` **(script)**. Edit the repo copy and re-run `bash ai_tools/setup.sh claude-code codex`.

## Skills

[`skills`](./skills/README.md) holds agent skills, mostly modified copies of [mattpocock/skills](https://github.com/mattpocock/skills) and [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack).

The `skills` step copies each into `~/.agents/skills` and links it from `~/.claude/skills` **(script)**, deleting every other entry in both except Claude Code's `synced` and dot-entries. `--status` lists what it would delete. Edit skills in the repo and re-run the step. `code-review` replaces Claude Code's bundled one, and `interrogate` needs both `claude` and `codex` signed in.

## Ubuntu

The same steps, without the ChatGPT app or computer use. The `codex` step installs `bubblewrap` and, if needed, an AppArmor profile **(script)**; test with `codex sandbox -- /bin/true`. Codex keeps MCP OAuth tokens in `~/.codex/.credentials.json`, readable only by you, since the keyring is locked over SSH.

### Notifications over SSH

Notifications travel over SSH to Ghostty on the Mac. The script sets Claude Code's channel to `ghostty` and Codex's to `osc9` unless you set your own **(script)**. Test with `scripts/test-notification.sh` in tmux.

### T3 Code on Ubuntu

One T3 Code server runs as a service, so the Mac and phone share it. Never start a second one on the same data.

- **Service (script).** The `t3` CLI and a service on loopback port 3773, started at boot, telemetry off. `systemctl --user status t3code`; log in `~/.t3/userdata/logs/boot-service.log`.
- While another server runs, the script leaves the service and its settings alone, and `--status` reports it. Stop it and re-run.
- The service gets the same [app settings](#app-settings), and the script asks before restarting it.
- Agents get the `docker` group after the first reboot. It's root-equivalent.
- When T3 Code's browser needs root setup, the script prints the command instead of running it, since `~/.local/bin/t3` is user-writable.
- **Desktop app (script).** On Ubuntu Desktop, the latest release's `.deb`, checked against the digest GitHub lists, with its own server off so it connects to the service, and telemetry off from the next login. It updates itself, asking for your password.

## Manual steps

`bash ai_tools/setup.sh manual-steps` prints these from this section. The rest are in the main README's [Manual steps](../README.md#manual-steps).

### macOS

1. **Logins.** Run `claude auth login`, sign in to the Claude and ChatGPT apps, and open T3 Code once. If `--status` says Codex isn't signed in, run `codex login`.
2. **Notifications.** In **System Settings → Notifications**, allow notifications with the **Persistent** style for Claude, ChatGPT, T3 Code, **Codex Computer Use**, and any terminal other than Ghostty. `manual-steps` opens the ones it can tell aren't set.
3. **Claude in Chrome.** See [Browser (Claude in Chrome)](#browser-claude-in-chrome).
4. **Claude Code computer use.** Per project, see [Computer use](#computer-use).
5. **ChatGPT app.** Set up Codex's [Browser](#browser) and [Computer use](#computer-use-1).
6. **T3 Code phone app.** See [Mobile](#mobile).
7. **Codex Remote.** In the ChatGPT app, set up **Settings → Connections → Control this Mac or PC** and scan the QR code with the phone app.
8. **Claude phone app.** Install it, sign in, and allow notifications.
9. **Training opt-outs.** See [Privacy](#privacy).
10. **GitHub repositories.** Enable **Allow squash merging**, and **Allow auto-merge** if you use it.

### Ubuntu

Over SSH, logins print a link to open on the Mac.

1. **Sudo work.** If setup ran without a terminal, run `bash ai_tools/setup.sh codex t3-code` from one.
2. **Claude Code.** `claude auth login`.
3. **Codex.** Turn on device code login in ChatGPT's **Settings → Security**, then `codex login --device-auth`.
4. **Claude in Chrome.** At the desktop, see [Browser (Claude in Chrome)](#browser-claude-in-chrome).
5. **T3 Code.** Connect to the [service](#t3-code-on-ubuntu):
   - `t3 connect --headless` (open the link on the Mac), `t3 connect publish`, then `t3 service restart`.
   - On the phone, steps 3 to 5 of [Mobile](#mobile).
   - In the Tailscale admin console, turn on **HTTPS Certificates** under **DNS**.
   - Run `t3 pair --tailscale` and paste the link in T3 Code on the Mac (**Settings → Connections → Add environment**). Don't use T3 Code's SSH connection type, which can start a second server.
   - After an agent first opens T3 Code's browser, re-run `bash ai_tools/setup.sh t3-code`. If it says the browser needs root, check `~/.local/bin/t3` is yours, then `sudo ~/.local/bin/t3 browser setup`.
   - At the desktop, run `t3 pair` and paste the link in the T3 Code app (**Settings → Connections → Add environment**).
6. **Claude app.** At the desktop, open Claude and sign in.

## Check it works

### macOS

- `command -v claude codex` prints two paths.
- `claude -p 'say ok'` and `codex exec --skip-git-repo-check 'say ok'` answer.
- `bash scripts/test-notification.sh` shows a notification.
- A commit from a T3 Code thread is signed.
- In a scratch repo under `~/Dev`, `claude -w test` starts in a worktree under `~/.worktrees`.
- Claude in Chrome and computer use can read a page or window title.

### Ubuntu

Over SSH from the Mac:

- `command -v claude codex t3` prints three paths.
- `claude -p 'say ok'` and `codex exec --skip-git-repo-check 'say ok'` answer.
- In tmux, `bash scripts/test-notification.sh` notifies on the Mac.
- After a reboot, `systemctl --user status t3code` is `active (running)`, T3 Code on the Mac reconnects, and an agent can run `docker ps`.

At the desktop, the T3 Code app shows the service's threads, and Claude opens signed in.

### Phone

- A turn on the Ubuntu server ends with a T3 Code push.
- A `/remote-control` session asked to notify you sends a Claude push.
- The ChatGPT app can start a Codex Remote task on the Mac.

## Maintenance

The `claude-code` and `codex` steps write only to `~/.claude` and `~/.codex`, and fail if `CLAUDE_CONFIG_DIR` or `CODEX_HOME` points elsewhere.

These apps don't document every key the steps write, so each was checked against one version. After an update, recheck the keys, fix the step, and update the version:

| App | Checked against | Key source |
| :- | :- | :- |
| Claude Code | 2.1.296 | [`scripts/claude-settings-keys.txt`](../scripts/claude-settings-keys.txt), checked by `scripts/check-ai-settings.sh` |
| Claude desktop app | 2.19675.0, and 2.42304.2 on Linux | Its `claude_desktop_config.json` |
| ChatGPT app | 26.930.21537 | The `[desktop]` table it writes in `~/.codex/config.toml` |
| T3 Code | 0.1.0 | Its [settings schema](https://github.com/pingdotgg/t3code/blob/v0.1.0/packages/contracts/src/settings.ts), checked by `scripts/check-t3-settings.sh` |

Then check the model shows in each app, notifications arrive, `pmset -g assertions` shows keep-awake during a task, and T3 Code starts at login (`launchctl getenv T3CODE_TELEMETRY_ENABLED` prints `false` on macOS; `systemctl --user is-enabled t3code` on Ubuntu).
