# Sets SENTINELS, the commands that fail when they run in tests/lib.sh's sandbox, which sources
# this file. Bash 3.2.
# shellcheck shell=bash
# shellcheck disable=SC2034 # the files that source this one read SENTINELS

# Commands a test must stub, since a test that runs one without stubbing it fails, even under
# `|| true`. Add a command here when a test would otherwise reach one that changes the real machine
# (orb reaches OrbStack's real machines), uses the network, or whose output depends on the real
# machine, such as smartctl, ss, pgrep, dpkg, ip, or systemd-detect-virt (CI runners are VMs).
# Other read-only commands the tests rely on, such as dscl, uname, and id, stay real. A test that
# needs a real sentinel command, such as mise, saves its path before setup_sandbox and runs that.
SENTINELS="brew apt apt-get add-apt-repository snap systemctl launchctl defaults softwareupdate mas
osascript curl wget npx npm gh tailscale ufw docker loginctl chsh killall pkill open xdg-open
locale-gen sysctl apparmor_parser rustup ssh-add xcode-select mise claude codex t3 uv bun pnpm ss
smartctl fwupdmgr fdesetup socketfilterfw notify-send runuser logger nmcli apt-config journalctl
orb nut-scanner upsc udevadm activateSettings apt-mark lsblk lsappinfo pgrep scutil pbpaste dpkg
dpkg-query ip bwrap systemd-detect-virt mdls"
