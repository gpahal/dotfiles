# Compatibility

What each full verification round tested, on what, and what it left to check by hand. Add a section for each new round at the top, and keep the older ones.

## 2026-10-15 Codex review verification

- On macOS 27.0.1 (arm64), under `/bin/bash` 3.2.57, `just check` and `scripts/check-tool-versions.sh` passed.
- The initial sandboxed `just test` run passed 74 scripts and failed 10 because the OS sandbox blocked tmux sockets, process inspection, and Atuin's `nice` call. All 10 passed in targeted reruns outside that OS sandbox, with temporary HOME and test command stubs retained. Across the runs, all 84 test scripts passed, with zero skips.
- The review also used isolated failure and concurrency reproductions. The findings went into an implementation plan; setup code was not changed.
- Ubuntu container/VM tests, `just test-ubuntu`, real setup, reboots, and hardware checks were not run.

## 2026-10-14 CI and zsh completion fixes

Ubuntu 26.04 is the only Linux CI target. Both CI jobs now download yq 4.54.1 on macOS and Ubuntu. Zsh skips insecure completion paths, rebuilds empty completion caches, and only refreshes a cache after initialization succeeds.

- On macOS 27.0.1 (arm64), `just check` and `TEST_FAIL_ON_SKIP=1 just test` passed under `/bin/bash` 3.2.57: 84 tests, zero failures, zero skips.
- The new completion regression passed with missing, cached, empty, and expired dumps. The whole-config terminal test also passed with a world-writable completion directory on `FPATH`; before the fix, that reproduced both `compinit: initialization aborted` and `compdef: unknown command or service: git`.
- Both CI matrices and yq installation blocks passed syntax checks. The actual macOS yq download ran in a temporary directory and passed `scripts/check-tool-versions.sh`.
- GitHub Actions, the Ubuntu container tests, and `just test-ubuntu` weren't run in this round.

## 2026-10-12 Setup review fixes

Fixed the findings from the 2026-10-12 setup reviews. Added one T3 Code server on Ubuntu, a firewall that has no temporary rules, daily health alerts and a boot notice, smartd warnings that repeat, and NUT for the UPS. Then ran a full setup in a systemd VM.

| Machine | OS | CPU |
| --- | --- | --- |
| Mac | macOS 27.0.1 | arm64 |
| OrbStack 2.2.3 machine (`just test-ubuntu`) | Ubuntu 26.04.1 LTS (resolute), with systemd | arm64 |

- `just check` and `just test` passed on the Mac: 82 tests, zero failures, zero skips. `test-harness.sh`'s timing check failed once while the suite ran under load, then passed three runs in a row on its own.
- `just test-ubuntu` passed. It ran `setup.sh` and `ai_tools/setup.sh` twice, rebooted, and ran both `--status` reports. Only the expected items were missing: the gh login and the two git items that wait for it, the Ghostty snap, Tailscale's login, and the Claude Code, Codex, and T3 Connect sign-ins. The health units, the timer, and the boot notice were ok. The smartd repeat setting and NUT showed as skipped, as they should in a VM. The ntfy URL showed as `info`.
- Versions in the VM: bash 5.3.9, git 2.56.0, Homebrew 7.0.9, mise 2026.10.8, rustc 1.99.0, Node 24.21.0, Go 1.27.2, Claude Code 2.1.296, Codex 0.162.1, and T3 Code 0.0.45.
- One T3 Code server, checked in the VM:
  - The service listened on 3773.
  - After `t3 service restart`, and after `kill -9` of its main process, exactly one server listened on 3773.
  - With the service stopped, a `t3 serve` started by hand took 3773. The service then failed its bind and kept retrying, and `--status` reported the manual server as missing. Once the manual server stopped, the service took over 3773.
- Monaspace installed through Homebrew into `~/.local/share/fonts`. The setup didn't hit the case where Zed or Monaspace is already installed outside Homebrew.

Still to check on the real machine:

- [ ] Pair the Mac over Tailscale HTTPS: turn on HTTPS certificates in the Tailscale admin console, run `t3 pair --tailscale`, and add the environment on the Mac.
- [ ] NUT with the real UPS:
  - [ ] The step finds the UPS through udev's `UPOWER_BATTERY_TYPE=ups` tag and installs NUT, and finds nothing with the UPS unplugged.
  - [ ] `upsc ups@localhost`.
  - [ ] The driver starts after the step restarts `nut-driver-enumerator`.
  - [ ] `upsmon` reaches upsd on `localhost`.
  - [ ] The pulled-plug test: unplug the UPS, then check that the machine shuts down, the UPS power-cycles it, and the machine comes back.
  - [ ] The RTC alarm starts the machine 15 minutes after a UPS shutdown when the UPS doesn't cut its output.
  - [ ] The board wakes on its RTC alarm: `sudo rtcwake -m off -s 120` powers it off and starts it 2 minutes later.
  - [ ] Whether UPower still sees the UPS once NUT's driver claims it.
