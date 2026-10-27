# dotfiles

Setup for my Mac (Apple Silicon, macOS 27) and the Ubuntu 26.04 x86_64 desktop I use from it over SSH. Setup stops on an Intel Mac, and warns on ARM Ubuntu, where a package with no ARM build fails its step.

![zsh prompt](./resources/prompt.png)

## First run

Set up the Mac first: Ubuntu's **SSH key** manual step runs on the Mac.

### macOS

1. Clone the repo anywhere, such as `git clone https://github.com/gpahal/dotfiles ~/Dev/setup/dotfiles`. If `git` asks to install the Command Line Tools, install them and clone again.
2. Sign in to the App Store, so the `homebrew` step can install Amphetamine and Windows App. [Dato](https://apps.apple.com/app/dato/id1470584107) is paid and optional; buy it there first if you want it.
3. In the repo, run `bash setup.sh`.
4. Do the macOS [manual steps](#macos-1), starting with Ghostty's Full Disk Access.
5. From Ghostty, do the AI tools' [First run](./ai_tools/README.md#first-run).
6. Run the [checks](#check-it-works).

### Ubuntu

1. In the installer, choose TPM-backed disk encryption without a PIN ([guide](https://ubuntu.com/desktop/docs/en/latest/how-to/encrypt-your-disk-with-tpm/)), or none. A LUKS passphrase stops the machine booting unattended after a power cut.
2. At the machine, `sudo apt update && sudo apt install git`, then clone as on macOS.
3. Do the **BIOS/UEFI** [manual step](#ubuntu-2), and use Ethernet until setup prints the Wi-Fi commands.
4. At the machine, run `bash setup.sh`, then, there or over SSH, `bash ai_tools/setup.sh`.
5. Do the rest of the Ubuntu [manual steps](#ubuntu-2).
6. Reboot once, so the T3 Code service and tmux get the `docker` group.
7. Run the [checks](#check-it-works) over SSH from the Mac.

## How setup works

`bash setup.sh` runs these steps in order. Each is `<step>/install.sh` and also runs on its own:

| Step | What it does |
| :- | :- |
| `homebrew` | Installs [Homebrew](https://brew.sh/) and the [packages](#packages), after the apt packages it needs on Ubuntu |
| `runtimes` | Installs Node LTS and Go with mise, and Rust with rustup |
| `git` | Copies the git config and `git wt`, and offers a GitHub login with `gh` |
| `lazygit` | Copies the lazygit config |
| `ssh` | Makes `~/.ssh` private. On macOS, keeps keys in the keychain and loads them at login |
| `zsh` | Copies the zsh and starship config, hooks it into the startup files, imports your zsh history into atuin, records the [checkout](#where-the-repo-lives), and offers zsh as the login shell |
| `vim` | Copies the vim config and vim-plug, installs the plugins at their pins, and installs the Go tools vim-go uses |
| `tmux` | Copies the tmux config and `tmux-sessionizer`, and installs the pinned plugins. On Ubuntu, starts tmux at boot |
| `ghostty` | Copies the Ghostty config. On Ubuntu, installs the Ghostty snap and its terminfo, so SSH from Ghostty works |
| `zed` | Copies the Zed settings and keymap |
| `stream-deck` | Installs the [Stream Deck](#stream-deck) plugin and profiles, or on Ubuntu the daemon that drives the deck |
| `hammerspoon` | Copies the [Hammerspoon](#hammerspoon) config and the open-in script its hotkeys run. macOS only |
| `hotkeys` | Adds GNOME shortcuts that match [Hammerspoon](#hammerspoon)'s. Ubuntu only |
| `gnome` | Matches GNOME's keyboard, Files, and dock to the [macOS defaults](./macos/install.sh), and adds Quick Look. Ubuntu only |
| `vicinae` | Sets up the [Vicinae](#vicinae) launcher with the repo's shared settings, on `Cmd+Space` on macOS and `Super+Space` on Ubuntu, where it also installs it |
| `editorconfig` | Copies `~/.editorconfig` |
| `macos` | Sets [macOS defaults](./macos/install.sh), turns on the firewall, its stealth mode, and automatic App Store updates, frees `Cmd+Space` for Vicinae, and sets the hostname if needed. macOS only |
| `ubuntu` | Sets Ubuntu up for [running around the clock](#running-around-the-clock). Ubuntu only |
| `docker` | Installs Docker Engine. Ubuntu only; OrbStack provides Docker on macOS |
| `chrome` | Installs Google Chrome from Google's apt repo, and removes Firefox. Ubuntu only |
| `logitech` | Installs Solaar from the Solaar team's PPA in place of Logi Options+. Ubuntu only |
| `monitor-input` | Installs ddcutil and the service that switches the [monitor's input](#monitor-input). Ubuntu only |
| `manual-steps` | Prints this OS's [manual steps](#manual-steps) that aren't done yet |

- `bash setup.sh git zsh` runs only those steps; `--help` lists them. Re-runs are safe. A failed step skips the steps that need it, and the run ends with the command that re-runs the failures.
- `--status [step...]` reports what's set up and changes nothing. Root-only checks run only while `sudo -v` is cached.
- Setup overwrites installed configs that differ from the repo's, with no backup, so run `just copy-back` first to keep edits. Files other tools also edit (shell startup files, `~/.ssh/config`, `~/.gitconfig`) only get setup's own lines added. A merge into an app's settings file, such as Vicinae's, offers a backup first, and `--backup` or `--no-backup` answers every such question.
- Settings that are yours, such as mise's global versions and the AI tools' models, are set when unset. When yours differs, setup asks before replacing it, and keeps it without a terminal.
- Installers are fetched over HTTPS without pinned checksums, as their vendors document. Apt keys must match pinned fingerprints.
- The AI tools have their own script, `bash ai_tools/setup.sh` ([ai_tools/README.md](./ai_tools/README.md)).
- `just status` runs both scripts with `--status`.

### Where the repo lives

The repo can live anywhere, and setup and `just` run from any clone or worktree. Two things run outside the repo, `upgrade` and the daily health check, so the `zsh` and `ubuntu` steps record the checkout they run from in `~/.local/state/dotfiles/checkout`. From a worktree, they record its main checkout, so removing the worktree doesn't break them. After moving the repo, re-run `bash setup.sh zsh ubuntu` (`zsh` on the Mac) from its new place. `--status` reports a stale record.

## Ubuntu

Run setup as your own user, not root. On Ubuntu Server, run `bash setup.sh` naming every step except `ghostty`, `zed`, `stream-deck`, `logitech`, and `chrome`, and install `upower` for UPS detection.

- Homebrew installs the Brewfile minus its `if OS.mac?` block, and the casks in `UBUNTU_CASKS` in [`homebrew/install.sh`](homebrew/install.sh). zsh comes from apt, Ghostty from its snap.
- Homebrew comes first on PATH, so its `python3`, `curl`, and `pkg-config` shadow the system's. Build against system libraries with `PATH=/usr/bin:/bin`.
- tmux and vim copy through OSC 52 to the Mac's clipboard.
- `gh` stores its token in `~/.config/gh/hosts.yml`, since the keyring is locked over SSH, and git uses HTTPS. To push `.github/workflows` changes, run `gh auth refresh -h github.com -s workflow --insecure-storage` once.
- Both machines' tmux use the `Ctrl+a` prefix, so press it twice for the inner one.

### Running around the clock

The `ubuntu`, `docker`, and `chrome` steps keep the machine reachable:

- Suspend is off, and a kernel panic reboots after 10 seconds.
- With a USB UPS, the machine shuts down on low battery and starts when power returns.
- smartd, a daily health check, and each boot push alerts to your phone. The health check reports on the [recorded checkout](#where-the-repo-lives), and alerts when it's gone.
- Security, Chrome, and Docker updates install daily without rebooting.
- User services, such as the T3 Code server and tmux, start at boot without a login.
- sshd lets only you in, and turns off passwords once you've used a key. Use OpenSSH over the tailnet, not Tailscale SSH, which drops sessions when tailscaled restarts.
- You can run `tailscale serve` and `funnel` without `sudo`. `--status` flags an active funnel, and Tailscale SSH being on.
- ufw lets SSH in only from private ranges, and lets the tailnet reach every port. The tailnet's access rules are what protect the machine, so keep them tight.
- Docker's published ports listen on `127.0.0.1` unless given an address. Joining the `docker` group is root-equivalent, so the step asks.
- Wired connections wake on LAN, with the BIOS setting on.
- Wi-Fi power save is off, so SSH over Wi-Fi doesn't lag.
- cloud-init is off outside a VM, since it only sets up a fresh install. cups-browsed is masked, so network printers aren't added by themselves; printing still works.

## What's included

### git

Config in [`git/`](git/), copied to `~/.config/git/`. Per-machine settings go in `~/.gitconfig` or `~/.gitconfig.local`, which git reads after this config. Signing setup and `gh` write to `~/.gitconfig`.

- `git dft`, `git dd`, `git dlog`: difftastic diffs.
- `git cob`, `git cobr`: pick a local or remote branch with fzf.
- `git wt` manages worktrees under `~/.worktrees`. `cd "$(git wt add <name> [<base>])"`; `git wt` alone prints usage.

#### Code layout

Projects live at `~/Dev/<group>/<project>`, such as `~/Dev/go/envl`. Worktrees go beside projects, not inside them:

| Tool | Worktrees |
| :- | :- |
| `git wt`, the `implement` skill, and Claude Code's `--worktree`, subagents, and background sessions | `~/.worktrees/<group>/<project>/<name>`, or `~/.worktrees/_/<project>-<hash>/<name>` outside `~/Dev/<group>/<project>` |
| T3 Code | `~/.t3/worktrees/<repo>/<worktree>` |
| The Codex app | `~/.codex/worktrees` |

#### Commit signing

`just git-signing` signs commits and tags with an SSH key and prints the `gh` commands that add it to GitHub. macOS uses `~/.ssh/id_ed25519` from the keychain; Ubuntu uses `~/.ssh/id_ed25519_signing`, with no passphrase, since agents can't type one.

### GitHub repos

`just github-repo [owner/repo]` lists each of a repo's settings that differs from the standard and changes them once you confirm. With no repo, it uses the one you're in. `--check` only reports, and exits 3 if anything differs. You need admin on the repo.

The standard:

- Issues are on. Projects, wiki, and discussions are off.
- Merges are squash only. A squash commit takes the PR's title and description. Auto-merge, the update branch button, and deleting merged branches are on.
- A `main` ruleset that nobody can bypass. Every change goes through a PR, which needs no approval, passing required status checks, and a squash merge. `main` keeps a linear history of signed commits, and nobody can force-push to it or delete it.
- Actions must be pinned to a commit SHA, and `GITHUB_TOKEN` is read-only by default. Actions can open and approve PRs. A PR from any outside contributor waits for your approval before its workflows run.
- Secret scanning is on, with push protection. So are Dependabot alerts and security updates, private vulnerability reporting, CodeQL default setup, and immutable releases.
- The repo has `.github/dependabot.yml`, a copy of [`github/dependabot.yml`](github/dependabot.yml), which bumps the pinned actions monthly after a week's cooldown. In a checkout of the repo, the recipe copies the file there for you to commit in a PR.

For the required status checks, the recipe offers the ruleset's current ones for you to edit. A repo without a ruleset gets the checks that ran on its latest PR instead. `--checks check,lint` sets them without asking, and `--checks none` requires none.

### SSH

`just ssh-host <alias> [hostname]` adds a `~/.ssh/config` block with keepalives and a shared connection. `ssh -O exit <alias>` closes it.

### vim

[`vim/vimrc`](vim/vimrc) with vim-plug, plugins pinned by commit. Leader is `Space`: `e` NERDTree, `f` files, `/` ripgrep, `b` buffers.

### zsh

[`zsh/`](zsh/), copied to `~/.zsh/`, with starship. The login shell is the system zsh, so it survives a broken Homebrew. Put secrets and per-machine settings in `~/.zshrc.local`.

- `Ctrl+T` files, `Alt+C` directories, `Ctrl+R` and Up search history (atuin).
- `g`, `c` (`bat`), `t` (`eza --tree`), `port`, `killport`, `o`, `scratch`, `reload`, `zshrc` (edits `~/.zshrc`), `ts` (`tmux-sessionizer`).
- `rm` deletes immediately. On macOS, `trash` can be undone.

### Ghostty

[`ghostty/`](ghostty/). `` Cmd+` `` toggles the quick terminal (needs Accessibility). `Cmd+Shift+S` opens the screen's text in TextEdit.

#### Ghostty notifications

Claude Code and Codex notify through Ghostty, inside tmux too. Outside tmux, Ghostty also notifies when a command of 10 seconds or more finishes in an unfocused window. To allow the notifications:

1. Run `scripts/test-notification.sh` from the repo in Ghostty and click **Allow**. In **System Settings → Notifications → Ghostty**, allow notifications with the **Persistent** style.
2. Add Ghostty to any Focus mode's **Allowed Apps**.

### Zed

[`zed/`](zed/). AI features and telemetry are off, and so is its updater, so `upgrade` updates it. The window title ends with the file's path, which Stream Deck and Hammerspoon read.

### Stream Deck

The **Dotfiles** keys act on the folder of the app in front:

- **Overview**, labeled MAC or UBUNTU for the machine it runs on, shows CPU and memory, and on the 15-key model opens the **System** page of stats. **Back** there returns to the main page.
- **Editor** opens Zed, **Terminal** Ghostty, and **Files** the file manager there.
- **Agenda** and **Gmail** focus or open [the agenda](https://garvitpahal.com/x/agenda) and Gmail.
- **Chrome**, **New Tab**, **T3 Code**, and **Claude** match the Hammerspoon hotkeys.

[`layout.json`](stream-deck/com.gpahal.dotfiles.sdPlugin/layout.json) places the keys of both pages on both OSes. [`stream-deck/icons`](stream-deck/icons/README.md) lists the app icons' sources.

On macOS, a plugin adds the keys to Elgato's Stream Deck app, with a read-only profile for each page. Stream Deck shows the main page when it starts and when the deck comes back from Ubuntu, and setup deletes any other profile for the deck. The folder comes from a Ghostty tab, a Zed file, a Finder selection, or a T3 Code thread.

Elgato's app doesn't run on Linux. On Ubuntu, the `dotfiles-stream-deck` user service draws the same keys, and a GNOME extension lets it read and focus windows. Unlike on macOS:

- The folder comes from a Ghostty tab, a Zed file, or a file manager window's folder, not its selected file. With T3 Code in front, the keys open a new window.
- **Terminal** opens a Ghostty window, not a tab.
- **Agenda** and **Gmail** open in their own Chrome windows, and the stat keys open Resources.
- **Power** shows the CPU package, its cores, and the GPU, with no figure for the whole machine.
- Keys that open apps do nothing while the screen is locked.
- Only the 15-key model works. The daemon leaves other decks blank and logs why.
- The deck's brightness is 60%, set each time it connects.
- `journalctl --user -u dotfiles-stream-deck` shows its log.

### Hammerspoon

macOS only. Hotkeys on `Ctrl+Opt+Cmd` (Rectangle takes `Ctrl+Opt`):

- `Space` Claude, `B` Chrome, `C` T3 Code.
- `T` Ghostty and `E` Zed, at the folder in front.
- `N` a new Chrome tab, with the clipboard's text pasted and selected.

On Ubuntu, the `hotkeys` step adds the same shortcuts on `Ctrl+Alt+Super`, which run the [Stream Deck](#stream-deck)'s actions. A shortcut of yours on the same keys keeps them, and `--status` names it. `journalctl --user -t dotfiles-hotkeys` shows their log.

### GNOME

Ubuntu only. The `gnome` step sets what the `macos` step sets in Finder, the Dock, and the keyboard, where GNOME has a match:

- Keys repeat after 225 ms, then every 30 ms.
- Files shows hidden files and opens folders in list view. File choosers show hidden files too.
- The dock hides until the pointer reaches the screen's edge.
- Space in Files previews the selected file, as Quick Look does (gnome-sushi).

### Vicinae

[Vicinae](https://docs.vicinae.com/) launches apps, keeps clipboard history, and runs many Raycast extensions. `Cmd+Space` opens it on the Mac, and `Super+Space` on Ubuntu.

- Both machines share [`vicinae/dotfiles.json`](vicinae/dotfiles.json): favorites, fallbacks, keybindings, theme, font, window size, and extension settings, with telemetry off. The step copies it to `~/.config/vicinae/` and adds it to the `imports` in `~/.config/vicinae/settings.json`.
- Vicinae's settings window saves to `settings.json`, whose values win over the shared file. `--status` names each shared setting that `settings.json` overrides. To share a change, move it to `vicinae/dotfiles.json` and delete it from `settings.json`.
- On the Mac, the homebrew step installs it and `upgrade` updates it. Paste into the active window and snippets are on, and need the Accessibility permission.
- On Ubuntu, Vicinae's installer puts it in `~/.local`, without sudo, and `upgrade` moves it to the latest release. Paste into the active window and snippets are off, since they need root. Pick a clipboard entry to copy it, then press `Ctrl+V`.
- Its GNOME extension, from extensions.gnome.org, gives it the clipboard and the window list. GNOME loads it at the next login.
- `Super+Space` doesn't switch keyboard layouts. With more than one layout, `Shift+Super+Space` still does.
- A shortcut of yours on `Super+Space` keeps it, and `--status` names it. `journalctl --user -u vicinae` shows Vicinae's log on Ubuntu.

### Monitor input

A USB switch moves the keyboard, mouse, and Stream Deck between the Mac and the Ubuntu desktop, and the monitor's input follows them over DDC/CI. Each machine switches the monitor to itself when the devices arrive. Ubuntu also hands the monitor back to the Mac when the devices leave it, so switching works while the Mac sleeps.

1. Pick a device the switch moves, such as the keyboard's receiver. `just monitor-input` lists the attached devices' `vendor:product` IDs, and the common input codes.
2. On the Mac: `just monitor-input <vendor:product> <Mac's input>`, such as `just monitor-input 1234:5678 27` for USB-C.
3. On Ubuntu: `just monitor-input <vendor:product> <Ubuntu's input> <Mac's input>`, such as `just monitor-input 1234:5678 17 27` for HDMI 1. With more than one monitor connected, add the output, such as `HDMI-A-1`.
4. In the monitor's menu, turn off its automatic input selection, so it wakes from sleep on the input it showed rather than the one it prefers. Some monitors have a separate setting for USB-C, which needs turning off too.

`just monitor-input off` turns it off on that machine. Ubuntu logs each switch to `journalctl -u dotfiles-monitor-input`, and the Mac shows failures in Hammerspoon's console.

### Monitor volume

macOS can't set the volume of HDMI or DisplayPort audio, so while the monitor is the Mac's sound output, Hammerspoon has the volume keys set the monitor's own volume over DDC/CI with m1ddc, from the Brewfile. Mute sets the monitor's volume to 0 and unmute brings it back, and `Shift+Opt` makes finer steps. Other outputs, such as headphones, keep the usual keys. The monitor answers only while it shows the Mac, and only with DDC/CI on in its menu.

Ubuntu sets the volume of HDMI audio itself, so its volume keys work as usual.

Speakers plugged into a Dell monitor's audio line-out don't follow the monitor's volume, so on the Mac the keys don't reach them. To control them from the keyboard, plug them into the Mac over USB or Bluetooth, which macOS sets the volume of, or use an app that adds software volume to HDMI and DisplayPort outputs, such as SoundSource.

### tmux

Prefix `Ctrl+a`. `|` and `-` split, `hjkl` move, `HJKL` resize, `Ctrl+h` and `Ctrl+l` switch windows, `v` copy mode, `S` new session, `X` kill session, `f` `tmux-sessionizer`. vim-tmux-navigator takes `Ctrl+hjkl`, so clear the screen with `prefix+Ctrl+k`.

### Packages

The CLI tools are in [`homebrew/Brewfile`](homebrew/Brewfile), and the macOS apps in `CASKS` and `MAS_APPS` in [`homebrew/install.sh`](homebrew/install.sh).

### Touch ID for sudo

`just touch-id` makes `sudo` take Touch ID, inside tmux too. It writes `/etc/pam.d/sudo_local` whole, replacing any lines you added. Re-run it after `brew upgrade` updates pam-reattach; `--status` says when. If `sudo` breaks, remove the file with an admin password, then re-run it:

```sh
osascript -e 'do shell script "rm /etc/pam.d/sudo_local" with administrator privileges'
```

## Manual steps

`bash setup.sh manual-steps` prints the ones here that aren't done, leaving out each it can check is done, and `bash setup.sh --status manual-steps` reports those checks. The AI tools' are in [ai_tools/README.md](./ai_tools/README.md#manual-steps).

### macOS

**Permissions**

1. Give Ghostty Full Disk Access in **System Settings → Privacy & Security → Full Disk Access**, reopen it, and run `bash setup.sh macos` in the repo again. Do the rest from Ghostty.
2. Allow Ghostty's notifications, with step 1 of [Ghostty notifications](#ghostty-notifications).
3. Add Ghostty to any Focus mode's **Allowed Apps**.
4. Add Ghostty in **System Settings → Privacy & Security → Accessibility**.

**Apps**

5. Set Google Chrome as the default browser.
6. Open Logi Options+, grant its permissions, and pair your devices.
7. Open OrbStack once and finish its setup.
8. Open Vicinae and finish its onboarding. Grant Accessibility, which paste and snippets need, and keep Launch at login on. Full Disk Access is optional; file search needs it to cover every folder.
9. Open Rectangle, grant accessibility, and set your shortcuts.
10. Turn on Launch at login in Rectangle, Amphetamine, Tailscale, and Dato.
11. Optional: turn on AppCleaner's SmartDelete, and install [Supercharge](https://sindresorhus.gumroad.com/l/supercharge).
12. Open Stream Deck and accept its prompt to install the **Main** profile. Press **Overview** and accept the prompt for the **System** profile. Press **Editor**, **Terminal**, and **Files** with Ghostty, Zed, and Finder in front, then **New Tab** and **Gmail**, and **Allow** each prompt. Add Elgato Stream Deck in **Privacy & Security → Accessibility**.
13. Open Hammerspoon and add it in **Privacy & Security → Accessibility**. Press `Ctrl+Opt+Cmd+T` and `E` with Ghostty, Zed, and Finder in front, then `N`, and **Allow** each prompt.
14. Optional: set up [monitor input](#monitor-input) switching on the Mac and on Ubuntu.

**Accounts and keys**

15. Sign in to Tailscale with the account your Ubuntu machine and phone use.
16. Add your Google account to Calendar and Contacts.
17. In Chrome, sign in to the sites you want agents to use.
18. If you skipped the GitHub login, re-run `bash setup.sh git` from a terminal and accept it.
19. Run `just git-signing` and the `gh` commands it prints.

**Security and backups**

20. Optional: `just touch-id`.
21. Turn on FileVault.
22. Back up off the Mac, such as with Time Machine.
23. Restore a file from the backup once, to check it.

**Performance and privacy**

24. In **System Settings → Spotlight → Search Privacy…**, add `~/Dev`, `~/go`, and `~/Library/pnpm`, so Spotlight stops indexing builds and package stores. Press `Cmd+Shift+G` in the file picker to type a path.
25. In **System Settings → Spotlight**, turn off the clipboard history, or keep it for the shortest time offered. It keeps copied passwords.
26. Optional: if you don't use Apple Intelligence, turn it off. Search System Settings for **Apple Intelligence**.
27. In Chrome, turn on **Memory Saver** in `chrome://settings/performance`.

### Ubuntu

Once:

1. **BIOS/UEFI.** Set the power-loss setting to **Power On**. For Wake-on-LAN, turn it on and turn **ErP**/**EuP** off.
2. **Network.** Use Ethernet, or run the `nmcli` commands the `ubuntu` step prints so Wi-Fi connects at boot.
3. **Disk encryption.** Store the recovery key off the machine.
4. **Login shell.** `chsh -s /usr/bin/zsh`, if you skipped it.
5. **Tailscale.**
   - Run `sudo tailscale up`.
   - In the admin console, disable key expiry for the machine.
   - Limit the access policy, and remove `root` from `users` in its `ssh` rules.
   - Remove the `funnel` nodeAttr, unless you use it.
6. **SSH key.** On the Mac:
   1. `ssh-keygen -t ed25519`, if there's no `~/.ssh/id_ed25519`.
   2. `just ssh-host <alias> <machine-name>`, using the machine's name in Tailscale. Leave out `<machine-name>` if it matches the alias. With MagicDNS off, use the full `<machine-name>.<tailnet>.ts.net` name.
   3. `ssh-copy-id <alias>`.
   4. `ssh -O exit <alias>`.

   Then SSH in with the key and re-run `bash setup.sh ubuntu`, which turns off password logins and finishes the Tailscale setup. Before closing that session, check `ssh -S none <alias> true` from the Mac.
7. **GitHub.** If you skipped the login, re-run `bash setup.sh git` from a terminal and accept it.
8. **Commit signing.** Run `just git-signing` and the `gh` commands it prints.
9. **Logitech.** At the desktop, open Solaar and pair your devices.
10. **GNOME extensions.** Log out of the desktop and back in once, so GNOME loads the extensions the `stream-deck` and `vicinae` steps turned on.
11. **Monitor input (optional).** Set up [monitor input](#monitor-input) switching here and on the Mac.
12. **Desktop session after a reboot.** Solaar and Claude in Chrome need one. Turn on Remote Login in **Settings → System → Remote Desktop** and connect over Tailscale with Windows App, or turn on GDM automatic login (the keyring stays locked).
13. **Phone alerts.** Run `just alerts` and leave the topic empty to generate one. On Android, scan the first QR code it shows, which the ntfy app opens; on an iPhone, scan the second. Then run `just alerts test`. To use your own topic of 20 or more characters, paste it or its `https://` URL instead.
14. **Power cuts.** Plug in the UPS over USB and re-run `bash setup.sh ubuntu`. Then:
    1. Unplug the UPS from the wall and wait for the push, the shutdown, and the UPS cutting its output (`sudo upsmon -c fsd` shuts down at once). If the output stays on, find the UPS setting that cuts it on shutdown.
    2. Plug it back in, and check the machine starts and `just status` shows the UPS on mains.
    3. At the machine, `sudo rtcwake -m off -s 120` starts it 2 minutes later. If it doesn't, only the BIOS setting brings it back.
    4. Run `just alerts test` again.
15. **Backups.** Back up `~` and `/var/lib/docker/volumes` off the machine on a schedule, such as with Déjà Dup.
16. **Restore.** Restore a few files from the backup once, to check it.
17. **Livepatch (optional).** `sudo pro attach <token>`, then `sudo pro enable livepatch`.
18. **Display scale.** In **Settings → Displays**, set **Scale** to **167%**, between 150% and 200%.

When needed:

- Reboot when `just status` says one is pending.
- Install firmware updates it lists: `fwupdmgr refresh && fwupdmgr update`.
- If `fwupdmgr refresh` times out, run `curl -sSI --max-time 15 https://cdn.fwupd.org/downloads/firmware.xml.zst.jcat` and `curl -sSI --max-time 15 https://fwupd.org`. When only the first fails, your network blocks the firmware CDN. Refresh on another network, such as a phone hotspot, or through a Tailscale exit node.
- After a release upgrade, re-run `bash setup.sh` and `bash ai_tools/setup.sh`.

## Check it works

The AI tools have their own [checks](./ai_tools/README.md#check-it-works).

### macOS

- `just status` prints no **Needs attention** line.
- In a new Ghostty window, `command -v brew mise node` prints three paths.
- In a scratch repo, `git commit --allow-empty -m test && git log --show-signature -1` shows `Good "git" signature`, also after a reboot without a passphrase prompt.
- After `just touch-id`, `sudo -k && sudo -v` asks for Touch ID, in tmux too.
- With a file open in Zed, the Stream Deck **Terminal** key opens Ghostty at its folder.
- `Cmd+Space` opens Vicinae, and `Cmd+Space` again closes it.

### Ubuntu

Over SSH from the Mac:

- `sudo -v && just status` prints no **Needs attention** line.
- `command -v brew mise node` prints three paths, and a test commit is signed.
- After a reboot, `ssh <alias>` connects, `docker ps` works without `sudo`, `tmux ls` lists the old sessions, and the phone gets the boot notice.
- `iw dev <device> get power_save` prints `Power save: off` for the Wi-Fi device `nmcli device` lists, also after a reboot.
- `systemctl is-enabled cups-browsed` prints `masked`, and `cloud-init status` prints `status: disabled` after a reboot.
- `snap list firefox` and `dpkg -s firefox` both say Firefox isn't installed, and `xdg-settings get default-web-browser` prints `google-chrome.desktop`.
- `fwupdmgr refresh --force` finishes without a timeout. If it times out, see **When needed** in the [manual steps](#ubuntu-2).

At the desktop, with the Stream Deck switched to it:

- The keys show, and **Overview** opens the **System** page.
- With a file open in Zed, **Terminal** and `Ctrl+Alt+Super+T` open Ghostty at its folder.
- `Super+Space` opens Vicinae. Typing an app's name and pressing `Enter` opens the app, and `Super+Space` again closes Vicinae.
- Copy two bits of text, open **Clipboard History** in Vicinae, and pick the first. `Ctrl+V` in a text field then pastes it.
- Holding a key in a text field repeats it after about a quarter of a second.
- Files lists folders in list view and shows hidden files, such as `.config` in your home folder. Selecting a file and pressing `Space` previews it, and `Space` again closes the preview.
- The dock stays hidden until the pointer reaches the screen's left edge, also with no window open.
- After the **Display scale** manual step, **Settings → Displays** shows **Scale** at **167%**.

## Updating

`upgrade` runs [`scripts/upgrade.sh`](scripts/upgrade.sh) from the dotfiles checkout or worktree you're in, else the [recorded checkout](#where-the-repo-lives). `just upgrade` uses the checkout that holds the justfile. Either updates apt, Homebrew, App Store apps, vim and tmux plugins to their pins, Vicinae and its GNOME extension, mise tools, global npm packages, uv tools, Rust, and the AI tools (`upgrade-ai-tools`, see [ai_tools/README.md](./ai_tools/README.md#updating)). It lists failed stages and returns 1.

- Install global npm CLIs with `mise use -g npm:<package>`, since mise removes old Node versions with their `npm install -g` packages.
- Don't run `brew bundle cleanup`: the Brewfile lists no casks, so it uninstalls them all.
- To update configs, pull and re-run `bash setup.sh` and `bash ai_tools/setup.sh`.

## Maintenance

- `just copy-back [dry-run]` copies installed configs that differ back into the repo for review with `git diff`. It skips repo files with uncommitted changes.
- `just clean-caches` lists build and download caches with their sizes: Go's build cache, the pnpm store, npm's cache, Homebrew's downloads, Playwright's browsers, and PyTorch's downloads. Once you confirm, it clears them; `dry-run` stops after the list. pnpm keeps the packages your projects use. Each cache refills on next use.
- Add hand-installed packages to `homebrew/Brewfile`, or to `CASKS`, `MAS_APPS`, or `UBUNTU_CASKS` in `homebrew/install.sh`.
- `just bump-plugins` moves the vim and tmux plugin pins and vim-plug to their latest versions. Commit, then re-run `bash setup.sh vim tmux` on each machine.
- To change the Stream Deck's keys, edit `stream-deck/com.gpahal.dotfiles.sdPlugin/layout.json`, run `bash stream-deck/build-profile.sh`, and commit both. Then re-run `bash setup.sh stream-deck` on each machine. On the Mac, accept Stream Deck's prompt for each changed profile, pressing **Overview** for the **System** profile.
- To update the Ubuntu Stream Deck's packages, run `pnpm update` in `stream-deck/linux`, commit `pnpm-lock.yaml`, and re-run `bash setup.sh stream-deck`.
- The manual steps live in `manual-steps/steps.sh` and `ai_tools/manual-steps/steps.sh`, each with the check that tells it's done. After editing one, run `just manual-steps-doc`, which rewrites the READMEs' Manual steps lists.
- [AGENTS.md](./AGENTS.md) covers adding steps, `just check`, and `just test`.

## License

[MIT](LICENSE).
