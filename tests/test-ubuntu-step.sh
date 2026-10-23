#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions

# The ubuntu step from a fresh machine: declined, applied, and re-run, plus its held-back package,
# ntfy URL, and health alert checks.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
assert_exit 3 main --status

# Declined: nothing that needs sudo changes
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged"
[ ! -e "$SLEEP_CONF" ] || fail "sleep.conf.d was written without a yes"
[ ! -e "$SMARTD_HOOK" ] || fail "smartd's hook was installed without a yes"
[ ! -e "$KEEP_CONFFILES_CONF" ] || fail "the conffile options were written without a yes"
[ ! -e "$AUTO_UPGRADES_CONF" ] || fail "unattended-upgrades was turned on without a yes"
assert_sudo_noninteractive "the declined step"
# No sudo needed, so set up even when declined
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
USER_UNITS="$HOME/.config/systemd/user"
assert_file_contains "$STUB_LOG" "systemctl --user enable --now dotfiles-health.timer"
assert_file_contains "$STUB_LOG" "systemctl --user enable dotfiles-boot-notice.service"

# With no SSH key login to go by, the VM opt-in turns password logins off
export DOTFILES_ASSUME_YES=1 DOTFILES_SSH_KEY_ONLY=1
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo sysctl --system"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now smartmontools.service"
assert_file_not_contains "$STUB_LOG" "apt-get"
# smartd.conf stays as shipped, so its updates install unattended
assert_file_not_contains "$STUB_LOG" "smartd.conf"
assert_file_not_contains "$STUB_LOG" "systemctl restart smartmontools.service"
assert_file_contains "$STUB_LOG" "sudo ufw allow 41641/udp"
assert_eq magic "$(cat "$SANDBOX/wol")" "Wake-on-LAN"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"

# sshd gets enabled in the run that installs openssh-server, which apply checks again after
stub dpkg-query 'case "${!#}" in
    openssh-server) [ ! -e "$SANDBOX/openssh" ] || echo "install ok installed" ;;
    *) echo "install ok installed" ;;
esac'
stub apt-get '[[ "$*" != *"install -y openssh-server"* ]] || touch "$SANDBOX/openssh"'
echo disabled > "$SANDBOX/units/ssh.socket"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "install -y openssh-server"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now ssh.socket"
stub dpkg-query 'echo "install ok installed"'
stub apt-get 'cat "$SANDBOX/apt-upgrade" 2> /dev/null || true'

# New dependencies don't hold a package back, as they don't stop unattended-upgrades
printf '%s\n' "NOTE: This is only a simulation!" "Reading package lists..." \
    "The following packages have been kept back:" "  nut-client nut-server" "  ubuntu-drivers-common" \
    "0 upgraded, 0 newly installed, 0 to remove and 3 not upgraded." > "$SANDBOX/apt-upgrade"
run status_held_back
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-client, nut-server, ubuntu-drivers-common;"
assert_file_contains "$STUB_LOG" "-o APT::Get::Upgrade-Allow-New=true"
assert_file_contains "$STUB_LOG" "-o APT::Get::Always-Include-Phased-Updates=true"
# full-upgrade keeps held packages back too, so they get unhold's advice
stub apt-mark '[ "$1" != showhold ] || printf "%s\n" nut-server ubuntu-drivers-common linux-generic'
run status_held_back
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-client; sudo apt full-upgrade"
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-server, ubuntu-drivers-common, on hold with apt-mark; sudo apt-mark unhold nut-server ubuntu-drivers-common"
stub apt-mark
printf '%s\n' "The following upgrades have been deferred due to phasing:" "  libfoo1" \
    "0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded." > "$SANDBOX/apt-upgrade"
run status_held_back
assert_contains "$RUN_OUTPUT" "ok         No packages held back from updates"
rm "$SANDBOX/apt-upgrade"

# ssh.service enabled instead of ssh.socket: leave ssh.socket off, since it couldn't bind sshd's port
echo disabled > "$SANDBOX/units/ssh.socket"
echo enabled > "$SANDBOX/units/ssh.service"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         sshd starts at boot"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "enable --now ssh.socket"
rm "$SANDBOX/units/"*

# Re-run: only sudo -n, to read the ufw rules
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
assert_sudo_noninteractive "the re-run"
assert_file_not_contains "$STUB_LOG" "daemon-reload"

# In a VM the host manages the disks
stub systemd-detect-virt
mv "$SMARTD_HOOK" "$SMARTD_HOOK.gone"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "skipped    smartd running: this is a VM"
assert_contains "$RUN_OUTPUT" "skipped    smartd's warning hook: this is a VM"
assert_exit 0 main
[ ! -e "$SMARTD_HOOK" ] || fail "smartd's hook was installed in a VM"
mv "$SMARTD_HOOK.gone" "$SMARTD_HOOK"
stub systemd-detect-virt 'exit 1'

mkdir -p "$(dirname "$NTFY_URL_FILE")"
url_label="ntfy URL for the disk, UPS, health, and boot alerts"
# Only you, nut, and root may read the topic, and it must be long enough not to be guessed
echo https://ntfy.sh/0123456789abcdef0123 > "$NTFY_URL_FILE"
# macOS gives a new file its directory's group, wheel under /tmp
chgrp "$(id -gn)" "$NTFY_URL_FILE"
chmod 644 "$NTFY_URL_FILE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $url_label ($NTFY_URL_FILE): it's $(id -un) $(id -gn) 644 (owner, group, mode), not $(id -un) $(id -gn) 640"
chmod 640 "$NTFY_URL_FILE"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         smartd's warnings pushed to ntfy"
echo https://ntfy.sh/topic > "$NTFY_URL_FILE"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $url_label ($NTFY_URL_FILE): its topic isn't 20 to 64 characters"
echo https://ntfy.sh/0123456789abcdef0123 > "$NTFY_URL_FILE"
# smartd runs the hook only through smartd-runner, which smartd.conf names
sed -i.bak 's/^DEVICESCAN/#DEVICESCAN/' "$SMARTD_CONF"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    smartd's warnings pushed to ntfy ($SMARTD_HOOK): $SMARTD_CONF has no uncommented line with -M exec"
mv "$SMARTD_CONF.bak" "$SMARTD_CONF"

# The units run a copy of the script, outside the repo
for file in health-alert.sh ntfy.sh paths.sh status-format.sh; do
    [ -e "$HOME/.local/share/dotfiles/health-alert/$file" ] || fail "the health alert's $file wasn't copied"
done

# After a failed daemon-reload, the next run reloads even though the files match
echo "# changed" >> "$USER_UNITS/dotfiles-health.service"
touch "$SANDBOX/reload-needed" "$SANDBOX/reload-fails"
assert_exit 1 main
rm "$SANDBOX/reload-fails"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The health alert's user units in ~/.config/systemd/user: changed since systemd loaded them"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
[ ! -e "$SANDBOX/reload-needed" ] || fail "the units weren't reloaded"
assert_exit 0 main --status
test_done
