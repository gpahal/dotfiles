#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions
set -euo pipefail

# The other test-ubuntu-*.sh tests start from the machine this one sets up.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

setup_sandbox
ubuntu_step_setup
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Suspend and hibernation off in systemd ($SLEEP_CONF)"
assert_contains "$RUN_OUTPUT" "missing    Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF)"
assert_contains "$RUN_OUTPUT" "missing    smartmontools, with smartd enabled at boot"
assert_contains "$RUN_OUTPUT" "missing    smartd running"
assert_contains "$RUN_OUTPUT" "missing    smartd's warnings pushed to ntfy ($SMARTD_HOOK)"
assert_contains "$RUN_OUTPUT" "info       ntfy URL for the disk, UPS, health, and boot alerts not set; just alerts sets it"
assert_contains "$RUN_OUTPUT" "missing    $KEEP_CONFFILES"
assert_contains "$RUN_OUTPUT" "ok         No packages held back from updates"
assert_contains "$RUN_OUTPUT" "missing    The health alert's user units in ~/.config/systemd/user"
assert_contains "$RUN_OUTPUT" "missing    Daily health alert to ntfy (dotfiles-health.timer) enabled and active"
assert_contains "$RUN_OUTPUT" "missing    Boot notice to ntfy (dotfiles-boot-notice.service) enabled"
assert_contains "$RUN_OUTPUT" "missing    en_US.UTF-8 locale"
assert_contains "$RUN_OUTPUT" "missing    unattended-upgrades runs daily"
assert_contains "$RUN_OUTPUT" "missing    Wake-on-LAN on \"Wired connection 1\""
assert_not_contains "$RUN_OUTPUT" "Home"
assert_contains "$RUN_OUTPUT" "missing    ufw on"
assert_contains "$RUN_OUTPUT" "missing    ~/.config/environment.d/99-homebrew.conf"

# Declined: nothing that needs sudo changes
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_contains "$RUN_OUTPUT" "Wake-on-LAN"
[ ! -e "$SLEEP_CONF" ] || fail "sleep.conf.d was written without a yes"
assert_contains "$RUN_OUTPUT" "Watch disk health: enable smartd"
assert_contains "$RUN_OUTPUT" "Push smartd's warnings to ntfy once a URL is set: install $SMARTD_HOOK"
[ ! -e "$SMARTD_HOOK" ] || fail "smartd's hook was installed without a yes"
assert_contains "$RUN_OUTPUT" "Keep conffiles you edited through updates, so unattended-upgrades doesn't skip them: write $KEEP_CONFFILES_CONF"
[ ! -e "$KEEP_CONFFILES_CONF" ] || fail "the conffile options were written without a yes"
assert_contains "$RUN_OUTPUT" "Add the en_US.UTF-8 locale"
assert_contains "$RUN_OUTPUT" "Install security updates daily: turn on unattended-upgrades"
[ ! -e "$AUTO_UPGRADES_CONF" ] || fail "unattended-upgrades was turned on without a yes"
assert_sudo_noninteractive "the declined step"
# No sudo needed, so copied even when declined
ENV_CONF="$HOME/.config/environment.d/99-homebrew.conf"
assert_eq "$(cat "$REPO_DIR/ubuntu/environment.d/99-homebrew.conf")" "$(cat "$ENV_CONF")" "the environment.d file"
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
USER_UNITS="$HOME/.config/systemd/user"
assert_file_contains "$USER_UNITS/dotfiles-health.service" "ExecStart=/bin/bash \"$REPO_DIR/ubuntu/health-alert.sh\" status"
assert_file_contains "$USER_UNITS/dotfiles-health.timer" "Persistent=true"
assert_file_contains "$USER_UNITS/dotfiles-health.timer" "RandomizedDelaySec="
assert_file_contains "$USER_UNITS/dotfiles-boot-notice.service" "ExecStart=/bin/bash \"$REPO_DIR/ubuntu/health-alert.sh\" boot"
assert_file_contains "$USER_UNITS/dotfiles-boot-notice.service" "WantedBy=default.target"
assert_file_contains "$STUB_LOG" "systemctl --user enable --now dotfiles-health.timer"
assert_file_contains "$STUB_LOG" "systemctl --user enable dotfiles-boot-notice.service"
assert_contains "$RUN_OUTPUT" "Turned on the daily health alert and the boot notice"

