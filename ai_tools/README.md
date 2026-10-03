# AI tools

How to set up the AI tools on macOS: [Claude Code](#claude-code), the Claude desktop app, [Codex](#codex) (the Codex CLI and the ChatGPT desktop app), and [T3 Code](#t3-code). It covers installation, notifications, browser control, computer use, permissions, app settings, [privacy](#privacy), [user-level instructions](#user-level-instructions), and [skills](#skills).

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
  - [Permissions and memory](#permissions-and-memory)
  - [Desktop app settings](#desktop-app-settings)
- [Codex](#codex)
  - [Notifications](#notifications-1)
  - [Browser](#browser)
  - [Computer use](#computer-use-1)
  - [Permissions and output](#permissions-and-output)
  - [Desktop app settings](#desktop-app-settings-1)
- [T3 Code](#t3-code)
  - [Notifications](#notifications-2)
  - [App settings](#app-settings)
- [Privacy](#privacy)
- [User-level instructions](#user-level-instructions)
- [Skills](#skills)

## Automated setup

Run the AI tools setup script after the main `setup.sh`:

```sh
bash ai_tools/setup.sh
```

It's safe to re-run. Settings that are already in place are left alone, with no questions. Before editing a file that already exists, it asks whether to back it up to `<file>.bak`, unless that backup already matches the file. It does the following, and steps below marked **(script)** are done for you:

- Installs the Claude desktop app, the ChatGPT desktop app, T3 Code, and the Codex CLI with brew, and Claude Code with its native installer. Apps that are already installed are skipped.
- **Claude Code:** turns on **Push when actions required** and **Push when Claude decides**, starts new sessions in auto mode, turns off auto memory, and opts out of telemetry, error reports, surveys, and feedback, all in `~/.claude/settings.json`.
- **Claude desktop app:** turns on **Draw attention on notifications**, **Keep computer awake while Claude works**, **Keep awake on battery power**, and scheduled tasks, sets **Archive inactive sessions** to 30 days, turns off **Show in menu bar**, sets quick entry to Option+Space, and sets up Cowork (browser tools in Chrome, web search, scheduled tasks, files in `~/Documents/Claude`).
- **Codex:** sets terse output, the workspace-write sandbox with network access, approval on request, the PR merge method to squash, and the desktop app's notifications, keep-awake, menu bar, steering, detail view, link, and reasoning effort settings. It also turns off analytics and feedback uploads. All of these go in `~/.codex/config.toml`.
- **T3 Code:** sets the default model, auto mode, and worktree threads, turns on notifications with sound, makes a mid-turn message steer the turn, sets up storage cleanup, and turns off the Cursor, Grok, and OpenCode providers, in `~/.t3/userdata/settings.json` and `~/.t3/userdata/client-settings.json`. It also turns off T3 Code's telemetry with a LaunchAgent.
- **User-level instructions:** copies [`ai_tools/user-instructions.md`](./user-instructions.md) to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. See [User-level instructions](#user-level-instructions).
- **Skills:** installs the skills in [`ai_tools/skills`](./skills/README.md) for Claude Code and Codex. See [Skills](#skills).
- Opens **System Settings → Notifications** one at a time for each of Ghostty, Claude, ChatGPT, and T3 Code that isn't already allowed and Persistent, and opens the Claude in Chrome extension page if it isn't installed. macOS only lets a terminal with Full Disk Access read notification settings, so without it the script opens all four.

The Claude, ChatGPT, and T3 Code apps overwrite their settings files, so the script asks to quit them first. If they're still running (or the script isn't run from a terminal), it skips those settings and tells you to re-run. T3 Code can't be quit while the script runs in its built-in terminal, so run the script from Ghostty.

Scripts can't do the rest. macOS doesn't let them change notification alert styles or Accessibility/Screen Recording permissions, extensions have to be installed from the browser, `/mcp` and `/chrome` are interactive, and the training opt-outs are account settings (see [Privacy](#privacy)). Follow the remaining steps below.

Test notifications from your terminal (works inside tmux too):

```sh
scripts/test-notification.sh
```

## Updating

The `upgrade` shell function (in `zsh/aliases.zsh`) updates the AI tools along with everything else. Each tool is only updated if it's installed:

- **Codex CLI and Claude Code installed with brew:** `brew upgrade`.
- **Claude Code native install:** `claude update`.
- **Codex CLI or Claude Code installed with npm:** `npm install -g <package>@latest`. Plain `npm update -g` never moves Codex to a new 0.x minor version.
- **Claude, ChatGPT, and T3 Code desktop apps installed with brew:** `brew upgrade --cask --greedy`. They also update themselves. Apps that are running are skipped, with a message to quit them and re-run.
- **Claude Code plugins:** `claude plugin marketplace update`, then `claude plugin update` for each plugin in `claude plugin list`, in the scope it was installed in. Claude Code has no update-all, and an updated plugin only takes effect the next time it starts.
- **Codex plugins:** `codex plugin marketplace upgrade`. The bundled and runtime marketplaces (browser, computer use, documents, and so on) ship with the Codex CLI and update with it, so this only matters for a Git marketplace you add yourself.

`upgrade` doesn't touch the skills or the user-level instructions. They're installed from this repo, so to change them, update `ai_tools/skills` or `ai_tools/user-instructions.md` and re-run `bash ai_tools/setup.sh` (see [Skills](#skills)).

## Before you start

- Every app that sends notifications needs macOS permission with a **Persistent** alert style, so notifications stay on screen until you dismiss them. Set this in **System Settings → Notifications → (app)**: turn on **Allow notifications** and set the alert style to **Persistent**. The apps are your terminal (**Ghostty**, and any other terminal you run the CLIs in), **Claude**, **ChatGPT**, and **T3 Code (Alpha)**, plus **Codex Computer Use** if it's listed.
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

### Permissions and memory

The script sets both in `~/.claude/settings.json`:

```json
{
  "permissions": { "defaultMode": "auto" },
  "autoMemoryEnabled": false
}
```

- **Auto mode by default (script).** New sessions start in auto mode, where a classifier approves safe actions and asks about risky ones. Only user or managed settings can make `auto` the default. Claude Code ignores it in a project's `.claude/settings.json` or `.claude/settings.local.json`. Use `--permission-mode` to pick another mode for one session, or `Shift+Tab` to cycle modes. The first time you enter auto mode, Claude Code shows a one-time notice.
- **Auto memory off (script).** Claude Code stops saving its own notes about you and your projects between sessions. `CLAUDE.md` files still load.

Docs: [Permission modes](https://code.claude.com/docs/en/permission-modes), [Settings](https://code.claude.com/docs/en/settings-reference)

### Desktop app settings

These are in the Claude desktop app (`/Applications/Claude.app`), mostly under **Settings → Claude Code**. **Show in menu bar** is under **Settings → General**. The script writes the settings marked **(script)** to `~/Library/Application Support/Claude/claude_desktop_config.json`, all under `preferences` except `coworkUserFilesPath`:

- **Show in menu bar: Off (script).** With it on, Claude keeps a menu bar icon and goes on running in the background after you close the window. With it off there's no menu bar icon, and closing the window leaves nothing behind but the Dock icon until you quit with ⌘Q.
- **Draw attention on notifications: On (script).** Bounces the Dock icon when Claude needs you and the app isn't focused. Also go to **System Settings → Notifications → Claude**, turn on **Allow notifications**, and set the alert style to **Persistent**.
- **Archive inactive sessions: On, set Inactive for at least to 30 days (script).** Archives local sessions with no activity. Sessions that are running or have background work are never archived, and a worktree with uncommitted changes stays on disk.
- **Keep computer awake while Claude works: On (script).** Stops the computer idle-sleeping while a Code session is running, so long tasks can finish. The display can still turn off, and closing the lid still sleeps the Mac.
- **Keep awake on battery power: On (script).** Applies the same while running on battery.

- **Quick entry: Option+Space (script).** Opens the quick entry window from anywhere.
- **Scheduled tasks: On (script).** Turned on for both Code sessions and Cowork.
- **Cowork (script).** Cowork uses browser tools in Chrome and web search, and saves files in `~/Documents/Claude`. The script creates the folder.

The keys are `menuBarEnabled`, `dockBounceEnabled`, `ccAutoArchiveInactiveDays`, `ccKeepAwakeWhileWorking`, `ccKeepAwakeOnBattery`, `ccdScheduledTasksEnabled`, `quickEntryShortcut`, `coworkBrowserToolsEnabled`, `coworkPreferredBrowser`, `coworkWebSearchEnabled`, `coworkScheduledTasksEnabled`, and the top-level `coworkUserFilesPath`. The two keep-awake settings are on by default, as is `menuBarEnabled`. The script sets them anyway so they stay the way you want them even if you changed them in the app.
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

### Permissions and output

The script sets these top-level keys in `~/.codex/config.toml` **(script)**:

```toml
model_verbosity = "low"
model_reasoning_summary = "concise"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true
```

- **Permissions.** Codex reads, edits, and runs commands in the workspace without asking, and those commands can reach the network. It asks before anything outside the workspace. `on-request` and `workspace-write` are the defaults for a trusted project, but setting them also covers projects you haven't trusted yet. Network access is off by default.
- **Desktop app.** The app uses these keys only while its permission picker shows **Custom (config.toml)**, which it picks by default when `config.toml` sets `sandbox_mode`. Choosing **Ask for approval** in the picker ignores `config.toml` and turns network access off.
- **Output.** `model_verbosity = "low"` keeps answers short and `model_reasoning_summary = "concise"` keeps the reasoning summaries short.

Docs: [Approvals and security](https://learn.chatgpt.com/docs/agent-approvals-security), [Config reference](https://learn.chatgpt.com/docs/config-file/config-reference)

### Desktop app settings

- **Show in menu bar: Off (script).** **Settings → General**. Described in the app as "Keep ChatGPT in the macOS menu bar when the main window is closed", so with it off there's no menu bar icon and nothing keeping the app up once you close the window. On by default.
- **Prevent sleep while running: On (script).** **Settings → General**. Keeps the computer awake while Codex runs a task. The display can still turn off, and closing the lid still sleeps the Mac. Off by default.
- **Keep this Mac awake: On (script).** **Settings → Connections**, for this Mac. Stops the Mac sleeping while it's plugged in and Codex Remote access is on, so your phone can reach it. Off by default.

  All three are saved in `~/.codex/config.toml`:

  ```toml
  [desktop]
  mac-menu-bar-enabled = false
  preventSleepWhileRunning = true
  keepRemoteControlAwakeWhilePluggedIn = true
  ```

- **Pull request merge method: Squash (script).** Go to **Settings → Git → Pull request merge method** and choose **Squash** (the default is Merge). This is saved in `~/.codex/config.toml` as:

  ```toml
  [desktop]
  git-pull-request-merge-method = "squash"
  ```

  On GitHub, also enable **Allow squash merging** under **Repository settings → General → Pull Requests**.

- **Other app preferences (script).** The script also sets these `[desktop]` keys:

  ```toml
  [desktop]
  followUpQueueMode = "steer"                        # a message sent mid-turn steers it instead of queueing
  conversationDetailMode = "STEPS_COMMANDS"          # threads show steps and commands
  show-context-window-usage = true
  ambient-suggestions-enabled = true
  open-link-in-target-preference = "external-browser"       # links open in your browser,
  open-local-url-in-target-preference = "external-browser"  # not the built-in one
  worktree-upstream-refresh-mode = "never"
  enabled-reasoning-efforts = ["low", "medium", "high", "xhigh", "ultra", "persistent", "max"]
  ```

  `enabled-reasoning-efforts` lists the efforts the picker offers. Update it when the models change.

Docs: [App settings](https://learn.chatgpt.com/codex/reference/settings)

## T3 Code

[T3 Code](https://t3.codes/) is a desktop app for running coding agents, and it's the one I use every day. It runs the `claude` and `codex` CLIs installed above, signed in with the same accounts, so their settings, [user-level instructions](#user-level-instructions), and [skills](#skills) apply in T3 Code too.

Install **(script)**:

```sh
brew install --cask t3-code   # installs "T3 Code (Alpha).app", auto-updates
```

The `t3-code@nightly` cask installs nightly builds as a separate app, `T3 Code (Nightly).app`. The script and `upgrade` only handle `t3-code`.

T3 Code has a built-in browser that agents can drive (**Settings → Agent browser access**, on by default), so it needs no browser or computer use setup.

### Notifications

1. **Settings → Thread notifications: Notifications and sound (script).** A system notification and a sound when a thread finishes, fails, or needs input or approval. They only arrive while T3 Code is open.
2. **Settings → In-app notifications: On (script).**
3. **System Settings → Notifications → T3 Code (Alpha)**: turn on **Allow notifications** and set the alert style to **Persistent**.

Both settings are saved in `~/.t3/userdata/client-settings.json`:

```json
{
  "notificationMode": "notifications-and-sound",
  "inAppNotificationsEnabled": true
}
```

### App settings

The script merges these into `~/.t3/userdata/settings.json` **(script)**, keeping any other keys:

```json
{
  "defaultModelSelection": { "instanceId": "claudeAgent", "model": "claude-opus-5-5" },
  "defaultRuntimeMode": "auto",
  "defaultThreadEnvMode": "worktree",
  "addProjectBaseDirectory": "~/Dev",
  "continueThreadsAfterServerUpdate": true,
  "sidebarAutoSettleAfterDays": 5,
  "storageCleanup": {
    "worktreeAfterDays": 10,
    "worktreeOnMerge": true,
    "worktreeOnDelete": true,
    "worktreeUnchanged": true,
    "browserArtifactsAfterDays": 30,
    "logsAfterDays": 30
  },
  "providers": {
    "cursor": { "enabled": false },
    "grok": { "enabled": false },
    "opencode": { "enabled": false }
  }
}
```

- **Default model: Claude Opus 5.5 in auto mode.** New threads use Claude Code with `claude-opus-5-5`, in auto mode instead of the default full access. Update the model when a new one comes out.
- **New thread mode: worktree.** Each new thread gets its own git worktree.
- **Add project base directory: `~/Dev`.** The add-project picker starts there.
- **Continue threads after restarts: On.** Threads that were running pick up again after T3 Code updates and restarts.
- **Auto-settle inactive threads: 5 days** (the default is 3).
- **Settings → Storage.** Deletes a worktree once its thread has been inactive for 10 days, its PR has merged, its thread is deleted, or it has no commits beyond the default branch. Branches and thread history stay. Saved browser captures and rotated logs are deleted after 30 days.
- **Providers.** Only Claude Code and Codex are on. Cursor, Grok, and OpenCode are off (also their defaults).

And into `~/.t3/userdata/client-settings.json` **(script)**:

```json
{
  "followUpBehavior": "steer",
  "diffFilesCollapsed": false
}
```

- **Follow-up behavior: Steer.** A message sent mid-turn steers the running turn instead of waiting in a queue.
- **Default diff file state: Expanded.** Files in a diff open expanded.

Other settings, keybindings (`~/.t3/userdata/keybindings.json`), and themes keep the app's defaults.

## Privacy

Neither Claude nor ChatGPT has a config file setting that stops training on your chats. That is an account setting, so turn it off by hand:

- **Claude:** turn off model improvement in claude.ai → **Settings → Privacy** ([claude.ai/settings/data-privacy-controls](https://claude.ai/settings/data-privacy-controls)). This covers Claude Code (also when T3 Code runs it) and the desktop app. With it off, Anthropic keeps chats for 30 days instead of 5 years. Chats flagged for safety review can still be used.
- **ChatGPT and Codex:** ChatGPT → **Settings → Data controls → Improve the model for everyone → Off**. This covers Codex tasks in the CLI, the desktop app, and T3 Code. Codex also has a separate **Include environments** setting in its data controls on chatgpt.com/codex. It decides whether context from your Codex environments can be used for training, and the ChatGPT toggle doesn't change it, so turn it off too.
- **Don't rate replies.** For ChatGPT and Codex, a thumbs up or down or a feedback report sends the whole conversation to OpenAI even with training off. Treat Claude's thumbs the same way.

The script turns off the telemetry each tool sends **(script)**. In `~/.claude/settings.json`:

```json
{
  "env": {
    "DO_NOT_TRACK": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
    "DISABLE_FEEDBACK_COMMAND": "1"
  },
  "feedbackDrafts": "off"
}
```

- `DO_NOT_TRACK` turns off usage telemetry, the same as `DISABLE_TELEMETRY`. Remote Control and mobile pushes still work (Claude Code 2.1.283 or later).
- `DISABLE_ERROR_REPORTING` stops error reports to Sentry.
- `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` stops the "How is Claude doing?" surveys, which can attach the session transcript.
- `DISABLE_FEEDBACK_COMMAND` turns off `/feedback`, which uploads the transcript with a bug report. `feedbackDrafts` stops Claude drafting feedback for you.
- The script leaves `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` unset. It also turns off auto-updates and Remote Control, and with that the mobile push notifications.

The consumer Claude desktop app has no telemetry settings. The `disable*Telemetry` keys in Anthropic's docs only apply to enterprise deployments that use a third-party model provider.

In `~/.codex/config.toml`:

```toml
[analytics]
enabled = false

[feedback]
enabled = false
```

- `[analytics] enabled = false` turns off usage metrics and product events in the Codex CLI and the ChatGPT desktop app. The app starts Codex with `--analytics-default-enabled`, but an explicit `false` in `config.toml` wins.
- `[feedback] enabled = false` rejects `/feedback` log uploads. It doesn't hide the thumbs in the desktop app.

T3 Code sends anonymous usage events to PostHog unless `T3CODE_TELEMETRY_ENABLED=false` is in its environment. An app opened from the Dock or Finder gets the launchd environment, not your shell's, so the script installs `~/Library/LaunchAgents/dotfiles.t3code-telemetry-off.plist`, which runs `launchctl setenv T3CODE_TELEMETRY_ENABLED false` at every login, and runs that command once right away. Restart T3 Code for it to take effect. To undo it, delete the plist and run `launchctl unsetenv T3CODE_TELEMETRY_ENABLED`.

Docs: [Claude Code data usage](https://code.claude.com/docs/en/data-usage), [Claude privacy settings](https://privacy.claude.com/en/articles/12109829-how-do-i-change-my-model-improvement-privacy-settings), [Codex advanced config](https://learn.chatgpt.com/docs/config-file/config-advanced), [ChatGPT data controls](https://help.openai.com/en/articles/7730893-data-controls-in-chatgpt)

## User-level instructions

[`ai_tools/user-instructions.md`](./user-instructions.md) holds instructions for every Claude Code and Codex session, including the ones T3 Code runs, whatever the repo: finish tasks without check-ins, ask a specific question when stuck, and keep responses, comments, and docs concise.

**Install (script).** The script copies it to `~/.claude/CLAUDE.md` (Claude Code) and `~/.codex/AGENTS.md` (Codex). If either file already exists with different content, it asks before replacing it, and without a terminal it leaves the file alone.

To change them, edit the repo copy and re-run `bash ai_tools/setup.sh`. If you edit an installed file instead, the script asks to replace it on every run.

## Skills

[`ai_tools/skills`](./skills/README.md) holds agent skills, copied and modified from [mattpocock/skills](https://github.com/mattpocock/skills) and [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack), grouped into `engineering` and `productivity`.

**Install (script).** The script installs every skill globally with the [skills CLI](https://skills.sh). It needs `npx`, so install Node.js first (e.g. with mise); without it, the step is skipped.

```sh
npx skills@latest add ./ai_tools/skills --global --agent claude-code codex --skill '*' --yes
```

The CLI copies each skill into `~/.agents/skills`, which Codex reads, and symlinks it into `~/.claude/skills` for Claude Code. Type `/` in either tool, or in T3 Code, to see them.

Notes:

- **Changes need a re-run.** The installed skills are copies, so after editing, adding, or removing skills in `ai_tools/skills`, re-run `bash ai_tools/setup.sh`.
- **Removing a skill.** Deleting it from the repo doesn't uninstall it. Run `npx skills remove --global <name>`, or `npx skills list --global` to see what's installed.
- **No per-repo setup.** Skills that produce documents (`research`, `to-spec`, `to-tickets`, `handoff`) write them under `.scratch/` at the root of the repo you're in, and `implement` and `code-review-stds-and-spec` read them from there. The layout is in the [skills README](./skills/README.md#scratch-files). Decide per repo whether to commit `.scratch/` or gitignore it.
- **Updating from upstream.** The skills are modified copies, so don't overwrite them with a fresh clone. Diff the upstream skill against ours, port what's wanted, and re-run the script.
