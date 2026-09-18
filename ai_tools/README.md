# AI tools

How to set up the AI tools on macOS: [Claude Code](#claude-code), the Claude desktop app, and [Codex](#codex) (the Codex CLI and the ChatGPT desktop app). It covers installation, notifications, browser control, computer use, app settings, and [skills](#skills).

Scripts used here:

- [`ai_tools/setup.sh`](./setup.sh) installs and configures the AI tools.
- [`scripts/test-notification.sh`](../scripts/test-notification.sh) sends a test desktop notification through your terminal.

## Table of contents

- [Automated setup](#automated-setup)
- [Updating](#updating)
- [Before you start](#before-you-start)
- [Claude Code](#claude-code)
  - [Notifications](#notifications)
  - [Browser (Claude in Chrome)](#browser-claude-in-chrome)
  - [Computer use](#computer-use)
  - [Desktop app settings](#desktop-app-settings)
- [Codex](#codex)
  - [Notifications](#notifications-1)
  - [Browser](#browser)
  - [Computer use](#computer-use-1)
  - [Desktop app settings](#desktop-app-settings-1)
- [Skills](#skills)

## Automated setup

Run the AI tools setup script after the main `setup.sh`:

```sh
bash ai_tools/setup.sh
```

It's safe to re-run. Settings that are already in place are left alone, with no questions. Before editing a file that already exists, it asks whether to back it up to `<file>.bak`, unless that backup already matches the file. It does the following, and steps below marked **(script)** are done for you:

- Installs the Claude desktop app, the ChatGPT desktop app, and the Codex CLI with brew, and Claude Code with its native installer. Apps that are already installed are skipped.
- **Claude Code:** turns on **Push when actions required** and **Push when Claude decides** in `~/.claude/settings.json`.
- **Claude desktop app:** turns on **Draw attention on notifications**, **Keep computer awake while Claude works**, and **Keep awake on battery power**, and sets **Archive inactive sessions** to 30 days.
- **Codex:** sets the PR merge method to squash and turns on desktop app notifications, **Prevent sleep while running**, and **Keep this Mac awake** in `~/.codex/config.toml`.
- **Skills:** installs the skills in [`ai_tools/skills`](./skills/README.md) for Claude Code and Codex. See [Skills](#skills).
- Opens **System Settings → Notifications** one at a time for each of Ghostty, Claude, and ChatGPT that isn't already allowed and Persistent, and opens the Claude in Chrome extension page if it isn't installed. macOS only lets a terminal with Full Disk Access read notification settings, so without it the script opens all three.

The Claude and ChatGPT apps overwrite their settings files, so the script asks to quit them first. If they're still running (or the script isn't run from a terminal), it skips those settings and tells you to re-run.

Scripts can't do the rest. macOS doesn't let them change notification alert styles or Accessibility/Screen Recording permissions, extensions have to be installed from the browser, and `/mcp` and `/chrome` are interactive. Follow the remaining steps below.

Test notifications from your terminal (works inside tmux too):

```sh
scripts/test-notification.sh
```

## Updating

The `upgrade` shell function (in `zsh/aliases.zsh`) updates the AI tools along with everything else. Each tool is only updated if it's installed:

- **Codex CLI and Claude Code installed with brew:** `brew upgrade`.
- **Claude Code native install:** `claude update`.
- **Codex CLI or Claude Code installed with npm:** `npm install -g <package>@latest`. Plain `npm update -g` never moves Codex to a new 0.x minor version.
- **Claude and ChatGPT desktop apps installed with brew:** `brew upgrade --cask --greedy`. They also update themselves. Apps that are running are skipped, with a message to quit them and re-run.
- **Claude Code plugins:** `claude plugin marketplace update`, then `claude plugin update` for each plugin in `claude plugin list`, in the scope it was installed in. Claude Code has no update-all, and an updated plugin only takes effect the next time it starts.
- **Codex plugins:** `codex plugin marketplace upgrade`. The bundled and runtime marketplaces (browser, computer use, documents, and so on) ship with the Codex CLI and update with it, so this only matters for a Git marketplace you add yourself.

`upgrade` doesn't touch the skills. They're installed from this repo, so to change them, update `ai_tools/skills` and re-run `bash ai_tools/setup.sh` (see [Skills](#skills)).

## Before you start

- Every app that sends notifications needs macOS permission with a **Persistent** alert style, so notifications stay on screen until you dismiss them. Set this in **System Settings → Notifications → (app)**: turn on **Allow notifications** and set the alert style to **Persistent**. The apps are your terminal (**Ghostty**, and any other terminal you run the CLIs in), **Claude**, and **ChatGPT**, plus **Codex Computer Use** if it's listed.
- Both CLIs send notifications through the terminal. For Ghostty, see [Ghostty notifications](../README.md#ghostty-notifications).
- Install [Google Chrome](https://www.google.com/chrome/) and sign in to the sites you want the agents to use.

## Claude Code

Install **(script)** and sign in:

```sh
curl -fsSL https://claude.ai/install.sh | bash   # native installer, auto-updates
claude   # then run /login and sign in with your claude.ai account
```

Browser control and computer use need a claude.ai login (Pro or Max plan). They don't work with an API key, a `claude setup-token` token, or Bedrock/Vertex/Foundry.

### Notifications

Claude Code sends a notification when it finishes a task or is waiting on a permission prompt and you seem to be away from the terminal.

1. **No Claude Code config needed.** The default `preferredNotifChannel` is `auto`, which detects the terminal and sends desktop notifications in Ghostty, iTerm2, and kitty, and can ring the bell in Apple Terminal. Keep it on `auto` if you use several terminals, and allow notifications for each terminal app in macOS with the **Persistent** alert style.
2. **tmux:** `auto` detects the terminal from `TERM_PROGRAM`, which tmux normally sets to `tmux`, so Claude Code would send no notification. This repo's configs fix that for any terminal:

   ```tmux
   # tmux.conf
   set -g allow-passthrough on                          # lets notifications reach the outer terminal
   set -ga update-environment TERM_PROGRAM              # copies the outer terminal's name on attach
   set -ga update-environment TERM_PROGRAM_VERSION
   set -g extended-keys on                              # lets Shift+Enter insert a newline
   ```

   `zsh/hooks.zsh` then exports those values in tmux panes before each command, so Claude Code sees the real terminal. If you attach the same session from a different terminal, the next command you run picks up the new one.

3. **Mobile push notifications (script).** Claude Code can push to the Claude app on your phone. The script turns on both `/config` toggles in `~/.claude/settings.json`:

   ```json
   {
     "inputNeededNotifEnabled": true,
     "agentPushNotifEnabled": true
   }
   ```

   - **Push when actions required** (`inputNeededNotifEnabled`): permission prompts and questions.
   - **Push when Claude decides** (`agentPushNotifEnabled`): usually when a long task finishes. You can also ask for one, e.g. "notify me when the tests finish".

   Pushes are only sent while **Remote Control** is active in the session (`/remote-control`, or `claude --remote-control`). To connect every session, set **Enable Remote Control for all sessions** in `/config` (`"remoteControlAtStartup": true`). On your phone, install the Claude app, sign in with the same account, and allow notifications. If `/config` shows **No mobile registered**, open the Claude app once. Claude Code skips pushes while you're focused on the connected terminal.

   Docs: [Mobile push notifications](https://code.claude.com/docs/en/remote-control#mobile-push-notifications)

4. **Optional: also play a sound** with a `Notification` hook. Hooks run alongside the built-in notification. In `~/.claude/settings.json`:

   ```json
   {
     "hooks": {
       "Notification": [
         {
           "hooks": [{ "type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff" }]
         }
       ]
     }
   }
   ```

Docs: [Terminal config: notifications](https://code.claude.com/docs/en/terminal-config#get-a-terminal-bell-or-notification)

### Browser (Claude in Chrome)

Claude Code controls your real Chrome, using the tabs and logins you already have, through the Claude in Chrome extension.

1. Install the [Claude in Chrome extension](https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn) (v1.0.36+) and sign in with the same claude.ai account.
2. Start Claude Code with Chrome enabled:

   ```sh
   claude --chrome
   ```

   Press Enter on the one-time intro dialog. The first run installs a native messaging host at
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json`.
   **Restart Chrome** so it picks this up.
3. Run `/chrome` and check that it shows **Status: Enabled** and **Extension: Installed**.
4. **Enable by default:** in `/chrome`, select **Enabled by default** so you don't need `--chrome` each time. This loads the browser tools in every session and uses more context. Skip this if you rarely use the browser.
5. **Site permissions** come from the extension. Manage which sites Claude may browse, click, and type on in the extension's settings. In a session, approve the `Claude in Chrome wants to …` prompt, or allow all actions on that site for the session.

Troubleshooting:

- Extension not detected: check it's enabled in `chrome://extensions`, restart Chrome, then run `/chrome` → **Reconnect extension**.
- Tools stop working after being idle: the extension's service worker went to sleep. Run `/chrome` → **Reconnect extension**.
- A page stops responding: a JavaScript `alert`/`confirm` dialog is probably blocking it. Close the dialog by hand.

Docs: [Use Claude Code with Chrome](https://code.claude.com/docs/en/chrome)

### Computer use

Lets Claude open native apps, click, type, and take screenshots, for things that no MCP server, shell command, or the browser can do (native apps, iOS Simulator, GUI-only tools). It's a macOS research preview for Pro/Max plans and only works in interactive sessions (not `claude -p`).

1. In a Claude Code session, run `/mcp`, select the built-in **`computer-use`** server, and choose **Enable**. This is saved **per project**, so repeat it in each project where you want it.
2. The first time Claude uses the computer, grant the two macOS permissions it asks for to the terminal app running Claude Code (e.g. **Ghostty**):
   - **System Settings → Privacy & Security → Accessibility**: lets it click, type, and scroll
   - **System Settings → Privacy & Security → Screen Recording**: lets it see the screen

   Then select **Try again**. After granting Screen Recording, fully quit and restart Claude Code if the prompt keeps coming back.
3. **Approve apps per session:** each app Claude wants to control needs **Allow for this session**. Terminals/IDEs ("equivalent to shell access"), Finder, and System Settings show extra warnings.
4. **Stop at any time** by pressing `Esc` anywhere, or `Ctrl+C` in the terminal. Only one Claude session can use the computer at a time. It keeps the lock until that session exits.

If `computer-use` doesn't appear in `/mcp`, check your plan with `/status` and make sure you signed in with `/login` (not an API key).

The **Claude desktop app** has the same feature under **Settings → General → Computer use** (under Desktop app).

Docs: [Computer use in the CLI](https://code.claude.com/docs/en/computer-use)

### Desktop app settings

These are in the Claude desktop app (`/Applications/Claude.app`) under **Settings → Claude Code**. The script writes the settings marked **(script)** to `preferences` in `~/Library/Application Support/Claude/claude_desktop_config.json`:

- **Draw attention on notifications: On (script).** Bounces the Dock icon when Claude needs you and the app isn't focused. Also go to **System Settings → Notifications → Claude**, turn on **Allow notifications**, and set the alert style to **Persistent**.
- **Archive inactive sessions: On, set Inactive for at least to 30 days (script).** Archives local sessions with no activity. Sessions that are running or have background work are never archived, and a worktree with uncommitted changes stays on disk.
- **Keep computer awake while Claude works: On (script).** Stops the computer idle-sleeping while a Code session is running, so long tasks can finish. The display can still turn off, and closing the lid still sleeps the Mac.
- **Keep awake on battery power: On (script).** Applies the same while running on battery.

The keys are `dockBounceEnabled`, `ccAutoArchiveInactiveDays`, `ccKeepAwakeWhileWorking`, and `ccKeepAwakeOnBattery`. The two keep-awake settings are on by default. The script sets them anyway so they stay on even if you turned them off.
- **Pull request merge method: squash.** The app has no setting for this because it always squash-merges when auto-merge is on. On GitHub, enable **Allow squash merging** and **Allow auto-merge** under **Repository settings → General → Pull Requests**, or Claude can't merge the PR.

Docs: [Desktop app](https://code.claude.com/docs/en/desktop)

## Codex

The Codex desktop app now ships as part of the **ChatGPT desktop app** (`/Applications/ChatGPT.app`), which runs Codex chats alongside a Work mode. Its built-in browser, Chrome control, and computer use are **desktop app only**, and the Codex CLI doesn't have them. The Codex CLI (`npm i -g @openai/codex` or `brew install --cask codex`) supports terminal notifications only.

### Notifications

**Desktop app:**

1. **ChatGPT → Settings → Notifications (script)**: turn-completion notifications when unfocused, plus permission and question notifications. Stored in `~/.codex/config.toml`:

   ```toml
   [desktop]
   notifications-turn-mode = "unfocused"   # off | unfocused | always
   notifications-permissions-enabled = true
   notifications-questions-enabled = true
   ```

2. **System Settings → Notifications → ChatGPT**: turn on **Allow notifications** and set the alert style to **Persistent**.

**Mobile:** Codex has no push-notification setting to turn on. To get Codex tasks on your phone, connect your Mac with **Codex Remote**:

1. In the ChatGPT desktop app, go to **Settings → Connections → Control this Mac or PC** and set it up.
2. Scan the QR code with your phone, sign in to the same ChatGPT account and workspace, and approve the connection.
3. On your phone, allow notifications for the ChatGPT app. Keep the Mac awake and online while tasks run.

From the phone you can start, approve, and review tasks. OpenAI's docs don't describe push notifications for Remote, and some users report the mobile app doesn't send them for Codex tasks, so don't count on them.

Docs: [Codex Remote](https://learn.chatgpt.com/docs/remote)

**Codex CLI:** works with no config. By default `[tui]` has `notifications = true`, `notification_method = "auto"`, and `notification_condition = "unfocused"`. `auto` sends OSC 9 desktop notifications in terminals that support them (Ghostty, iTerm2, kitty, WezTerm, Warp) and rings the bell (BEL) in others. Inside tmux it detects the real terminal the same way Claude Code does (see [tmux](#notifications) above), wraps the sequence for tmux, and `allow-passthrough` lets it through.

> **Don't overwrite the top-level `notify` key** in `~/.codex/config.toml`. The Computer Use plugin sets it (`notify = [".../SkyComputerUseClient", "turn-ended"]`). `notify` runs an external program on `agent-turn-complete` and is separate from the built-in `[tui]` notifications.

Docs: [Config: notifications](https://learn.chatgpt.com/docs/config-file/config-advanced), [App settings](https://learn.chatgpt.com/codex/reference/settings)

### Browser

There are two options:

**Built-in browser** (installed automatically with the app):

- Open it from the toolbar, by clicking a URL, or with `Cmd+Shift+B`, or just ask Codex to use the browser in a task.
- Good for previewing local dev servers (`http://localhost:3000`), taking screenshots, and clicking through pages.
- It uses a **separate profile** from your normal browser, with no shared logins, history, or extensions. It can't automate file uploads.
- Manage it in **Settings → Browser**: turn the bundled Browser plugin on or off, manage downloads and data, and set allowed/blocked websites. Codex asks before visiting a new site unless you've allowed it.

**Your real Chrome** (the ChatGPT Chrome extension, for signed-in sites):

1. Open **Settings → Computer Use**, select **Chrome**, and install the required plugin when prompted.
2. Click **Install** to open the Chrome Web Store, add the ChatGPT extension, and accept its permissions.
3. Back in **Settings → Computer Use**, check that Chrome shows **Manage**.
4. In a Codex chat, type `@Chrome` to give it browser tasks. Pairing happens automatically for the active Chrome profile.
5. Manage site allowlists and blocklists in **Settings → Computer Use → Chrome → Manage**. Prompts offer allow once, allow for this site, allow for all sites, or decline.

If it doesn't connect: update the app, restart Chrome, make sure the right Chrome profile is active, start a new chat, or reinstall the extension from Settings.

Docs: [Browser](https://learn.chatgpt.com/codex/browser), [Chrome extension](https://learn.chatgpt.com/codex/chrome-extension)

### Computer use

1. In the ChatGPT desktop app, open **Plugins**, find **Computer Use**, select **Install plugin**, then enable it.
2. Grant the macOS permissions to **Codex Computer Use** when asked (or add them by hand in **System Settings → Privacy & Security**):
   - **Screen Recording**: lets it see the target app
   - **Accessibility**: lets it click, type, and navigate
3. **App approvals:** Codex asks before using each app. Choose **Always allow** to stop asking for that app, and review the list in **Settings → Computer Use → Always-allowed apps**.
4. **Optional: locked use.** **Settings → Computer Use → Enable locked use** lets tasks keep using apps after your Mac locks. It installs a macOS authorization plug-in, so only turn it on if you need it.

Limits: it can't control terminal apps or the ChatGPT app itself, and it can't get past admin password prompts. To revoke access, remove **Codex Computer Use** from Screen Recording and Accessibility in Privacy & Security.

Docs: [Computer use](https://learn.chatgpt.com/docs/computer-use)

### Desktop app settings

- **Prevent sleep while running: On (script).** **Settings → General**. Keeps the computer awake while Codex runs a task. The display can still turn off, and closing the lid still sleeps the Mac. Off by default.
- **Keep this Mac awake: On (script).** **Settings → Connections**, for this Mac. Stops the Mac sleeping while it's plugged in and Codex Remote access is on, so your phone can reach it. Off by default.

  Both are saved in `~/.codex/config.toml`:

  ```toml
  [desktop]
  preventSleepWhileRunning = true
  keepRemoteControlAwakeWhilePluggedIn = true
  ```

- **Pull request merge method: Squash (script).** Go to **Settings → Git → Pull request merge method** and choose **Squash** (the default is Merge). This is saved in `~/.codex/config.toml` as:

  ```toml
  [desktop]
  git-pull-request-merge-method = "squash"
  ```

  On GitHub, also enable **Allow squash merging** under **Repository settings → General → Pull Requests**.

Docs: [App settings](https://learn.chatgpt.com/codex/reference/settings)

## Skills

[`ai_tools/skills`](./skills/README.md) holds agent skills, copied and modified from [mattpocock/skills](https://github.com/mattpocock/skills) and [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack), grouped into `engineering` and `productivity`.

**Install (script).** The script installs every skill globally with the [skills CLI](https://skills.sh). It needs `npx`, so install Node.js first (e.g. with mise); without it, the step is skipped.

```sh
npx skills@latest add ./ai_tools/skills --global --agent claude-code codex --skill '*' --yes
```

The CLI copies each skill into `~/.agents/skills`, which Codex reads, and symlinks it into `~/.claude/skills` for Claude Code. Type `/` in either tool to see them.

Notes:

- **Changes need a re-run.** The installed skills are copies, so after editing, adding, or removing skills in `ai_tools/skills`, re-run `bash ai_tools/setup.sh`.
- **Removing a skill.** Deleting it from the repo doesn't uninstall it. Run `npx skills remove --global <name>`, or `npx skills list --global` to see what's installed.
- **No per-repo setup.** Skills that produce documents (`research`, `to-spec`, `to-tickets`, `handoff`) write them under `.scratch/` at the root of the repo you're in, and `implement` and `code-review-stds-and-spec` read them from there. The layout is in the [skills README](./skills/README.md#scratch-files). Decide per repo whether to commit `.scratch/` or gitignore it.
- **Updating from upstream.** The skills are modified copies, so don't overwrite them with a fresh clone. Diff the upstream skill against ours, port what's wanted, and re-run the script.
