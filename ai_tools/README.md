# AI tools

How to set up the AI tools on macOS, and on an [Ubuntu](#ubuntu-1) machine used over SSH: [Claude Code](#claude-code), the Claude desktop app, [Codex](#codex) (the Codex CLI and the ChatGPT desktop app), and [T3 Code](#t3-code), with their [privacy](#privacy) settings, [user-level instructions](#user-level-instructions), and [skills](#skills).

## Table of contents

- [First run](#first-run)
- [Automated setup](#automated-setup)
- [Updating](#updating)
- [Claude Code](#claude-code)
- [Codex](#codex)
- [T3 Code](#t3-code)
- [Privacy](#privacy)
- [User-level instructions](#user-level-instructions)
- [Skills](#skills)
- [Ubuntu](#ubuntu-1)
- [Manual steps](#manual-steps)
- [Check it works](#check-it-works)
- [Maintenance](#maintenance)

## First run

### macOS

1. Run the main [`setup.sh`](../README.md#first-run) first. The steps here need its `jq`, `yq`, and Node.
2. Quit the Claude, ChatGPT, and T3 Code apps, open a new Ghostty window, and run `bash ai_tools/setup.sh`. Run it from Ghostty, since T3 Code can't be quit while the script runs in T3 Code's terminal.
3. Do the macOS [manual steps](#macos-1): the logins, the notifications, and the phone apps.
4. Run the [checks](#check-it-works).

### Ubuntu

1. Run the main `setup.sh` first, including the `ubuntu` step, which turns on linger for the T3 Code service.
2. From a terminal at the machine, or over SSH, run `bash ai_tools/setup.sh`. Steps that need `sudo` ask for it there.
3. Do the Ubuntu [manual steps](#ubuntu-2): the logins and the T3 Code connections.
4. Reboot once, as the main README's [First run](../README.md#ubuntu) says, then run the [checks](#check-it-works) over SSH from the Mac.

## Automated setup

```sh
bash ai_tools/setup.sh              # every step
bash ai_tools/setup.sh codex skills # only these steps
bash ai_tools/setup.sh --status     # what's set up, changing nothing
```

The steps, in order, are `claude-code`, `claude-desktop`, `codex`, `t3-code`, `skills`, and `manual-steps`. Ubuntu skips `claude-desktop`; see [Ubuntu](#ubuntu-1). Each step's script also runs on its own and lists the settings it writes. Its path is `ai_tools/<step>/install.sh`, except for `ai_tools/manual-steps.sh`.

The script works like `setup.sh` (see [How setup works](../README.md#how-setup-works)). A model, effort, or footer you set yourself is kept, and a run with a terminal asks each time whether to replace it. `--status` also checks the logins. On macOS the script asks to quit the Claude, ChatGPT, and T3 Code apps, which overwrite their settings files, and skips their settings while they run.

Steps marked **(script)** below are done for you. The script adds no MCP servers. Add your own with `claude mcp add --scope user <name> ...` or `codex mcp add <name> ...`.

## Updating

The `upgrade` shell function updates the AI tools with everything else, through `upgrade-ai-tools`, which you can also run on its own. It updates only what's installed, and lists the failed stages at the end:

- **Claude Code native install:** `claude update`.
- **Codex CLI or Claude Code installed with npm:** `npm install -g <package>@latest`. mise later removes the Node version that holds them, so prefer brew or `mise use -g npm:<package>`, which the main [`upgrade`](../README.md#updating) updates.
- **t3 CLI and the T3 Code service:** `t3 update`. It asks before restarting a running service.
- **Desktop apps installed with brew:** `brew upgrade --cask --greedy`, skipping running apps.
- **Codex CLI installed with brew:** `brew upgrade --cask --greedy codex`, even while it runs.
- **Codex CLI from its standalone installer:** `codex update`.
- **Claude Code plugins:** `claude plugin marketplace update`, then `claude plugin update` for each user plugin in `claude plugin list`. A running session keeps the old version until `/reload-plugins`.
- **Codex plugins:** `codex plugin marketplace upgrade`, for a Git marketplace you added.

## Claude Code

Install **(script)** with the native installer, which auto-updates. Browser control and computer use need a claude.ai login on a Pro or Max plan.

### Notifications

Claude Code notifies when it finishes or waits on a permission prompt while you're away from the terminal. It sends desktop notifications in Ghostty, iTerm2, and kitty, inside tmux too. In other terminals, such as Apple Terminal, set `"preferredNotifChannel": "terminal_bell"`.

The script turns on push notifications to the Claude phone app, and Remote Control for all sessions, which pushes need **(script)**. If `/config` shows **No mobile registered**, open the Claude app once. Docs: [Mobile push notifications](https://code.claude.com/docs/en/remote-control#mobile-push-notifications).

### Browser (Claude in Chrome)

1. Install the [Claude in Chrome extension](https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn) and sign in with the same claude.ai account.
2. Run `claude --chrome` once, then restart Chrome.
3. Run `/chrome` and check for **Status: Enabled** and **Extension: Installed**. Select **Enabled by default** to skip `--chrome`, at the cost of context in every session.

If the extension stops responding, run `/chrome` → **Reconnect extension**. Docs: [Use Claude Code with Chrome](https://code.claude.com/docs/en/chrome).

### Computer use

1. In a session, run `/mcp`, select **`computer-use`**, and choose **Enable**. It's saved per project.
2. The first time, give the terminal **Accessibility** and **Screen Recording** in **System Settings → Privacy & Security**, then select **Try again**.
3. Approve each app Claude wants to control. Press `Esc` to stop it.

Docs: [Computer use](https://code.claude.com/docs/en/computer-use).

### Permissions and memory

Sessions start in auto mode, where a classifier approves safe actions and asks about risky ones **(script)**. Auto memory is off, and transcripts are kept 90 days instead of 30. The script adds no permission rules and leaves yours alone. T3 Code runs the same CLIs, so these settings apply there too, except the model, effort, mode, and sandbox, which T3 sets per session.

`permissions.defaultMode`, `tui`, `editorMode`, `cleanupPeriodDays`, and the script's other settings are reset on every run, so change them in [`claude-code/install.sh`](./claude-code/install.sh), not in `/config`. A model, effort, or status line you change is kept unless you agree to replace it when the script asks. The keys the script sets in `~/.claude/settings.json` were checked against Claude Code 2.1.296. Docs: [Settings](https://code.claude.com/docs/en/settings-reference).

### Model and interface

- **Model (script).** Opus 5.5 at medium effort, and Sonnet 5.5 at high. To switch for one session, press `s` in the `/model` picker.
- **Interface (script).** The fullscreen TUI with normal (not vim) key bindings. When safeguards flag a message, Claude Code switches models instead of pausing.
- **Status line (script).** [`claude-code/statusline.sh`](./claude-code/statusline.sh) shows the model, effort, context used, the 5-hour rate limit, and the branch: `Opus 5.5 · medium · ctx 43% · 5h 24% · main`.
- **Worktrees (script).** [`claude-code/worktree-hook.sh`](./claude-code/worktree-hook.sh) puts the worktrees of `--worktree`, subagents, and background sessions under `~/.worktrees` through [`git wt`](../README.md#git) (see [Code layout](../README.md#code-layout)). When a session ends, the hook removes its subagents' worktrees that have no changes; remove the rest with `git wt rm`.
- **`.worktreeinclude`.** The hook copies the gitignored files and directories it lists into a new worktree. Naming an ignored directory, such as `node_modules/`, copies it whole. A pattern inside an ignored directory, such as `build/config.json` when `build/` is ignored, copies nothing, so name the directory instead.

### Desktop app settings

The Claude desktop app **(script)** stays out of the menu bar, bounces its Dock icon on notifications, keeps the Mac awake while Claude works, archives inactive sessions after 30 days, and opens quick entry with Option+Space. Anthropic doesn't document these keys. They come from the app's own config file, checked against Claude 2.19675.0. Docs: [Desktop app](https://code.claude.com/docs/en/desktop).

## Codex

The Codex desktop app is part of the **ChatGPT desktop app**, which alone has the browser, Chrome control, and computer use. The script installs the app and the CLI with brew **(script)**, and leaves alone a Codex from its standalone installer.

### Notifications

The desktop app notifies when a turn ends while it's unfocused, and on permission requests and questions **(script)**. On macOS the CLI notifies in Ghostty with no config, inside tmux too. Don't overwrite the top-level `notify` key, which the Computer Use plugin sets. Codex has no phone push, but **Codex Remote**, a [manual step](#macos-1), lets the phone start, approve, and review tasks on the Mac.

### Browser

- **Built-in browser.** Open it with `Cmd+Shift+B`, or ask Codex to use it. It has its own profile, without your logins.
- **Your Chrome.** In **Settings → Computer Use**, select **Chrome**, install the plugin and the ChatGPT extension, then type `@Chrome` in a chat.

Docs: [Browser](https://learn.chatgpt.com/codex/browser), [Chrome extension](https://learn.chatgpt.com/codex/chrome-extension).

### Computer use

1. In the ChatGPT app, open **Plugins**, install **Computer Use**, and turn it on.
2. Give **Codex Computer Use** **Screen Recording** and **Accessibility** when asked.
3. Approve each app it uses, or choose **Always allow**.

It can't control terminals or the ChatGPT app. Leave **Enable locked use** off unless you need it. Docs: [Computer use](https://learn.chatgpt.com/docs/computer-use).

### Permissions and output

In `~/.codex/config.toml` **(script)**:

- **Model.** `gpt-6.1-sol` at high effort, with short answers and concise reasoning summaries. The script sets the model, effort, and footer when they're unset, and a run with a terminal asks before replacing your own. The interrogate skill's Codex reviewer uses the same model, so update its table in `ai_tools/skills/engineering/interrogate/SKILL.md` with the script's.
- **Permissions.** Codex works in the workspace without asking, and sends anything else, network access included, to a reviewer agent instead of to you. The sandbox has no network unless you turn it on under `[sandbox_workspace_write]`, which the script leaves alone.
- **Rewritten file.** The step edits `config.toml` with yq 4.54.1 or later, which rewrites the whole file. Values and full-line comments stay, though a comment may move, but end-of-line comments may go, and multi-line strings and dotted keys may change form. When yq would change another value or drop a full-line comment, the step leaves the file alone and says why.

Docs: [Approvals and security](https://learn.chatgpt.com/docs/agent-approvals-security), [Config reference](https://learn.chatgpt.com/docs/config-file/config-reference).

### Desktop app settings

The ChatGPT app **(script)** stays out of the menu bar, keeps the Mac awake while a task runs and for Codex Remote while plugged in, squash-merges pull requests, lets a mid-turn message steer the turn, and opens links in your browser. OpenAI's reference doesn't list these `[desktop]` keys. They come from the file the app writes, checked against ChatGPT 26.930.21537. Docs: [App settings](https://learn.chatgpt.com/codex/reference/settings).

## T3 Code

[T3 Code](https://t3.codes/) is a desktop app for running coding agents, and the one I use every day. It runs the `claude` and `codex` CLIs, so their settings, instructions, and skills apply there too. The script installs the `t3-code` cask **(script)**, which auto-updates. The app runs its own server while it's open. The `t3` CLI runs the same server without the app, as on the [Ubuntu](#t3-code-on-ubuntu) machine.

### Mobile

The T3 Code phone app controls the agents on your Mac through **T3 Connect**, T3's hosted relay and the only connection that sends push notifications. The Mac has to be on, awake, and running T3 Code.

1. **Install the phone app.** [T3 Code - Remote Claude & more](https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824) on iOS, or **T3 Code** by T3 Tools on Google Play.
2. **Link the Mac.** In T3 Code, open **Settings → Connections**, sign in to T3 Connect, and turn on **T3 Connect** for the local environment.
3. **Publish activity.** In the same place, turn on **Publish agent activity**, or the phone gets no notifications.
4. **Sign in on the phone** with the same account, and choose the Mac's environment.
5. **Turn on notifications.** In the phone app, go to **Settings → Notifications**, turn on **Device Notifications**, and allow them.
6. **Optional: lock screen progress.** Turn on **Live Activity Updates** (iOS) or **Ongoing Agent Activity** (Android).
7. **Open T3 Code at login (script).** A LaunchAgent opens it at login, after turning telemetry off. macOS may show a "Background item added" notice, and lists it under **System Settings → General → Login Items → Allow in the Background**.
8. **Keep the Mac awake** with an Amphetamine session that lets the display sleep, or `caffeinate -i`, since T3 Code has no keep-awake setting.

Docs: [Remote access](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md), [Mobile notifications](https://github.com/pingdotgg/t3code/blob/main/docs/user/mobile-notifications.md).

### App settings

The script merges its settings into `~/.t3/userdata/settings.json` and `client-settings.json` **(script)**. New threads use Claude Opus 5.5 at medium effort with the 1M context window, in auto mode, each in its own worktree under `~/.t3/worktrees`. Threads continue after T3 Code restarts, a mid-turn message steers the turn, and pull requests squash-merge. A model or effort you pick in T3 Code is kept unless you agree to replace it when the script asks. T3 Code documents these keys only in its source; they were checked against T3 Code 0.0.45's [settings schema](https://github.com/pingdotgg/t3code/blob/v0.0.45/packages/contracts/src/settings.ts).

The script also makes T3 wait for existing worktree setup actions before it starts the agent. An action you add later needs `"async": false`, or another setup run. Keep dev servers in manual actions.

Worktree cleanup removes a worktree after its thread is idle 30 days, once its commits are in the remote default branch, or when its last thread is deleted. It keeps the branch, and skips a worktree with uncommitted changes or ignored files other than `node_modules`, such as a `.env`. Docs: [cleanup settings](https://github.com/pingdotgg/t3code/blob/main/docs/user/project-settings.md).

## Privacy

Training on your chats is an account setting, so turn it off by hand:

- **Claude.** Turn off model improvement in [claude.ai → Settings → Privacy](https://claude.ai/settings/data-privacy-controls). It covers Claude Code, T3 Code's Claude sessions, and the desktop app.
- **ChatGPT and Codex.** Turn off **Settings → Data controls → Improve the model for everyone** in ChatGPT, and **Include environments** in the Codex data controls on chatgpt.com/codex.
- **Don't rate replies.** A thumbs up or down sends the whole conversation, even with training off.

The script turns off Claude Code's error reporting and feedback prompts, Codex's analytics and feedback uploads, and T3 Code's telemetry **(script)**. Claude Code's usage telemetry stays on, since `/advisor`, skill syncing, and paste collapsing need the feature flags it fetches ([details](https://code.claude.com/docs/en/env-vars#features-that-need-feature-flag-fetching)). T3 Code on macOS needs no restart after the next login, since the LaunchAgent turns telemetry off before it opens the app. If macOS reopened T3 Code at login because **Reopen windows when logging back in** was checked, it may have started first, so quit and reopen it.

Docs: [Claude Code data usage](https://code.claude.com/docs/en/data-usage), [ChatGPT data controls](https://help.openai.com/en/articles/7730893-data-controls-in-chatgpt), [T3 Code telemetry](https://github.com/pingdotgg/t3code/blob/main/docs/user/telemetry.md).

## User-level instructions

[`ai_tools/user-instructions.md`](./user-instructions.md) holds instructions for every Claude Code and Codex session, T3 Code's included. The `claude-code` and `codex` steps copy it to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` **(script)**. To change it, edit the repo copy and re-run `bash ai_tools/setup.sh claude-code codex`. A copy you edited stays until you agree to replace it, which backs it up first.

## Skills

[`ai_tools/skills`](./skills/README.md) holds agent skills, grouped into `engineering` and `productivity`. Most are modified copies of [mattpocock/skills](https://github.com/mattpocock/skills) and [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack), each with its source's `LICENSE`.

The `skills` step installs them with a pinned version of the [skills CLI](https://skills.sh), which needs Node.js 24 or newer from the `runtimes` step **(script)**. Each skill is copied into `~/.agents/skills`, which Codex reads, and linked into `~/.claude/skills`. Type `/` in Claude Code or T3 Code, or `$` in Codex, to list them.

- **Changes need a re-run** of `bash ai_tools/setup.sh skills`, which backs up an edited copy before replacing it. It offers to remove each skill it installed that the repo no longer has, and leaves skills from elsewhere alone.
- **`code-review`** replaces Claude Code's bundled `/code-review`. In Codex, run it as `$code-review`.
- **`interrogate`** runs reviewers through `claude -p` and `codex exec`, so sign in to both.

## Ubuntu

Run `bash ai_tools/setup.sh` on the Ubuntu machine too, after its `setup.sh`. It runs `claude-code`, `codex`, `t3-code`, `skills`, and `manual-steps`. They set up the same as on macOS, without desktop apps or computer use. The `codex` step also installs `bubblewrap` for Codex's sandbox, with an AppArmor profile when needed **(script)**; test it with `codex sandbox -- /bin/true`.

### Notifications over SSH

Claude Code and Codex send notifications as escape sequences, which travel over SSH to Ghostty on the Mac. A tmux pane may not know it's in Ghostty, so the script sets Claude Code's channel to `ghostty` and Codex's to `osc9` **(script)**, unless you've set your own. Check it with `scripts/test-notification.sh` inside tmux over SSH.

### T3 Code on Ubuntu

The machine runs one T3 Code server all the time, as a service, so the Mac and the phone can both reach it. Two servers on the same data conflict, so nothing else may start one. The Ubuntu [manual steps](#ubuntu-2) connect the Mac and the phone to it.

- **Service (script).** The script installs the `t3` CLI and its service, which starts at boot on port 3773 with telemetry off. Check it with `systemctl --user status t3code`; its log is `~/.t3/userdata/logs/boot-service.log`.
- **Another server.** While another T3 Code server runs, such as one the Mac started over SSH, the script changes neither the settings nor the service, and `--status` reports it. Stop it and re-run the script. If the service failed in the meantime, run `systemctl --user reset-failed t3code` first, or systemd refuses to start it for 5 minutes.
- **Settings (script).** The server gets the same [app settings](#app-settings). When they change, the script asks once to restart the service, which stops the threads running on it.
- **Docker access.** The service's agents get the `docker` group only after the reboot in the main README's [First run](../README.md#ubuntu). The group is root-equivalent, so an agent can get root through a container.
- **Browser (script, T3 Code 0.0.46+).** The script runs `sudo t3 browser setup`, after asking, when T3 Code's browser needs an AppArmor profile or libraries.

## Manual steps

Scripts can't do these. `bash ai_tools/setup.sh manual-steps` prints the list for its OS from this section, so edit the steps here. The other manual steps are in the main README's [Manual steps](../README.md#manual-steps).

### macOS

1. **Logins.** Run `claude auth login`. Sign in to the Claude and ChatGPT apps, and open T3 Code once. The ChatGPT app's Codex login also serves the Codex CLI. If `bash ai_tools/setup.sh --status` says Codex isn't signed in, run `codex login`.
2. **Notifications.** In **System Settings → Notifications**, turn on **Allow notifications** and set the alert style to **Persistent**, for Claude, ChatGPT, T3 Code, **Codex Computer Use** if it's listed, and any terminal other than Ghostty you run the CLIs in. Ghostty's are in the main README's [Ghostty notifications](../README.md#ghostty-notifications). `manual-steps` opens the ones it can tell aren't set.
3. **Claude in Chrome.** Set it up as [Browser (Claude in Chrome)](#browser-claude-in-chrome) says.
4. **Claude Code computer use.** Turn it on in each project you want it in, as Claude Code's [Computer use](#computer-use) says.
5. **ChatGPT app.** Set up Codex's [Browser](#browser) and [Computer use](#computer-use-1).
6. **T3 Code phone app.** Do the steps in [Mobile](#mobile).
7. **Codex Remote.** In the ChatGPT app, set up **Settings → Connections → Control this Mac or PC**, and scan the QR code with the ChatGPT phone app.
8. **Claude phone app.** Install it, sign in with Claude Code's account, and allow its notifications. See Claude Code's [Notifications](#notifications).
9. **Training opt-outs.** Turn them off in claude.ai, ChatGPT, and chatgpt.com/codex, as [Privacy](#privacy) says.
10. **GitHub repositories.** Under **Repository settings → General → Pull Requests**, enable **Allow squash merging**, and **Allow auto-merge** if you use Claude's auto-merge.

### Ubuntu

Over SSH, the logins print a link to open on the Mac.

1. **Sudo work.** If you ran setup without a terminal, it skipped what needs sudo: bubblewrap and its AppArmor profile, `libatomic1` for the `t3` CLI, and `sudo t3 browser setup`. Run `bash ai_tools/setup.sh codex t3-code` from a terminal to do it.
2. **Claude Code.** Run `claude auth login`.
3. **Codex.** Turn on device code login in ChatGPT's **Settings → Security** on chatgpt.com, then run `codex login --device-auth`.
4. **Claude in Chrome.** At the Ubuntu desktop, set it up as [Browser (Claude in Chrome)](#browser-claude-in-chrome) says.
5. **T3 Code.** Connect everything to the [service](#t3-code-on-ubuntu):
   - Run `t3 connect --headless` and open the link on the Mac, then `t3 connect publish`, so the phone gets notifications, then `t3 service restart`.
   - On the phone, sign in to the T3 Code app and turn on notifications: steps 4 to 6 of [Mobile](#mobile).
   - In the Tailscale admin console, turn on **HTTPS Certificates** under **DNS**.
   - Run `t3 pair --tailscale`, and paste the link in T3 Code on the Mac (**Settings → Connections → Add environment**). Don't add the machine with T3 Code's SSH connection type, which starts its own server whenever its check for a running one fails. Remove any such connection there.
   - After an agent first opens T3 Code's browser in a thread, which downloads the browser, re-run `bash ai_tools/setup.sh t3-code`.
6. **Claude phone app, training opt-outs, and GitHub repository settings** belong to your accounts, so doing them once from the Mac covers this machine.

## Check it works

Run these once `ai_tools/setup.sh` and the manual steps are done. The shell and commit signing checks are in the main README's [Check it works](../README.md#check-it-works).

### macOS

- In a new Ghostty window, `command -v claude codex` prints a path for each.
- `claude -p 'say ok'` and `codex exec --skip-git-repo-check 'say ok'` each answer.
- In Ghostty, `bash scripts/test-notification.sh` from the repo shows a notification.
- A commit made from a T3 Code thread shows `Good "git" signature` with `git log --show-signature -1`.
- In a throwaway repo under `~/Dev`, `claude -w test` starts in a new worktree under `~/.worktrees`. When you exit, choose to remove the worktree; its directory under `~/.worktrees` is then gone.
- After `claude --chrome`, Claude opens `https://example.com` in Chrome and reads back the page title.
- With computer use on, Claude reads the title of an open TextEdit or Finder window.

### Ubuntu

Run these over SSH from the Mac.

- In a new SSH session, `command -v claude codex t3` prints a path for each.
- `claude -p 'say ok'` and `codex exec --skip-git-repo-check 'say ok'` each answer.
- Inside tmux, `bash scripts/test-notification.sh` from the repo shows a notification on the Mac.
- A commit made from a T3 Code thread on this machine shows `Good "git" signature`.
- `claude -w test` in a throwaway repo under `~/Dev` starts in a new worktree under `~/.worktrees`.
- After a reboot, `systemctl --user status t3code` shows `active (running)`, T3 Code on the Mac reconnects, and an agent in a thread on this machine can run `docker ps` and `node -v`.

### Phone

- With the T3 Code phone app in the background, start a turn from the Mac in a thread on the Ubuntu server. The phone gets a push notification when the turn ends.
- In an interactive Claude Code session, ask "notify me when you're done" with a short task, then switch away from the terminal. The Claude phone app gets a push notification.
- The ChatGPT phone app lists the Mac under Codex Remote and can start a task on it.

## Maintenance

**Where the steps write.** The `claude-code` and `codex` steps write config only to `~/.claude` and `~/.codex`, so a `CLAUDE_CONFIG_DIR` or `CODEX_HOME` elsewhere fails them. The `t3-code` step writes to `~/.t3/userdata`, plus a LaunchAgent on macOS and a systemd drop-in for `t3code.service` on Ubuntu. The `skills` step backs up edited skills to `${XDG_STATE_HOME:-~/.local/state}/dotfiles/skills-backup/`.

**When an app updates.** Some keys the script writes aren't documented, so each section that sets them names the version they were checked against. After an update, check those keys against the app's settings file or schema, fix the script if they changed, and update the version. Then check that the app still does what setup configured:

- **Model.** Claude Code's status line starts with `Opus 5.5 · medium`, and the Codex CLI's footer shows `gpt-6.1-sol` with high effort. In the apps, the model picker of a new chat or thread shows the same.
- **Notifications.** For each app, start a short task, switch away, and wait for the notification.
- **Keep-awake.** While the Claude app or ChatGPT runs a task, `pmset -g assertions` lists a `PreventUserIdleSystemSleep` assertion from it.
- **T3 Code at login.** On macOS, after a login T3 Code is running and `launchctl getenv T3CODE_TELEMETRY_ENABLED` prints `false`. On Ubuntu, `systemctl --user is-enabled t3code` prints `enabled`.

**A newer skills CLI.** Check its flags, Node.js version, and copy exclusions, then update `SKILLS_CLI` and the related values in [`skills/install.sh`](./skills/install.sh) and its tests.
