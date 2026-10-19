# dotfiles

Configuration and setup scripts for my Mac, and for the Ubuntu desktop I use from it over SSH. See [Ubuntu](#ubuntu-1) for what differs there.

The Mac is Apple Silicon on macOS 27. The Ubuntu desktop runs Ubuntu 26.04 LTS on x86_64. On an Intel Mac, `setup.sh` and `ai_tools/setup.sh` stop before any step runs. On ARM Ubuntu, they warn and carry on. A package with no ARM build then fails its step, except Chrome, which the chrome step skips.

![zsh prompt](./resources/prompt.png)

## Table of contents

- [First run](#first-run)
- [How setup works](#how-setup-works)
- [Ubuntu](#ubuntu-1)
- [Code layout](#code-layout)
- [What's included](#whats-included)
- [Manual steps](#manual-steps)
- [Check it works](#check-it-works)
- [Updating](#updating)
- [Maintenance](#maintenance)

## First run

Set up the Mac first, then the Ubuntu machine: Ubuntu's **SSH key** manual step runs commands on the Mac.

### macOS

1. Run `git clone https://github.com/gpahal/dotfiles ~/Dev/setup/dotfiles`. The first `git` command asks to install the Command Line Tools. Install them, then run the clone again.
2. Sign in to the App Store, so the `homebrew` step can install the free [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) and Windows App. [Dato](https://apps.apple.com/app/dato/id1470584107) is paid and optional. Buy it there once if you want it. Without it, the `homebrew` step notes it isn't installed, and `--status` lists it as `info`, which doesn't need attention.
3. In `~/Dev/setup/dotfiles`, run `bash setup.sh`.
4. Give Ghostty Full Disk Access, then quit and reopen it. The first of the macOS [manual steps](#macos-1) says how.
5. Do the rest of the macOS [manual steps](#macos-1), commit signing included.
6. From Ghostty, do the AI tools' [First run](./ai_tools/README.md#first-run).
7. Run the [checks](#check-it-works).

### Ubuntu

1. In the Ubuntu installer, choose TPM-backed disk encryption without a PIN ([Encrypt your disk with TPM](https://ubuntu.com/desktop/docs/en/latest/how-to/encrypt-your-disk-with-tpm/)), or none. A LUKS passphrase makes every boot wait at the console, so the machine can't come back by itself after a power cut. The `ubuntu` step warns about one, which binding the disk to the TPM with `systemd-cryptenroll`, or reinstalling, fixes.
2. At the machine, run `sudo apt update && sudo apt install git`, then clone the repo as on macOS. Ubuntu Desktop has no `git` and no SSH server until setup runs.
3. Do the **BIOS/UEFI** [manual step](#ubuntu-2), and use Ethernet until setup prints the Wi-Fi commands (**Network** manual step).
4. From a terminal at the machine, run `bash setup.sh`. Then, at the machine or over SSH, run `bash ai_tools/setup.sh`. Steps that need `sudo` ask for it.
5. Do the rest of the Ubuntu [manual steps](#ubuntu-2), which include the AI tools' ones.
6. Reboot once, so the T3 Code service and tmux get the `docker` group.
7. Run the [checks](#check-it-works) over SSH from the Mac.

## How setup works

```sh
cd ~/Dev/setup/dotfiles
bash setup.sh
```

`setup.sh` runs one script per step, in this order. Each is `<step>/install.sh` and also runs on its own:

| Step | What it does |
| :- | :- |
| `homebrew` | Installs [Homebrew](https://brew.sh/) and the packages in [What's included](#whats-included). On Ubuntu, first the apt packages Homebrew needs |
| `runtimes` | Installs Node LTS and Go with mise, and Rust with rustup |
| `git` | Copies the git config, the global ignore file, and `git wt`, and offers to log in to GitHub with `gh` |
| `lazygit` | Copies the lazygit config |
| `ssh` | Makes `~/.ssh` private. On macOS, keeps your keys in the keychain and loads them at login |
| `zsh` | Copies the zsh and starship config, adds its lines to `~/.zshrc` and the other startup files, and offers to make zsh the login shell |
| `vim` | Copies the vim config and installs vim-plug |
| `tmux` | Copies the tmux config and `tmux-sessionizer`, and installs tpm and the plugins at their pinned commits. On Ubuntu, sets tmux to start at boot |
| `ghostty` | Copies the Ghostty config and reloads it. On Ubuntu, installs the Ghostty snap |
| `zed` | Copies the Zed settings and keymap, replacing ones Zed edited |
| `stream-deck` | Installs the [Stream Deck](#stream-deck) plugin and restarts Stream Deck to load it. macOS only |
| `hammerspoon` | Copies the [Hammerspoon](#hammerspoon) config, whose hotkeys open Claude, Chrome, a new Chrome tab, Ghostty, T3 Code, and Zed. macOS only |
| `editorconfig` | Copies `~/.editorconfig` |
| `macos` | Sets macOS defaults, frees the shortcuts Raycast and Hammerspoon take, and, when needed, sets the hostname. macOS only |
| `ubuntu` | Sets Ubuntu up for [running around the clock](#running-around-the-clock). Ubuntu only |
| `docker` | Installs Docker Engine, started at boot. Ubuntu only; OrbStack provides Docker on macOS |
| `chrome` | Installs Google Chrome from Google's apt repo. Ubuntu only; the `homebrew` step installs it on macOS |
| `logitech` | Installs Solaar, since Logi Options+ has no Linux version. Ubuntu only |
| `manual-steps` | Prints this OS's [manual steps](#manual-steps). Its script is `manual-steps.sh` |

Name steps to run only those, such as `bash setup.sh git zsh`. `--help` lists them. Re-running is safe: a step that's already applied says so and changes nothing. A failed step doesn't stop the rest, and the run ends by listing the failed steps and the command that re-runs them.

**Status.** `bash setup.sh --status [step...]` reports what's set up and changes nothing. It checks root-only settings only while sudo credentials are cached (`sudo -v`). Each item is `ok`, `missing` (run the step, or the manual step it names), `skipped` (doesn't apply here), `unverified` (only partly checked), `unknown` (can't be checked), or `info`. The run ends by listing the steps that need attention. Status also checks free disk space, and on Ubuntu SMART health, firmware updates, Docker's disk usage, and container ports published on every address. `--quick` skips the slowest checks, Docker's disk usage among them.

**Files you also edit.** Setup copies configs over the installed ones whenever they differ, with no backup, so copy changes you want to keep back to the repo first ([Maintenance](#maintenance)). Settings merged into files other tools also edit ask whether to back up the file first, and `--backup` or `--no-backup` answers every backup question. Shell startup files, `~/.ssh/config`, and `~/.gitconfig` only get setup's own lines added.

**Settings that are yours.** mise's global versions, the AI tools' models and status lines, and a few others are set only when unset. A run with a terminal asks before replacing your own, and a run without one keeps it.

**Downloads.** The installers for Homebrew, rustup, Claude Code, and T3 Code, Chrome's first `.deb`, and the Docker and Tailscale apt keys come over HTTPS only, with TLS 1.2 or later and no redirect to plain HTTP. Setup runs the installers and the `.deb` without a pinned checksum, as each vendor's instructions do, so the vendor's HTTPS server decides what runs. An apt key must match the fingerprint its step pins. The skills CLI comes from npm through `npx`, pinned by version but not by checksum, and the Ghostty snap from the Snap Store.

**XDG.** git, tmux, and lazygit configs follow `$XDG_CONFIG_HOME` when it's set, and so do Ghostty and Zed on Ubuntu.

The AI tools have their own script, `bash ai_tools/setup.sh`, described in [ai_tools/README.md](./ai_tools/README.md). It needs Node from the `runtimes` step.

After Homebrew is installed, `just` in the repo lists the [justfile](./justfile)'s recipes, which wrap the setup scripts and the ones this README names. `just status` runs both setup scripts with `--status`.

## Ubuntu

The same `bash setup.sh` sets up Ubuntu, the only Linux supported, with the steps the [table](#how-setup-works) doesn't mark macOS only. Run setup as your own user, not root. On Ubuntu Server, leave out `ghostty`, `zed`, `logitech`, and `chrome` by naming the other steps, and install `upower`, which the UPS detection needs. The `homebrew` step still installs the Zed cask.

What differs from macOS:

- **System packages.** Before Homebrew, the `homebrew` step installs these apt packages, after asking: `build-essential procps curl file git zsh lsof bsdextrautils unzip jq gpg locales fontconfig`.
- **Packages.** Homebrew installs the Brewfile's formulae on Ubuntu too, except the Mac-only `macmon`, `terminal-notifier`, `pam-reattach`, and `mas`. zsh comes from apt. Of the casks, Ubuntu gets `zed` and `font-monaspace` here and `codex` from `ai_tools/setup.sh`. Ghostty comes from its snap, Chrome from Google's apt repo, and [Solaar](https://pwr-solaar.github.io/Solaar/) takes the place of Logi Options+.
- **PATH.** Homebrew comes first, as on macOS, so brew's `python3`, `curl`, and `pkg-config` shadow the system's. Build against system libraries with `PATH=/usr/bin:/bin`.
- **Clipboard.** Copying in tmux and yanking in vim go through OSC 52, which Ghostty puts on the Mac's clipboard.
- **GitHub.** `gh` keeps its token in `~/.config/gh/hosts.yml`, since the desktop keyring is locked over SSH, and git reaches GitHub over HTTPS. To push a change under `.github/workflows`, run `gh auth refresh -h github.com -s workflow --insecure-storage` once.

### Running around the clock

The Ubuntu machine stays on so the Mac and the phone can reach its agents at any time. The `ubuntu` step does most of this, and the `docker` step the Docker part:

- **No sleep.** Suspend is off.
- **Power cuts.** With a UPS on USB, the machine shuts down on a low battery and starts again when mains returns. If the UPS keeps its power on, a fallback starts the machine 15 minutes later, but only on a motherboard that wakes from an RTC alarm. The **Power cuts** manual step tests both.
- **Kernel panics.** The machine reboots 10 seconds after one.
- **Disk health.** smartd watches the drives and pushes its warnings to your phone. It may not repeat a warning, so act on the first one.
- **Health alerts.** A daily check pushes what needs attention to your phone when it changes, again each week while it lasts, and once more when it's all clear. It runs without root, so it skips the checks that need root: ufw's rules, sshd's effective settings, SMART health, NUT's and Docker's config files, and unattended-upgrades' settings when only root can read them. A push names them. To check them, run `sudo -v`, then `just status`. Each boot pushes a notice. Re-run setup after moving the checkout, which they run from.
- **Updates.** Security, Chrome, and Docker updates install daily, without a reboot. `just status` lists a pending reboot and firmware updates.
- **User services.** Your systemd user services, such as the T3 Code server and tmux, start at boot without a login.
- **SSH.** sshd starts at boot, lets only you log in, and turns off password logins once you've used a key.
- **Tailscale.** Once you've logged in, Tailscale updates itself, and you can run `tailscale serve` without `sudo`. So can anything else running as you. It can also run `tailscale funnel`, which opens a port to the internet if the tailnet's policy grants funnel, and `tailscale set --ssh`, which turns on Tailscale SSH. The **Tailscale** manual step covers the policy. Use OpenSSH over the tailnet, not Tailscale SSH, which drops every session when tailscaled restarts.
- **Firewall.** ufw lets SSH in only from `10.0.0.0/8`, `192.168.0.0/16`, and IPv6's unique local and link-local ranges, and lets the tailnet (`tailscale0`) reach every port, so Tailscale's access rules decide what tailnet devices can reach. It leaves out `172.16.0.0/12`, which the `docker` step limits Docker's networks to, and denies SSH on Docker's bridges, `docker0` and `br-*`, so containers on them can't reach sshd, even on a network with IPv6 or a subnet you chose. A network whose bridge you name (`com.docker.network.bridge.name`), or Swarm's `docker_gwbridge`, needs its own rule: `sudo ufw prepend deny in on <bridge> to any port 22 proto tcp`. On a LAN in that range, SSH in over Tailscale. If you share the machine, or add devices you don't own to the tailnet, limit them with an ACL. `just status` flags any other rule that lets SSH in from outside those ranges, such as the one `ufw allow ssh` adds. Before Tailscale is up, SSH from the Mac to the machine's IPv4 address, or a name that resolves to it, since ufw lets in no global IPv6 address.
- **Docker.** Docker starts at boot. You and T3 Code's agents use it without `sudo` through the `docker` group, which is root-equivalent, so the step asks about it on its own, once, when it installs Docker. Without it, use `sudo docker`, or join later with the command `just status` shows. Published ports bypass ufw, so they listen on `127.0.0.1` unless you give an address, as in `-p 0.0.0.0:8080:80`, and `just status` flags a running container's port that listens on every address. For containers to reach a port on the host, run `sudo ufw allow in on docker0`. Docker networks get `/24` subnets only from `172.17.0.0/16` to `172.31.0.0/16`, outside the SSH ranges.
- **Wake-on-LAN.** Wired connections wake on a magic packet, with the BIOS setting on.

Over SSH from the Mac, both machines' tmux use the `Ctrl+a` prefix, so press it twice to reach the inner one.

## Code layout

Projects live at `~/Dev/<group>/<project>`, grouped by language or purpose: `~/Dev/go/envl`, `~/Dev/js/jslib`. This repo is at `~/Dev/setup/dotfiles`.

Worktrees go under `~/.worktrees/<group>/<project>/<name>`, beside the projects rather than inside them. A repo outside `~/Dev/<group>/<project>` uses `~/.worktrees/_/<project>-<hash>/<name>`. Each tool keeps its own:

| Tool | Worktrees |
| :- | :- |
| [`git wt`](#git), the implement skill, and Claude Code's `--worktree`, subagents, and background sessions | `~/.worktrees/<group>/<project>/<name>` |
| T3 Code | `~/.t3/worktrees/<repo>/<worktree>` |
| The Codex app | `~/.codex/worktrees` |

`ts` in zsh and `prefix+f` in tmux pick a project from `~/Dev/*/*` and open a tmux session for it.

## What's included

### Fonts

- [Monaspace](https://monaspace.githubnext.com/), from the `font-monaspace` cask on both OSes

### git

- [Git](https://git-scm.com/) config with the [delta](https://github.com/dandavison/delta) pager, `zdiff3` and `histogram` diffs, `rerere`, auto-squash and `updateRefs` on rebase, rebase on pull, and object checks on fetch
- [difftastic](https://github.com/Wilfred/difftastic) as the diff tool: `git dft`, `git dd`, and `git dlog`
- `git cob` and `git cobr` pick a local or remote branch with fzf and switch to it. `git co` runs `switch`, `git unstage` runs `restore --staged`, and `git del` deletes a merged branch
- `git wt` manages a repo's worktrees under `~/.worktrees` (see [Code layout](#code-layout)). `git wt add <name> [<base>]` creates a branch and its worktree and prints the path, so `cd "$(git wt add foo)"` works. `git wt base` prints the ref `git wt add` branches from when you give no base. `git wt rm --delete-merged-branch <name>` also deletes the branch when another branch has all its commits. `git wt path`, `list`, and `prune` do the rest; `git wt` alone prints its usage
- Copied to `~/.config/git/config`, with a global ignore file at `~/.config/git/ignore`
- Put settings for one machine in `~/.gitconfig.local`. To clone a repo with malformed objects, run `git -c transfer.fsckObjects=false clone <url>`

#### Commit signing

`just git-signing`, a [manual step](#manual-steps), signs commits and tags with an SSH key and prints the `gh` commands that add it to GitHub. `git tag --no-sign <name>` makes a lightweight tag. Agents can't type a passphrase, so macOS signs with `~/.ssh/id_ed25519` from the keychain, and Ubuntu with `~/.ssh/id_ed25519_signing`, a separate key without a passphrase that GitHub gets only as a signing key.

### lazygit

- [lazygit](https://github.com/jesseduffield/lazygit) shows diffs through delta

### SSH

- On macOS, `~/.ssh/config` gets a `Host *` block that keeps key passphrases in the keychain, and a LaunchAgent loads the keys at each login, so commits sign after a reboot. The block starts with `IgnoreUnknown UseKeychain`, so an ssh other than Apple's, such as Homebrew's, still reads the file
- `just ssh-host <alias> [hostname]` adds a block for a host you SSH to, such as the Ubuntu machine by its tailnet name, with keepalives and one shared connection per host, kept open a minute after the last session closes. `ssh -O exit <alias>` closes it

### vim

- [Vim](https://www.vim.org/) config with [vim-plug](https://github.com/junegunn/vim-plug) and plugins:
  - [vim-sensible](https://github.com/tpope/vim-sensible) defaults
  - [NERDTree](https://github.com/preservim/nerdtree) with [nerdtree-git-plugin](https://github.com/Xuyuanp/nerdtree-git-plugin), [fzf.vim](https://github.com/junegunn/fzf.vim), [vim-gitgutter](https://github.com/airblade/vim-gitgutter), [vim-fugitive](https://github.com/tpope/vim-fugitive)
  - [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator): Ctrl+hjkl between vim and tmux
  - [vim-commentary](https://github.com/tpope/vim-commentary), [vim-surround](https://github.com/tpope/vim-surround), [vim-repeat](https://github.com/tpope/vim-repeat), [auto-pairs](https://github.com/jiangmiao/auto-pairs), [vim-matchup](https://github.com/andymass/vim-matchup)
  - [vim-go](https://github.com/fatih/vim-go), [rust.vim](https://github.com/rust-lang/rust.vim)
  - [vim-airline](https://github.com/vim-airline/vim-airline) with [vim-airline-themes](https://github.com/vim-airline/vim-airline-themes)
- Relative line numbers, persistent undo, smart case search, a space leader key, and the mouse in tmux too
- `Space e` toggles NERDTree. `Space f` finds files, `Space /` searches contents with ripgrep, and `Space b` lists buffers
- Copied to `~/.vimrc`, with the vim-plug release the repo vendors. vim installs missing plugins when it starts, at the commits `vim/vimrc` pins

### zsh

- zsh itself is the system's, so the login shell works if Homebrew breaks
- [starship](https://starship.rs/) prompt
- Plugins: [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions), [fzf](https://github.com/junegunn/fzf) (`Ctrl+T` for files, `Alt+C` for directories), [zoxide](https://github.com/ajeetdsouza/zoxide), [atuin](https://github.com/atuinsh/atuin) (`Ctrl+R` and the Up arrow search history), [mise](https://mise.jdx.dev/), and [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting)
- `Ctrl+X Ctrl+E` edits the command in `$EDITOR`, and `Ctrl+Z` on an empty line runs `fg`
- An unknown command gets Homebrew's suggestion of the formula that provides it, then on Ubuntu apt's
- Aliases and functions include `g` (`git`, or `git status -sb`), `c` (`bat -pp`), `t` (`eza --tree`), `port <n>` and `killport <n>`, `o [path]`, `scratch` (a shell in a temp dir), `reload`, and `ts` (`tmux-sessionizer`)
- `rm` deletes immediately. On macOS, use `trash` for a delete you can undo
- `~/.zshrc.local`, if it exists, is sourced near the end. Put secrets and settings for one machine there
- zsh config goes in `~/.zsh/`, with `~/.zshrc` sourcing `main.zsh`. `~/.zprofile`, `main.zsh`, and on Ubuntu `~/.zshenv` source `path.zsh`, which sets PATH. On Ubuntu, `~/.profile` sources `profile.sh`, which sets PATH for `sh` login shells and the desktop session. Starship reads `~/.config/starship.toml`

### Ghostty

- [Ghostty](https://ghostty.org/) with the GitHub Dark theme and Monaspace, a native tab bar, copy-on-select, and SSH integration, which installs Ghostty's terminfo on remote hosts
- Left Option acts as Alt. `Cmd+Shift+S` opens the visible screen's text in the default text app (TextEdit), `Cmd+Ctrl+arrows` resize a split, `Cmd+Shift+=` makes the splits equal, and Ghostty's own `Cmd+Shift+Enter` zooms one
- `` Cmd+` `` shows or hides the quick terminal from any app. It needs Accessibility permission, and it may not work on GNOME. It takes over macOS's `` Cmd+` ``, which switches between an app's windows. That's intended
- A notification when a command that ran over 10 seconds finishes while Ghostty is unfocused
- Copied to `~/.config/ghostty/config.ghostty`

#### Ghostty notifications

Claude Code, Codex, and long builds send notifications through Ghostty, inside tmux too. To get them:

1. Run `~/Dev/setup/dotfiles/scripts/test-notification.sh` in Ghostty and click **Allow**. Then, in **System Settings → Notifications → Ghostty**, turn on **Allow notifications** and set the alert style to **Persistent**.
2. An active Focus mode silences them. Add Ghostty to the mode's **Allowed Apps** to keep them.

### Zed

- [Zed](https://zed.dev/), from the `zed` cask on both OSes. Its own updater is off, so `upgrade` updates it
- Settings and keymap copied to `~/.config/zed/`. AI features and telemetry, crash reports included, are off
- In Zed's terminal, `Shift+Enter` adds a newline in the Claude Code and Codex CLIs
- The window title ends with the open file's full path, which the [Stream Deck](#stream-deck) keys and [Hammerspoon](#hammerspoon)'s `Ctrl+Opt+Cmd+T` and `Ctrl+Opt+Cmd+E` read

### Stream Deck

macOS only. The `stream-deck` step installs a plugin whose **Dotfiles** category has three keys that act on the app in front:

| Key | From Ghostty | From Zed | From Finder | From T3 Code |
| :- | :- | :- | :- | :- |
| **Editor** | Zed at the tab's folder | Shows the open file | Zed at the selection, or the window's folder | Zed at the thread's folder |
| **Terminal** | A new tab at the tab's folder | Ghostty at the file's folder | Ghostty at the selected folder, the selected file's folder, or the window's folder | Ghostty at the thread's folder |
| **Files** | Finder at the tab's folder | Reveals the file in Finder | Opens the selected folder, reveals the selected file, or opens the window's folder | Finder at the thread's folder |

A thread's folder is its worktree, or else its project's folder. With no folder to use, as when another app is in front or the folder is on another machine, a key opens Finder or Ghostty at your home folder, or an empty Zed window. A key shows a warning when a permission is missing or nothing opened. **Chrome**, **New Tab**, **T3 Code**, and **Claude** do what the [Hammerspoon](#hammerspoon) hotkeys do, and **Gmail** brings Chrome's Gmail tab to the front, or opens Gmail in a new tab. [`stream-deck/icons`](stream-deck/icons/README.md) lists where the app icons came from.

**Overview** shows CPU and memory use. On the 15-key Stream Deck, a press opens the **System** page. The plugin has no page for other models, so there a press shows a warning on the key. The page:

| | | | | |
| :- | :- | :- | :- | :- |
| Back | CPU | Memory | Swap | Activity Monitor |
| Top Process | GPU | Temperature | Power | Disk |
| Network | | | | |

A stat key updates every 2 seconds while it's on screen, turns yellow or red as the stat nears trouble, and opens Activity Monitor when pressed. Memory's color is macOS's memory pressure. GPU, Temperature, and Power need [macmon](#cli-tools-installed-via-brew). **Back** returns to the profile you came from. The stat keys are also in the category, for any page.

### Hammerspoon

macOS only. The `hammerspoon` step copies `~/.hammerspoon/init.lua`, which sets global hotkeys on `Ctrl+Opt+Cmd`, since [Rectangle](#apps)'s recommended shortcuts take `Ctrl+Opt+C`, `E`, and `T`. Each opens its app, or brings it to the front:

- `Ctrl+Opt+Cmd+Space` opens Claude, whose own `Option+Space` opens quick entry. `Ctrl+Opt+Cmd+B` opens Google Chrome, and `Ctrl+Opt+Cmd+C` T3 Code.
- `Ctrl+Opt+Cmd+T` opens Ghostty, and `Ctrl+Opt+Cmd+E` Zed, at the folder in front, as the Stream Deck's **Terminal** and **Editor** keys do.
- `Ctrl+Opt+Cmd+N` opens a new Chrome tab. When the clipboard holds text, it pastes it into the address bar and selects it, so Enter opens it and typing or Delete replaces it. It waits for you to release the hotkey's keys. If they're still held, or Chrome isn't in front, after 10 seconds, it shows a notification instead. A second press while the tab is on its way does nothing.

### tmux

- [tmux](https://github.com/tmux/tmux) with the `Ctrl+a` prefix, mouse support, and vi copy mode
- `prefix+|` and `prefix+-` split in the current directory. `prefix+hjkl` moves between panes and `prefix+HJKL` resizes them
- `prefix+Ctrl+h` and `prefix+Ctrl+l` go to the previous and next window
- `prefix+v` enters copy mode, where `v` selects and `y` copies
- vim-tmux-navigator takes `Ctrl+hjkl` in every pane, so use `prefix+Ctrl+k` to clear the screen
- `prefix+S` creates a session and `prefix+X` kills one. `prefix+f` runs `tmux-sessionizer`, which opens or switches to a session for a project
- [tpm](https://github.com/tmux-plugins/tpm) with [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator), [tmux-yank](https://github.com/tmux-plugins/tmux-yank), [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum), which restores sessions and on Ubuntu starts tmux at boot, and [tmux-open](https://github.com/tmux-plugins/tmux-open)
- Copied to `~/.config/tmux/tmux.conf`, and `tmux-sessionizer` to `~/.local/bin`

### EditorConfig

- `~/.editorconfig` applies to every project without its own `root = true`: UTF-8, LF, a final newline, no trailing whitespace outside Markdown and patches, 4-space indents, 2 for JSON, YAML, JavaScript, and TypeScript, and tabs for Go and Makefiles

### Runtimes

The `runtimes` step installs these:

- [Node.js](https://nodejs.org/) LTS and [Go](https://go.dev/), with mise, as the global versions
- [Rust](https://www.rust-lang.org/) with [rustup](https://rustup.rs/), with the stable toolchain

### CLI tools (installed via brew)

**Search and navigation:**
- [fzf](https://github.com/junegunn/fzf): fuzzy finder
- [ripgrep](https://github.com/BurntSushi/ripgrep): regex search
- [fd](https://github.com/sharkdp/fd): a simpler find
- [broot](https://github.com/Canop/broot): interactive directory navigator
- [zoxide](https://github.com/ajeetdsouza/zoxide): a cd that learns your habits

**Git tools:**
- [gh](https://cli.github.com/): GitHub from the terminal
- [delta](https://github.com/dandavison/delta): syntax-highlighting pager for git
- [lazygit](https://github.com/jesseduffield/lazygit): terminal UI for git
- [difftastic](https://github.com/Wilfred/difftastic): structural diff
- [git-absorb](https://github.com/tummychow/git-absorb): fixup commits for staged changes, aimed at the commits they belong to

**File viewing:**
- [bat](https://github.com/sharkdp/bat): cat with syntax highlighting
- [bat-extras](https://github.com/eth-p/bat-extras): bat-powered scripts
- [glow](https://github.com/charmbracelet/glow): Markdown in the terminal

**System monitoring:**
- [macmon](https://github.com/vladkens/macmon) (macOS only): power, temperature, and RAM monitor

**Disk and process tools:**
- [dust](https://github.com/bootandy/dust): du alternative
- [duf](https://github.com/muesli/duf): df alternative
- [procs](https://github.com/dalance/procs): ps alternative

**Modern replacements:**
- [eza](https://github.com/eza-community/eza): ls alternative
- [sd](https://github.com/chmln/sd): sed alternative
- [doggo](https://github.com/mr-karan/doggo): DNS client

**Data processing:**
- [jq](https://github.com/jqlang/jq): JSON processor
- [yq](https://github.com/mikefarah/yq): YAML, TOML, and XML processor

**Networking:**
- [httpie](https://github.com/httpie/httpie): HTTP client

**Development utilities:**
- [ShellCheck](https://www.shellcheck.net/): shell script linter
- [tokei](https://github.com/XAMPPRocky/tokei): code statistics
- [hyperfine](https://github.com/sharkdp/hyperfine): CLI benchmarking
- [watchexec](https://github.com/watchexec/watchexec): runs commands on file changes
- [grex](https://github.com/pemistahl/grex): regexes from examples
- [just](https://github.com/casey/just): command runner
- [atuin](https://github.com/atuinsh/atuin): shell history with fuzzy search
- [tlrc](https://github.com/tldr-pages/tlrc): tldr client
- [terminal-notifier](https://github.com/julienXX/terminal-notifier) (macOS only): macOS notifications from scripts
- [pam-reattach](https://github.com/fabianishere/pam_reattach) (macOS only): the PAM module [Touch ID for sudo](#touch-id-for-sudo) needs inside tmux
- [lazydocker](https://github.com/jesseduffield/lazydocker): terminal UI for Docker

**Encryption:**
- [age](https://github.com/FiloSottile/age): file encryption

**Version management:**
- [mise](https://github.com/jdx/mise): version manager for dev tools
- [uv](https://docs.astral.sh/uv/): Python packages, environments, and tools
- [pnpm](https://pnpm.io/) and [Bun](https://bun.sh/): JavaScript packages

**Mac App Store (macOS only):**
- [mas](https://github.com/mas-cli/mas): installs the App Store apps below

### Apps

macOS only. Installed with brew casks:

- [Google Chrome](https://www.google.com/chrome/): browser, which the AI tools also control. The `chrome` step installs it on Ubuntu
- [OrbStack](https://orbstack.dev/): Docker containers and Linux machines
- [Tailscale](https://tailscale.com/): private network to reach the Ubuntu machine from anywhere
- [Raycast](https://www.raycast.com/): launcher
- [Rectangle](https://rectangleapp.com/): window management
- [Stats](https://github.com/exelban/stats): menu bar memory pressure, CPU, GPU, network, and sensors
- [AppCleaner](https://freemacsoft.net/appcleaner/): app uninstaller
- [The Unarchiver](https://theunarchiver.com/): opens any archive format
- [Logi Options+](https://www.logitech.com/software/logi-options-plus.html): Logitech device settings. The `logitech` step installs Solaar on Ubuntu instead
- [Elgato Stream Deck](https://www.elgato.com/s/downloads): Stream Deck keys, with the [Stream Deck](#stream-deck) plugin
- [Hammerspoon](https://www.hammerspoon.org/): the [hotkeys](#hammerspoon) that open Claude, Chrome, Ghostty, T3 Code, and Zed

Installed from the Mac App Store with mas, once you're signed in to the App Store (see [First run](#macos)):

- [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704): keeps the Mac awake
- [Dato](https://apps.apple.com/app/dato/id1470584107): menu bar calendar. It's paid and optional, and installs only once you buy it
- [Windows App](https://apps.apple.com/app/windows-app/id1295203466): Microsoft's RDP client, to reach the Ubuntu desktop through GNOME's Remote Login

### macOS defaults

The `macos` step sets these:

- **Finder:** hidden files, extensions, path and status bars, the full path in the window title, list view, folders first, search the current folder, no warning when changing an extension
- **Keyboard and typing:** no Spotlight on `Cmd+Space`, so Raycast can take it, fast key repeat, no press-and-hold, no autocorrect, auto-capitalization, smart quotes or dashes, or period on double-space
- **Dock:** auto-hide with no delay, minimize into the app's icon, no recent apps. Spaces keep their order
- **Screenshots:** PNG in `~/Screenshots`, without window shadows
- **Hostname:** when it's unset or invalid, the name in System Settings → General → Sharing, so Ghostty's shell integration can report the folder. It asks first, since it needs `sudo`
- **Misc:** no `.DS_Store` on network or USB volumes, expanded save and print dialogs, new documents saved to disk rather than iCloud, plain-text TextEdit, all processes in Activity Monitor

### Touch ID for sudo

`just touch-id` makes `sudo` take Touch ID, inside tmux too, by rewriting `/etc/pam.d/sudo_local`. It copies pam-reattach's module into `/usr/local/lib/pam`, which only root can write, so a process running as you can't replace what sudo loads. Re-run it after `brew upgrade` updates pam-reattach; `--status` says when. Uninstalling pam-reattach doesn't break sudo, which loads the copy.

## Manual steps

Scripts can't do these. `bash setup.sh manual-steps` prints the list for its OS from this section, so edit the steps here. The AI tools' steps are in [ai_tools/README.md](./ai_tools/README.md#manual-steps).

### macOS

**Permissions**

1. Give Ghostty Full Disk Access in **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it. From Ghostty, run `cd ~/Dev/setup/dotfiles && bash setup.sh macos` again, which makes TextEdit default to plain text now that it can. Do the rest of the setup from Ghostty.
2. Turn on [Ghostty notifications](#ghostty-notifications).
3. Add Ghostty in **System Settings → Privacy & Security → Accessibility**, so the `` Cmd+` `` quick terminal works.

**Apps**

4. Set Google Chrome as the default browser.
5. Open [Logi Options+](https://www.logitech.com/software/logi-options-plus.html), grant the permissions it asks for, and pair your devices.
6. Open OrbStack once and finish its setup, so `docker` works.
7. Open [Raycast](https://www.raycast.com/), grant permissions, and [set its hotkey](https://manual.raycast.com/settings) to `Cmd+Space`, which the `macos` step frees from Spotlight.
8. Open [Rectangle](https://rectangleapp.com/), grant accessibility permissions, and set your shortcuts.
9. Turn on Launch at login in Rectangle, Raycast, Stats, Amphetamine, Tailscale, and Dato if you bought it.
10. Open Stats and turn on the modules you want (optional).
11. Open [AppCleaner](https://freemacsoft.net/appcleaner/) and turn on SmartDelete (optional).
12. Install [Supercharge](https://sindresorhus.gumroad.com/l/supercharge) (optional).
13. Set up the [Stream Deck](#stream-deck) keys. In the Stream Deck app, drag **Overview**, **Editor**, **Terminal**, **Files**, **Chrome**, **New Tab**, **Gmail**, **T3 Code**, and **Claude** from the **Dotfiles** category onto keys. Press **Overview** and accept the prompt to install the **System** page. Press **Editor**, **Terminal**, and **Files** once each with Ghostty, Zed, and Finder in front, then press **New Tab** and **Gmail**, and click **Allow** on each prompt. Then turn on Elgato Stream Deck in **System Settings → Privacy & Security → Accessibility**, so the keys can read Zed's window title and T3 Code's thread, and paste into the new tab.
14. Open [Hammerspoon](#hammerspoon) and turn it on in **System Settings → Privacy & Security → Accessibility**, so `Ctrl+Opt+Cmd+N` can paste into the new tab and `Ctrl+Opt+Cmd+T` and `Ctrl+Opt+Cmd+E` can read Zed's window title and T3 Code's thread. Press `Ctrl+Opt+Cmd+T` and `Ctrl+Opt+Cmd+E` once each with Ghostty, Zed, and Finder in front, then press `Ctrl+Opt+Cmd+N`, and click **Allow** on each prompt. The config sets Hammerspoon to open at login.

**Shell**

15. Run `atuin import auto` once to bring your zsh history into Atuin.
16. Run `:GoInstallBinaries` in vim once for vim-go's tools.

**Accounts and keys**

17. Sign in to the Tailscale app with the account the Ubuntu machine and your phone use, and approve the VPN configuration it asks for.
18. Add your Google account to Calendar and Contacts.
19. In Google Chrome, sign in to the sites you want the agents to use.
20. If you skipped the GitHub login during setup, run `gh auth login`, then `gh auth setup-git`.
21. Run `just git-signing` and the `gh` commands it prints. [Commit signing](#commit-signing) has more.

**Security and backups**

22. Turn on [Touch ID for sudo](#touch-id-for-sudo) with `just touch-id` (optional).
23. Turn on FileVault in **System Settings → Privacy & Security → FileVault**, and the firewall in **System Settings → Network → Firewall**. `bash setup.sh --status macos` reports both.
24. Back up to a destination off the Mac, such as Time Machine to a network disk, and restore a file once to check it.

### Ubuntu

Once, before or right after setup:

1. **BIOS/UEFI.** Set the power-loss setting (**Restore on AC Power Loss**, **After Power Failure**, or similar) to **Power On**. For Wake-on-LAN, turn on its setting and turn **ErP**/**EuP** off. Wake-on-LAN works only from the same LAN.
2. **Network.** Use Ethernet, or make Wi-Fi connect at boot with the `nmcli` commands the `ubuntu` step prints. Without them, Wi-Fi whose password is in your login keyring connects only after you log in.
3. **Disk encryption.** Store the installer's recovery key off the machine. Step 1 of [First run](#ubuntu) covers the choice in the installer.
4. **Login shell.** Run `chsh -s /usr/bin/zsh`, if you skipped it during setup.
5. **Shell history and vim-go.** Run `atuin import auto` once, and `:GoInstallBinaries` in vim once.
6. **Tailscale.** Run `sudo tailscale up`. In the admin console, **Disable key expiry** for the machine, and review the access policy so only the devices you need reach it. Anything running as you can turn on Tailscale SSH with `tailscale set --ssh`, which skips sshd's settings, so remove `root` from `users` in the policy's `ssh` rules (the default policy lets Tailscale SSH log in as root).
7. **SSH key.** On the Mac, run these, where `<alias>` is the name you pick for the machine:
   1. `ssh-keygen -t ed25519`, if there's no `~/.ssh/id_ed25519`.
   2. `just ssh-host <alias> <tailnet-name>`.
   3. `ssh-copy-id <alias>`.
   4. `ssh -O exit <alias>`, which closes the password connection ssh keeps open.

   Then SSH in with the key and re-run `bash setup.sh ubuntu` in that session. It turns off password logins and, now that Tailscale is logged in, turns on its auto-update and makes you its operator. Before closing that session, check a fresh login from the Mac with `ssh -S none <alias> true`, which skips the shared connection. Don't run `ssh -O exit` now: it would close that session too.
8. **GitHub.** If you skipped it during setup, run `gh auth login --insecure-storage --git-protocol https`, `gh auth setup-git`, then `bash setup.sh git`.
9. **Commit signing.** Run `just git-signing` and the `gh` commands it prints. [Commit signing](#commit-signing) has more.
10. **AI tools.** Do the AI tools' [manual steps](./ai_tools/README.md#manual-steps).
11. **Logitech.** At the Ubuntu desktop, open Solaar and pair your devices.
12. **Desktop session after a reboot.** Solaar and Claude in Chrome need a desktop session, and a reboot ends it. Turn on GNOME's Remote Login in **Settings → System → Remote Desktop**, set its username and password, and connect over Tailscale with the Mac's Windows App. Or turn on automatic login in GDM, which starts a session at boot but leaves the login keyring locked.
13. **Phone alerts.** Install the ntfy app on your phone, subscribe to a topic with a long random name, and run `just alerts`. Paste the topic name at its prompt, which hides it, or a full `https://` URL for a topic on another ntfy server. Then run `just alerts test`. Disk warnings, UPS events, the daily health alert, and the boot notice then push there. `just alerts test` also tests the UPS notifier once a UPS is set up, so run it again after **Power cuts**.
14. **Power cuts.** Plug the machine into a UPS with its USB cable, and re-run `bash setup.sh ubuntu`. Then test it:
    1. Unplug the UPS from the wall, and wait for the low-battery push, the shutdown, and the UPS cutting its output. `sudo upsmon -c fsd` starts the shutdown at once. If the UPS doesn't cut its output, look in its settings for one that turns the output off on shutdown. Otherwise, while mains is still out, the fallback below starts the machine on battery, and it shuts down and starts again until the battery runs out.
    2. Plug the UPS back in, and check that the machine starts and `just status` reports the UPS on mains.
    3. At the machine, check the fallback for a UPS that keeps its power on: `sudo rtcwake -m off -s 120` should start the machine 2 minutes later. If it doesn't, the fallback won't work on this board, and only the BIOS power-loss setting brings the machine back, when the UPS cuts its power.
15. **Backups.** Back up `~`, including `~/.t3` and `~/.worktrees`, and `/var/lib/docker/volumes` off the machine, with restic or Borg on a schedule. Restore a few files once to check it.
16. **Livepatch (optional).** With a free Ubuntu Pro token, run `sudo pro attach <token>` and `sudo pro enable livepatch` for kernel fixes without a reboot.

Later, when needed:

- Reboot when `just status` says one is pending, at a time no agent is running.
- Install firmware updates when `just status` lists them: `fwupdmgr refresh && fwupdmgr update`.
- After a release upgrade, re-run `bash setup.sh` and `bash ai_tools/setup.sh`, which turn the third-party apt sources back on.

## Check it works

Run these once setup and the manual steps are done. The AI tools have their own [checks](./ai_tools/README.md#check-it-works).

### macOS

- In the repo, `just status` prints no **Needs attention** line.
- In a new Ghostty window, `command -v brew mise node` prints a path for each.
- In a scratch repo, `git commit --allow-empty -m test`, then `git log --show-signature -1`, shows `Good "git" signature`.
- After a reboot, before any `ssh` command, a commit still signs without asking for the passphrase.
- If you ran `just touch-id`, `sudo -k && sudo -v` asks for Touch ID, both in a new terminal and inside tmux.
- With a file open in Zed, the Stream Deck **Terminal** key opens Ghostty at its folder. **Overview** opens the **System** page, where every key shows a number within a few seconds.
- With a URL copied, `Ctrl+Opt+Cmd+N` opens a new Chrome tab with the URL selected in the address bar.

### Ubuntu

Run these over SSH from the Mac.

- In the repo, run `sudo -v`, then `just status`. It prints no **Needs attention** line.
- In a new SSH session, `command -v brew mise node` prints a path for each.
- A test commit shows `Good "git" signature`, as on macOS.
- After a reboot, `ssh <alias>` connects over the tailnet, `docker ps` works without `sudo`, `tmux ls` lists the sessions from before, and the phone gets the boot notice.

## Updating

The `upgrade` shell function runs `scripts/upgrade.sh` from this repo, which updates everything installed. A stage that fails doesn't stop the rest, and `upgrade` lists the failed stages and returns 1:

- Ubuntu's apt packages: `sudo apt upgrade`.
- Homebrew: `brew upgrade`, then the formulae added to the Brewfile and the casks added to the homebrew step. On Ubuntu it then refreshes the font cache.
- Casks that update themselves, or whose updater the repo turns off (Zed, AppCleaner, The Unarchiver, Logi Options+), when one is outdated and not running. Logi Options+ upgrades even while it runs.
- App Store apps (macOS): `mas upgrade`.
- vim and tmux plugins, each to the commit the repo pins.
- mise tools (Node, Go): `mise upgrade`. mise later removes old Node versions, with any CLI installed with `npm install -g`, so install global CLIs with `mise use -g npm:<package>`.
- Global npm packages: `npm update -g`, run with the Node `mise upgrade` installed. When `upgrade` can't switch to that Node, it skips this.
- Python tools installed with uv: `uv tool upgrade --all`
- Rust: `rustup update`
- AI tools: `upgrade-ai-tools`, described in [ai_tools/README.md](./ai_tools/README.md#updating)
- Old Homebrew versions: `brew cleanup`. It runs last, so it also removes the old versions of the casks upgraded above.

Plugins never move past the commits the repo pins. `just bump-plugins` moves the pins (see [Maintenance](#maintenance)).

macOS itself updates from **System Settings → General → Software Update**, and snapd updates the Ghostty snap.

Don't run `brew bundle cleanup`. The Brewfile lists no casks, so it would uninstall every cask.

Configs come from this repo, so to update them, pull, then re-run `bash setup.sh` for configs and `bash ai_tools/setup.sh` for the AI tools' configs, skills, and instructions, or just the steps you need.

## Maintenance

Copy config files from the system back to this repo:

```sh
cp ~/.config/git/config git/gitconfig
cp ~/.config/git/ignore git/ignore
cp ~/.config/git/fsmonitor git/fsmonitor
cp "$(lazygit --print-config-dir)/config.yml" lazygit/config.yml
cp ~/.vimrc vim/vimrc
for file in zsh/*.zsh; do cp "$HOME/.zsh/${file##*/}" "$file"; done
cp ~/.zsh/profile.sh zsh/profile.sh   # Ubuntu
cp ~/.config/starship.toml zsh/config/starship.toml
cp ~/.config/ghostty/config.ghostty ghostty/config.ghostty
cp ~/.config/tmux/tmux.conf tmux/tmux.conf
cp ~/.local/bin/tmux-sessionizer tmux/bin/tmux-sessionizer
cp ~/.local/bin/git-wt git/bin/git-wt
cp ~/.claude/hooks/worktree-hook.sh ai_tools/claude-code/worktree-hook.sh
cp ~/.claude/statusline.sh ai_tools/claude-code/statusline.sh
cp ~/.config/zed/settings.json ~/.config/zed/keymap.json zed/
cp ~/.editorconfig editorconfig/editorconfig
cp ~/.hammerspoon/init.lua hammerspoon/init.lua   # macOS
cp ~/.hammerspoon/bin/open-in stream-deck/com.gpahal.dotfiles.sdPlugin/bin/open-in   # macOS
cp ~/Library/LaunchAgents/dotfiles.ssh-add.plist ssh/dotfiles.ssh-add.plist   # macOS
cp ~/Library/LaunchAgents/dotfiles.claude-desktop.plist ai_tools/claude-desktop/dotfiles.claude-desktop.plist   # macOS
cp ~/Library/LaunchAgents/dotfiles.t3code-telemetry-off.plist ai_tools/t3-code/dotfiles.t3code-telemetry-off.plist   # macOS
cp ~/.config/environment.d/99-homebrew.conf ubuntu/environment.d/99-homebrew.conf   # Ubuntu
cp ~/.claude/CLAUDE.md ai_tools/user-instructions.md   # or ~/.codex/AGENTS.md
cp /etc/smartmontools/run.d/50dotfiles-notify ubuntu/smartd-notify.sh   # Ubuntu
cp /usr/local/libexec/dotfiles-ups-notify ubuntu/ups-notify.sh   # Ubuntu
cp /usr/local/lib/dotfiles/ntfy.sh ubuntu/lib/ntfy.sh   # Ubuntu
```

With `XDG_CONFIG_HOME` set, copy the git and tmux configs, and on Ubuntu the Ghostty and Zed configs, from under it. The repo keeps no copy of `~/.gitconfig`, `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.profile`, or `~/.ssh/config`. To change the lines setup adds to them, edit the scripts that write them: `zsh/install.sh`, `ssh/install.sh`, `ssh/add-host.sh`, `git/install.sh`, and `git/setup-signing.sh`.

Packages installed by hand don't go back automatically. Add formulae to `homebrew/Brewfile`, App Store apps to `MAS_APPS` and casks to `CASKS` in `homebrew/install.sh`, and each to [What's included](#whats-included). A cask Ubuntu gets too also goes in `UBUNTU_CASKS` and the Packages list in [Ubuntu](#ubuntu-1).

Update the vim and tmux plugins, and vim-plug itself, with `just bump-plugins`. It moves the pins in `vim/vimrc` and `tmux/plugins.lock` to each plugin's latest commit, and replaces `vim/plug.vim` when vim-plug has a newer release. It prints a link to review each change. Commit the result. Then on each machine, re-run `bash setup.sh vim tmux`, which copies the new pins and moves the tmux plugins. It leaves installed vim plugins at their old commits, so then run `upgrade`, or only `vim -Nes -u ~/.vimrc -i NONE -c 'PlugUpdate --sync' -c qa`, to move them.

**Stream Deck and Hammerspoon.** The Stream Deck keys and Hammerspoon's `Ctrl+Opt+Cmd+N`, `Ctrl+Opt+Cmd+T`, and `Ctrl+Opt+Cmd+E` run the plugin's `bin/open-in`, which the `hammerspoon` step copies to `~/.hammerspoon/bin`. Each run logs a line, to `~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log` from a key and to Hammerspoon's console from a hotkey. After editing the **System** page in `stream-deck/profile`, run `bash stream-deck/build-profile.sh` and commit both. Stream Deck installs the page on the first **Overview** press and keeps its own copy, so to load a changed page, delete the **System** profile in Stream Deck's settings and press **Overview** again.

[AGENTS.md](./AGENTS.md) describes how to add a config or step, and how to check and test one with `just check`, `just test`, and `just test-ubuntu`.

## License

Licensed under the MIT license ([LICENSE](LICENSE) or [opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)).