- [ ] ufw's rules for the fixed private ranges, on each port `sshd -T` reports and `ssh.socket` listens on.
- [ ] Solaar installs from Ubuntu's universe archive.
- [ ] continuum's `tmux.service` starts tmux after a reboot and restores the sessions.
- [ ] `git wt prune` from Claude Code's `SessionEnd` hook removes the ending session's clean subagent worktrees and keeps the rest.
- [ ] The daily health alert and the boot notice arrive on the phone.
- [ ] An x86_64 run (`TEST_UBUNTU_ARCH=amd64 just test-ubuntu`, or the real machine).

Still to check on macOS, which no round has covered:

- [ ] `setup.sh` and `ai_tools/setup.sh` stop on an Intel Mac before any step runs.
- [ ] mas installs Amphetamine.
- [ ] The `macos` step turns off Spotlight's `Cmd+Space`, and Raycast can take it.
- [ ] The macOS first-run checklists end to end: no round has run `setup.sh` and `ai_tools/setup.sh` on a fresh Mac or macOS VM.
- [ ] After a real login, the T3 LaunchAgent opens T3 Code with telemetry off.

## 2026-10-10 Ubuntu 26.04 retarget

Moved the Ubuntu target to 26.04 LTS (resolute) and ran the test suite where 26.04 replaces sudo and coreutils with sudo-rs and Rust coreutils.

| Machine | OS | CPU | sudo | coreutils |
| --- | --- | --- | --- | --- |
| Mac | macOS 27.0.1 (26A434) | arm64 | | |
| Container | `ubuntu:26.04` (26.04.1 LTS) in OrbStack's Docker 29.4.0, as a non-root user | arm64 | sudo-rs 0.2.13-0ubuntu1.2 | uutils 0.10.0 (`rust-coreutils`) |

- Tools: on the Mac, `/bin/bash` 3.2.57, zsh 5.9.2, just 1.58.0, ShellCheck 0.11.0, jq 1.8.2, and yq 4.54.1. On 26.04, bash 5.3.9, zsh 5.9, tmux 3.6, git 2.53.0, just 1.45.0, jq 1.8.1, Vim 9.1, and OpenSSH 10.2p1. The container had ShellCheck 0.11.0 and yq 4.54.1 from their releases, and mise 2026.10.5, as CI installs them.
- `just check` and `just test` with `TEST_FAIL_ON_SKIP=1` passed on the Mac and Ubuntu 26.04: 75 tests, zero failures, zero skips. The suite ran from a copy of the repo with a fresh git index, and the container ran with `--init`.
- Before the fixes, two tests failed on Ubuntu and passed on the Mac. `test-zsh-config.sh` reached the `mise` sentinel, and `test-ssh.sh` ran `ssh -G` on a config holding `UseKeychain`, which OpenSSH outside macOS rejects. Both were test bugs.
- `test-harness.sh`'s TERM check failed twice while three suites ran at once. It now waits up to 5 s for the killed test's `sleep`. It didn't fail in 36 later runs, with or without load.
- These forms passed with the real sudo-rs and Rust coreutils: `sudo VAR=val`, `sudo -n` with and without cached credentials, `sudo -v`, `sudo tee` and `tee -a`, `sudo -u`, `sudo install -m` and `-d -m`, `sudo mktemp`, `sudo cp` and `cp -p`, `sudo test -e`, `stat -c %a`, `stat -L -c`, `stat -c %Y`, `sort -s -t`, `sort -k`, `-u`, `-un`, and `-nr`, `paste -sd`, `date -d @N`, `date +FORMAT`, `touch -t`, `mktemp` with and without a template, `readlink` and `readlink -f`, `cp -Rp`, `tail -c1`, `comm`, `uniq -d`, `sha256sum`, and `env -u`. With a password and no `NOPASSWD`, credentials cached by `sudo -v` reached a child shell on the same terminal and no other terminal, as with sudo. Only the error text differs ("interactive authentication is required"), and no script reads it.
- Resolute's archive, checked in the container: `ghostty` 1.3.0, `apparmor` 5.0.2 with `/etc/apparmor.d/bwrap-userns-restrict`, `openssh-server` 10.2p1, whose postinst enables `ssh.socket` and which adds `sshd.service` as an alias of `ssh.service`, `ufw` 0.36.2 with its `/etc/default/ufw` backend settings, `gdm3` 50.1 with `/etc/gdm3/custom.conf`, and `unattended-upgrades` 2.12 with the same `20auto-upgrades` files.

Changes from this round: the codex step loads the bwrap profile `apparmor` puts in `/etc/apparmor.d`. The `ghostty` step keeps the snap, which follows Ghostty's releases, over the archive's 1.3.0. CI added `ubuntu-26.04` to `check` and `ai-settings`. `just test-ubuntu` creates an `ubuntu:resolute` machine. Neither ran here.