# With no SSH key login to go by, the VM opt-in turns password logins off
export DOTFILES_ASSUME_YES=1 DOTFILES_SSH_KEY_ONLY=1
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$SLEEP_CONF" "AllowSuspend=no"
assert_file_contains "$SLEEP_CONF" "AllowHibernation=no"
assert_file_contains "$SLEEP_CONF" "AllowHybridSleep=no"
assert_file_contains "$SLEEP_CONF" "AllowSuspendThenHibernate=no"
assert_file_contains "$SYSCTL_CONF" "kernel.panic = 10"
assert_file_not_contains "$SYSCTL_CONF" "panic_on_oops"
assert_file_contains "$SYSCTL_CONF" "fs.inotify.max_user_instances = 1024"
assert_file_contains "$SYSCTL_CONF" "fs.inotify.max_user_watches = 1048576"
assert_file_contains "$STUB_LOG" "sudo sysctl --system"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now smartmontools.service"
assert_file_not_contains "$STUB_LOG" "apt-get"
cmp -s "$REPO_DIR/ubuntu/smartd-notify.sh" "$SMARTD_HOOK" || fail "smartd's hook isn't the repo's"
[ -x "$SMARTD_HOOK" ] || fail "smartd's hook isn't executable"
cmp -s "$REPO_DIR/ubuntu/lib/ntfy.sh" "$NTFY_LIB" || fail "the hook's ntfy code isn't the repo's"
# smartd.conf stays as shipped, so its updates install unattended
assert_file_not_contains "$STUB_LOG" "smartd.conf"
assert_file_not_contains "$STUB_LOG" "systemctl restart smartmontools.service"
assert_file_contains "$KEEP_CONFFILES_CONF" '"--force-confdef";'
assert_file_contains "$KEEP_CONFFILES_CONF" '"--force-confold";'
assert_file_contains "$STUB_LOG" "sudo locale-gen en_US.UTF-8"
assert_file_contains "$AUTO_UPGRADES_CONF" 'APT::Periodic::Update-Package-Lists "1";'
assert_file_contains "$AUTO_UPGRADES_CONF" 'APT::Periodic::Unattended-Upgrade "1";'
assert_file_contains "$STUB_LOG" "sudo ufw allow 41641/udp"
assert_eq magic "$(cat "$SANDBOX/wol")" "Wake-on-LAN"
assert_contains "$RUN_OUTPUT" "ErP"
assert_exit 0 status
assert_not_contains "$RUN_OUTPUT" "missing"
assert_contains "$RUN_OUTPUT" "ok         $KEEP_CONFFILES"

# New dependencies don't hold a package back, as they don't stop unattended-upgrades
printf '%s\n' "NOTE: This is only a simulation!" "Reading package lists..." \
    "The following packages have been kept back:" "  nut-client nut-server" "  ubuntu-drivers-common" \
    "0 upgraded, 0 newly installed, 0 to remove and 3 not upgraded." > "$SANDBOX/apt-upgrade"
: > "$STUB_LOG"
run status_held_back
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-client, nut-server, ubuntu-drivers-common; sudo apt full-upgrade shows what installing them takes"
assert_file_contains "$STUB_LOG" "apt-get -s -o APT::Get::Upgrade-Allow-New=true -o APT::Get::Always-Include-Phased-Updates=true upgrade"
# full-upgrade keeps held packages back too, so they get unhold's advice
stub apt-mark '[ "$1" != showhold ] || printf "%s\n" nut-server ubuntu-drivers-common linux-generic'
run status_held_back
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-client; sudo apt full-upgrade shows what installing them takes"
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-server, ubuntu-drivers-common, on hold with apt-mark; sudo apt-mark unhold nut-server ubuntu-drivers-common lets them update"
stub apt-mark
printf '%s\n' "The following upgrades have been deferred due to phasing:" "  libfoo1" \
    "0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded." > "$SANDBOX/apt-upgrade"
run status_held_back
assert_contains "$RUN_OUTPUT" "ok         No packages held back from updates"
rm "$SANDBOX/apt-upgrade"

