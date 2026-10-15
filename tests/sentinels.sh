# Sets SENTINELS, the commands that fail when they run in tests/lib.sh's sandbox, or while
# scripts/check-docs.sh sources the steps. Both source this file. Bash 3.2.
# shellcheck shell=bash
# shellcheck disable=SC2034 # the files that source this one read SENTINELS

# Commands a test must stub, since a test that runs one without stubbing it fails, even under
# `|| true`. Add a command here when a test would otherwise reach one that changes the real machine,
# uses the network, or reads real hardware or system state:
# - commands that change the machine or use the network
# - orb, which would reach OrbStack's real machines
# - ss, whose real connections would decide what the ubuntu step's firewall allows
# - read-only commands whose output depends on the real machine: the status diagnostics'
#   smartctl, fwupdmgr, fdesetup, socketfilterfw, nmcli, apt-config, apt-mark, and journalctl,
#   which read the real disks, firmware, security settings, network, apt config, holds, and logs,
#   the ubuntu step's nut-scanner and upsc, which read a real UPS, udevadm, which reads the real
#   devices, and lsblk, which reads the real disks' encryption
# Other read-only commands the tests rely on, such as dscl, dpkg, uname, and id, stay real. A test
# that needs a real sentinel command, such as mise, saves its path before setup_sandbox and runs
# that.
SENTINELS="brew apt apt-get add-apt-repository snap systemctl launchctl defaults softwareupdate mas
osascript curl wget npx npm gh tailscale ufw docker loginctl chsh killall pkill open xdg-open
locale-gen sysctl apparmor_parser rustup ssh-add xcode-select mise claude codex t3 uv bun pnpm ss
smartctl fwupdmgr fdesetup socketfilterfw notify-send runuser logger nmcli apt-config journalctl
orb nut-scanner upsc udevadm activateSettings apt-mark lsblk"
