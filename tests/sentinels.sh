# shellcheck shell=bash
# shellcheck disable=SC2034 # sourcing files read SENTINELS

# Commands a test must stub; running one unstubbed fails the test, even under `|| true`. List any
# that changes the machine, uses the network, or prints machine-specific output, and any whose
# presence a step checks, so the check finds the stub on every machine. A test needing a real one
# saves its path before setup_sandbox.
SENTINELS="brew apt apt-get add-apt-repository snap systemctl launchctl defaults softwareupdate mas
osascript curl wget npx npm gh tailscale ufw docker loginctl chsh killall pkill open xdg-open
locale-gen sysctl apparmor_parser rustup ssh-add xcode-select mise claude codex t3 uv bun pnpm ss
smartctl fwupdmgr fdesetup socketfilterfw notify-send runuser logger nmcli apt-config journalctl
orb nut-scanner upsc udevadm activateSettings apt-mark lsblk lsappinfo pgrep scutil pbpaste dpkg
dpkg-query ip bwrap systemd-detect-virt mdls m1ddc ddcutil ioreg busctl gdbus gsettings gnome-extensions
systemd-run gnome-shell"