Not checked here. amd64 containers can't run on this Mac, since OrbStack's amd64 emulation is off, so every Linux run was arm64. No systemd, AppArmor, sshd, ufw, or snapd ran in the containers. Still to check on a native 26.04 x86_64 machine or a systemd VM: sshd socket activation and `sshd -T`, ufw's backend once enabled, systemd-oomd and linger, the unattended-upgrades defaults, GDM's automatic login, the installer's TPM encryption options, the codex step's AppArmor detection, `t3 browser setup`, T3 Code's `.deb`, the Ghostty quick terminal under GNOME 50, OrbStack's `ubuntu:resolute` image, and a full `setup.sh` and `ai_tools/setup.sh` run followed by a reboot and both `--status` reports.

Also still to check by hand, since the tests stub each of these:

- On 26.04's OpenSSH: the format of the file `$SSH_USER_AUTH` names, that sshd removes it when the session disconnects, and the stale tmux pane whose original session has ended.
- In a VM, without dropping the original session: a password login, a key login, a tmux pane, and the firewall turning on.
- The wording `ufw` prints for a rule's comment and for `ufw delete`.
- A real `apt-get update` competing for the lists lock.
- The sudo-rs and Rust coreutils forms above, on the native machine rather than in a container.
- Vim's `ttymouse` in tmux under Ghostty, and whether Ghostty's Cmd+Shift+= equalizes splits, as `ghostty/config.ghostty` binds it, rather than acting as Cmd++, which raises the font size.
- Noninteractive SSH commands, systemd user services and `environment.d`'s `${HOME}` expansion, and T3 Code's import of the login shell's `PATH`.
- Whether the desktop's `gpg-agent.socket` starts the system agent before Homebrew's gnupg does.
- The diagnostics on real hardware and OS versions: `smartctl`, `fwupdmgr`, `fdesetup`, `socketfilterfw`, and `docker system df`.
- `materialize-head.sh` on a repo with Git LFS files and submodules.
- amd64: every Linux run here was arm64.
- smartd's warning path: `smartd-runner` running `50dotfiles-notify` on a real warning, `runuser` with `notify-send` reaching a GNOME Wayland session's bus, and a real ntfy push arriving on a phone.
- Detection of the LAN device through the `lower_*` links of a real bridge, such as `br0`, holding a physical port, and of a real bond and VLAN.

## 2026-10-10

### Machines

| Machine | OS | CPU |
| --- | --- | --- |
| Mac | macOS 27.0.1 (26A434) | arm64 |

### Versions on the Mac

| Tool | Version |
| --- | --- |
| Claude Code (`claude`) | 2.1.296 |
| Codex CLI (`codex`) | 0.162.0 |
| Claude desktop app | 2.19675.0 |
| ChatGPT desktop app | 26.930.21537 |
| T3 Code (Alpha) app | 0.0.45 |
| Ghostty | 1.3.1 |
| Zed | 1.23.2 |
| OrbStack | 2.2.3 |
| Homebrew | 7.0.9 |
| `/bin/bash` | 3.2.57 |
| zsh | 5.9.2 |
| tmux | 3.8 |
| git | 2.56.0 |
| mise | 2026.10.5 |
| Node | 24.21.0 |
| Go | 1.27.1 |
| jq | 1.8.2 |
| yq (mikefarah) | 4.54.1 |
| ShellCheck | 0.11.0 |
| just | 1.58.0 |
| gh | 2.102.0 |

### Checks run

All passed.

- `just check` on the Mac.
- `just test` on the Mac.
- `scripts/check-ai-settings.sh` with the CLIs above.

### Manual checks left

- `just test-ubuntu` in OrbStack, for the systemd paths, reboot and timer status, and the T3 Code service.
- On the Ubuntu machine: re-run setup, reboot, and confirm key-only SSH login from a second session before closing the first.
- CI on push: the `check` and `ai-settings` jobs in `.github/workflows/check.yml`, each on macOS and Ubuntu.

### Follow-up fixes

Later the same day, a second pass checked the small fixes from the setup review on the Mac, with the same tools: Vim's bounded vim-plug download, Ghostty's steady cursor, the docker step's curl check, pam-reattach in the Brewfile, the T3 Code OOM comment, the status wording for a file with no record, HTTPS for Ubuntu's GitHub login, Claude Code's status line refresh, and doc corrections.

- `just check` passed, and `just test` passed 68 tests with zero failures and zero skips.
- The tests ran in the temp-`HOME` sandbox with stub commands. No real installer, service restart, PAM or firewall change, or machine setting ran, and the native Ubuntu, macOS GUI and PAM, and AI CLI checks above weren't rerun.

## 2026-10-09

Moved from the README; this records the earlier run, not a new verification.

T3 Code 0.0.45 crashed with `SIGSEGV` when systemd executed it directly under
OrbStack's amd64 translation on Apple Silicon, including for `t3 --version`.
Foreground execution and execution through Bash worked. With
`TEST_UBUNTU_ARCH=amd64`, the Ubuntu test runner reported the failure.

Native ARM Ubuntu service and reboot checks passed. A full ARM setup and native
x86_64 service execution remained untested by that run.