touch "$REBOOT_REQUIRED"
printf '%s\n' linux-image-6.8.0-45-generic linux-base linux-image-6.8.0-45-generic > "$REBOOT_REQUIRED.pkgs"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Reboot pending for updates: linux-base, linux-image-6.8.0-45-generic; reboot when no agent runs"
rm "$REBOOT_REQUIRED.pkgs"
# Something outside dpkg may ask for the reboot without a package list
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Reboot pending for updates; reboot when no agent runs"
assert_contains "$RUN_OUTPUT" "openssh-server"
rm "$REBOOT_REQUIRED"

echo disabled > "$SANDBOX/units/apt-daily-upgrade.timer"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    apt's daily timers enabled and running; run sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
rm "$SANDBOX/units/apt-daily-upgrade.timer"
touch "$SANDBOX/units/apt-daily-upgrade.timer.inactive"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turn on apt's daily timers: systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         apt's daily timers enabled and running"
echo disabled > "$SANDBOX/units/apt-daily.timer"
touch "$SANDBOX/timers-fail"
assert_exit 1 main
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    apt's daily timers enabled and running"
rm "$SANDBOX/timers-fail" "$SANDBOX/units/apt-daily.timer"

# 26.04 starts sshd through ssh.socket
echo disabled > "$SANDBOX/units/ssh.socket"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    sshd starts at boot; run sudo systemctl enable --now ssh.socket"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Start sshd at boot: systemctl enable --now ssh.socket"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now ssh.socket"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         sshd starts at boot"
# ssh.service enabled instead: leave ssh.socket off, since it couldn't bind sshd's port
echo disabled > "$SANDBOX/units/ssh.socket"
echo enabled > "$SANDBOX/units/ssh.service"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         sshd starts at boot"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "enable --now ssh.socket"
rm "$SANDBOX/units/"*

# Re-run: only sudo -n, to read the ufw rules
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
assert_sudo_noninteractive "the re-run"
assert_file_not_contains "$STUB_LOG" "daemon-reload"

# In a VM the host manages the disks
stub systemd-detect-virt
mv "$SMARTD_HOOK" "$SMARTD_HOOK.gone"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    smartd running: this is a VM"
assert_contains "$RUN_OUTPUT" "skipped    smartd's warning hook: this is a VM"
assert_contains "$RUN_OUTPUT" "info       ntfy URL for the disk, UPS, health, and boot alerts not set"
assert_contains "$RUN_OUTPUT" "ok         Daily health alert to ntfy (dotfiles-health.timer) enabled and active"
assert_exit 0 main
[ ! -e "$SMARTD_HOOK" ] || fail "smartd's hook was installed in a VM"
mv "$SMARTD_HOOK.gone" "$SMARTD_HOOK"
stub systemd-detect-virt 'exit 1'

echo "# older" >> "$SMARTD_HOOK"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    smartd's warnings pushed to ntfy ($SMARTD_HOOK): out of date"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "install $SMARTD_HOOK"
cmp -s "$REPO_DIR/ubuntu/smartd-notify.sh" "$SMARTD_HOOK" || fail "the old hook wasn't replaced"
mkdir -p "$(dirname "$NTFY_URL_FILE")"
url_label="ntfy URL for the disk, UPS, health, and boot alerts"
# Only you, nut, and root may read the topic, and it must be long enough not to be guessed
echo https://ntfy.sh/0123456789abcdef0123 > "$NTFY_URL_FILE"
chmod 644 "$NTFY_URL_FILE"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $url_label ($NTFY_URL_FILE): it's $(id -un) $(id -gn) 644 (owner, group, mode), not $(id -un) $(id -gn) 640; run just alerts to save it again"
chmod 640 "$NTFY_URL_FILE"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         smartd's warnings pushed to ntfy"
assert_contains "$RUN_OUTPUT" "info       $url_label set ($NTFY_URL_FILE)"
echo https://ntfy.sh/topic > "$NTFY_URL_FILE"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $url_label ($NTFY_URL_FILE): its topic isn't 20 to 64 characters, so it can be guessed;"
echo https://ntfy.sh/0123456789abcdef0123 > "$NTFY_URL_FILE"
# smartd runs the hook only through smartd-runner, which smartd.conf names
cp "$SMARTD_CONF" "$SANDBOX/smartd.conf.orig"
sed -i.bak 's/^DEVICESCAN/#DEVICESCAN/' "$SMARTD_CONF"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    smartd's warnings pushed to ntfy ($SMARTD_HOOK): $SMARTD_CONF has no uncommented line with -M exec /usr/share/smartmontools/smartd-runner"
mv "$SANDBOX/smartd.conf.orig" "$SMARTD_CONF"
rm "$SMARTD_CONF.bak"

