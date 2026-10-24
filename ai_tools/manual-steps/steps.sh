# The AI tool steps scripts can't do, as ai_tools/README.md's "Manual steps" lists them: the list
# scripts/manual-steps-doc.sh writes there, and the checks ai_tools/manual-steps/install.sh runs.
# lib/manual.sh says how to declare one; the checks are functions in install.sh. Source it; don't
# run it.
# shellcheck shell=bash

# shellcheck disable=SC2034 # lib/manual.sh reads it
MANUAL_DOC="$DOTFILES_DIR/ai_tools/README.md"

manual_steps() {
    manual_reset

    manual_step macos logins <<'MD'
**Logins.**
MD
    manual_step macos claude-login --parent logins --bullet --elsewhere \
        --check claude_signed_in "Signed in to Claude Code" <<'MD'
Run `claude auth login`.
MD
    manual_step macos app-logins --parent logins --bullet <<'MD'
Sign in to the Claude and ChatGPT apps, and open T3 Code once.
MD
    manual_step macos codex-login --parent logins --bullet --elsewhere \
        --check codex_signed_in "Signed in to Codex" <<'MD'
Run `codex login`, if signing in to the ChatGPT app didn't sign Codex in.
MD
    manual_step macos notifications <<'MD'
**Notifications.** In **System Settings → Notifications**, allow notifications with the **Persistent** style for:
MD
    manual_step macos app-notifications --parent notifications --bullet --check app_notifications \
        "Claude, ChatGPT, and T3 Code notifications allowed, with the Persistent style" <<'MD'
Claude, ChatGPT, and T3 Code. `manual-steps` opens the ones it can tell aren't set.
MD
    manual_step macos other-notifications --parent notifications --bullet <<'MD'
**Codex Computer Use**, and any terminal other than Ghostty.
MD
    manual_step macos claude-in-chrome \
        --check claude_in_chrome "Claude in Chrome's extension installed, and claude --chrome run" <<'MD'
**Claude in Chrome.** See [Browser (Claude in Chrome)](#browser-claude-in-chrome).
MD
    manual_step macos computer-use <<'MD'
**Claude Code computer use.** Per project, see [Computer use](#computer-use).
MD
    manual_step macos chatgpt-app <<'MD'
**ChatGPT app.** Set up Codex's [Browser](#browser) and [Computer use](#computer-use-1).
MD
    manual_step macos t3-phone <<'MD'
**T3 Code phone app.** See [Mobile](#mobile).
MD
    manual_step macos codex-remote <<'MD'
**Codex Remote.** In the ChatGPT app, set up **Settings → Connections → Control this Mac or PC** and scan the QR code with the phone app.
MD
    manual_step macos claude-phone <<'MD'
**Claude phone app.** Install it, sign in, and allow notifications.
MD
    manual_step macos training <<'MD'
**Training opt-outs.** See [Privacy](#privacy).
MD
    manual_step macos github-squash-merge \
        --check github_squash_merge "Squash merging allowed in your GitHub repositories" <<'MD'
**GitHub repositories.** Enable **Allow squash merging** in each, and **Allow auto-merge** if you use it.
MD

    manual_group ubuntu "Over SSH, logins print a link to open on the Mac."
    manual_step ubuntu sudo-work --check ai_sudo_work_done "The AI tools' sudo changes made" <<'MD'
**Sudo work.** If setup ran without a terminal, run `bash ai_tools/setup.sh claude-desktop codex t3-code` from one.
MD
    manual_step ubuntu claude-login --elsewhere --check claude_signed_in "Signed in to Claude Code" <<'MD'
**Claude Code.** `claude auth login`.
MD
    manual_step ubuntu codex-login --elsewhere --check codex_signed_in "Signed in to Codex" <<'MD'
**Codex.** Turn on device code login in ChatGPT's **Settings → Security**, then `codex login --device-auth`.
MD
    manual_step ubuntu claude-in-chrome \
        --check claude_in_chrome "Claude in Chrome's extension installed, and claude --chrome run" <<'MD'
**Claude in Chrome.** At the desktop, see [Browser (Claude in Chrome)](#browser-claude-in-chrome).
MD
    manual_step ubuntu t3-code <<'MD'
**T3 Code.** Connect to the [service](#t3-code-on-ubuntu):
MD
    manual_step ubuntu t3-connect --parent t3-code --bullet --elsewhere \
        --check t3_connect_linked "T3 Connect linked and publishing agent activity" <<'MD'
`t3 connect --headless` (open the link on the Mac), `t3 connect publish`, then `t3 service restart`.
MD
    manual_step ubuntu t3-phone --parent t3-code --bullet \
        --check t3_phone_connected "T3 Code's phone app connected" <<'MD'
On the phone, steps 3 to 5 of [Mobile](#mobile).
MD
    manual_step ubuntu tailscale-https --parent t3-code --bullet \
        --check tailscale_https_on "Tailscale HTTPS certificates on" <<'MD'
In the Tailscale admin console, turn on **HTTPS Certificates** under **DNS**.
MD
    manual_step ubuntu t3-mac-paired --parent t3-code --bullet \
        --check t3_mac_paired "T3 Code on the Mac paired with the service" <<'MD'
Run `t3 pair --tailscale` and paste the link in T3 Code on the Mac (**Settings → Connections → Add environment**). Don't use T3 Code's SSH connection type, which can start a second server.
MD
    manual_step ubuntu t3-browser --parent t3-code --bullet --elsewhere \
        --check t3_browser_ready "T3 Code's browser can run in Chrome's sandbox" <<'MD'
After an agent first opens T3 Code's browser, re-run `bash ai_tools/setup.sh t3-code`. If it says the browser needs root, check `~/.local/bin/t3` is yours, then `sudo ~/.local/bin/t3 browser setup`.
MD
    manual_step ubuntu t3-desktop-paired --parent t3-code --bullet \
        --check t3_desktop_paired "T3 Code's desktop app paired with the service" <<'MD'
At the desktop, run `t3 pair` and paste the link in the T3 Code app (**Settings → Connections → Add environment**).
MD
    manual_step ubuntu claude-app <<'MD'
**Claude app.** At the desktop, open Claude and sign in.
MD
}