# The units after the repo moved
sed -i.orig "s|$REPO_DIR|$SANDBOX/old-repo|" "$USER_UNITS/dotfiles-health.service"
rm "$USER_UNITS/dotfiles-health.service.orig"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    The health alert's user units in ~/.config/systemd/user: differ from what setup writes; re-run the ubuntu step"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$USER_UNITS/dotfiles-health.service" "$REPO_DIR/ubuntu/health-alert.sh"
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
# After a failed daemon-reload, the next run reloads even though the files match
sed -i.orig "s|$REPO_DIR|$SANDBOX/old-repo|" "$USER_UNITS/dotfiles-health.service"
rm "$USER_UNITS/dotfiles-health.service.orig"
touch "$SANDBOX/reload-needed" "$SANDBOX/reload-fails"
assert_exit 1 main
rm "$SANDBOX/reload-fails"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    The health alert's user units in ~/.config/systemd/user: changed since systemd loaded them"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
[ ! -e "$SANDBOX/reload-needed" ] || fail "the units weren't reloaded"
assert_exit 0 status

# From a worktree, setup leaves units that run another checkout alone
OTHER_REPO="$SANDBOX/other-checkout"
for unit in dotfiles-health.service dotfiles-boot-notice.service; do
    sed -i.orig "s|$REPO_DIR|$OTHER_REPO|" "$USER_UNITS/$unit"
    rm "$USER_UNITS/$unit.orig"
done
OTHER_UNIT="$(cat "$USER_UNITS/dotfiles-health.service")"
replace_fn in_git_worktree true
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "is a git worktree, so the daily health alert and the boot notice aren't"
assert_eq "$OTHER_UNIT" "$(cat "$USER_UNITS/dotfiles-health.service")" "the units after a run from a worktree"
assert_file_not_contains "$STUB_LOG" "systemctl --user"
DOTFILES_ALLOW_WORKTREE=1 assert_exit 0 configure_health_alerts
assert_file_contains "$USER_UNITS/dotfiles-health.service" "$REPO_DIR/ubuntu/health-alert.sh"
DOTFILES_ALLOW_WORKTREE=1 assert_exit 0 status
replace_fn in_git_worktree false

restore_fn in_git_worktree
GIT_REPO="$SANDBOX/git-main"
git init -q "$GIT_REPO"
mkdir "$GIT_REPO/sub"
git_commit "$GIT_REPO" --allow-empty -m init
git -C "$GIT_REPO" worktree add -q "$SANDBOX/git-wt" -b wt
mkdir "$SANDBOX/git-wt/sub"
assert_exit 1 in_git_worktree "$GIT_REPO"
assert_exit 1 in_git_worktree "$GIT_REPO/sub"
assert_exit 0 in_git_worktree "$SANDBOX/git-wt"
assert_exit 0 in_git_worktree "$SANDBOX/git-wt/sub"
assert_exit 1 in_git_worktree "$SANDBOX"
replace_fn in_git_worktree false

# just alerts shows the ntfy topic as QR codes
stub dpkg-query '[ "${!#}" == qrencode ] || echo "install ok installed"'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    qrencode, which just alerts shows the ntfy topic with"
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=1 assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install qrencode, which just alerts uses to show the ntfy topic as QR codes"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y qrencode"
stub dpkg-query 'echo "install ok installed"'

stub nmcli '[ "$*" != "-t -e no -f UUID,TYPE,NAME connection show" ] || echo "2222-bbbb:802-11-wireless:Home"'
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    Wake-on-LAN: no wired connection"
test_done
