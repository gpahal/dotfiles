#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The ubuntu step's main and status on a new machine (tests/ubuntu-step-fixture.sh): what status
# lists, a declined run, an approved one, then apt's daily timers, the packages apt holds back, a
# pending reboot, sshd at boot, a re-run that changes nothing, a VM, smartd's hook, the health
# alerts' user units (reloaded until systemd has them, and not installed from a git worktree), and
# Wake-on-LAN. Also tests/ubuntu-sandbox.sh's check for a constant left on a system path. The other
# test-ubuntu-*.sh tests of the step's main start from the machine this one sets up.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

setup_sandbox
ubuntu_step_setup
# ubuntu_sandbox_paths fails the test when a constant still names a system path, as REBOOT_REQUIRED did once a test
# loaded the step again
leak_reboot_required() {
    TEST_FAILURES=0
    REBOOT_REQUIRED=/var/run/reboot-required
    _ubuntu_system_paths_left
    exit "$TEST_FAILURES"
}
leak_status=0
leaks="$( (leak_reboot_required) 2>&1)" || leak_status=$?
assert_eq 1 "$leak_status" "the failures for a constant left on a system path"
assert_contains "$leaks" "REBOOT_REQUIRED=/var/run/reboot-required"

# Not set up yet: status lists each new item as missing
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

# Declined: lists them, and changes nothing that needs sudo
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
if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
    fail "the declined step ran sudo without -n"
fi
# The environment.d file needs no sudo, so it's copied either way, and the user manager reloaded
ENV_CONF="$HOME/.config/environment.d/99-homebrew.conf"
assert_eq "$(cat "$REPO_DIR/ubuntu/environment.d/99-homebrew.conf")" "$(cat "$ENV_CONF")" "the environment.d file"
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
# So are the health alert's user units, which name this repo, and they're turned on: the timer
# runs, and the boot notice waits for the next boot
USER_UNITS="$HOME/.config/systemd/user"
assert_file_contains "$USER_UNITS/dotfiles-health.service" "ExecStart=/bin/bash \"$REPO_DIR/ubuntu/health-alert.sh\" status"
assert_file_contains "$USER_UNITS/dotfiles-health.timer" "Persistent=true"
assert_file_contains "$USER_UNITS/dotfiles-health.timer" "RandomizedDelaySec="
assert_file_contains "$USER_UNITS/dotfiles-boot-notice.service" "ExecStart=/bin/bash \"$REPO_DIR/ubuntu/health-alert.sh\" boot"
assert_file_contains "$USER_UNITS/dotfiles-boot-notice.service" "WantedBy=default.target"
assert_file_contains "$STUB_LOG" "systemctl --user enable --now dotfiles-health.timer"
assert_file_contains "$STUB_LOG" "systemctl --user enable dotfiles-boot-notice.service"
assert_contains "$RUN_OUTPUT" "Turned on the daily health alert and the boot notice"

# Approved: everything is written, applied, and reported ok. With no SSH key login to go by, the
# VM opt-in turns password logins off.
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
# Already installed, so only enabled
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now smartmontools.service"
assert_file_not_contains "$STUB_LOG" "apt-get"
# smartd-runner runs the hook as root, so it's executable and a copy of the repo's
cmp -s "$REPO_DIR/ubuntu/smartd-notify.sh" "$SMARTD_HOOK" || fail "smartd's hook isn't the repo's"
[ -x "$SMARTD_HOOK" ] || fail "smartd's hook isn't executable"
# with the ntfy code it sources, which the UPS notifier shares
cmp -s "$REPO_DIR/ubuntu/lib/ntfy.sh" "$NTFY_LIB" || fail "the hook's ntfy code isn't the repo's"
# smartd's conffile stays as the package ships it, so its updates install unattended
assert_file_not_contains "$STUB_LOG" "smartd.conf"
assert_file_not_contains "$STUB_LOG" "systemctl restart smartmontools.service"
# dpkg keeps a conffile you edited, such as NUT's, and takes a new one you didn't
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

# Packages apt holds back, which unattended-upgrades never installs: status names them. New
# dependencies don't hold a package back, as they don't stop unattended-upgrades.
printf '%s\n' "NOTE: This is only a simulation!" "Reading package lists..." \
    "The following packages have been kept back:" "  nut-client nut-server" "  ubuntu-drivers-common" \
    "0 upgraded, 0 newly installed, 0 to remove and 3 not upgraded." > "$SANDBOX/apt-upgrade"
: > "$STUB_LOG"
run status_held_back
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-client, nut-server, ubuntu-drivers-common; sudo apt full-upgrade shows what installing them takes"
assert_file_contains "$STUB_LOG" "apt-get -s -o APT::Get::Upgrade-Allow-New=true -o APT::Get::Always-Include-Phased-Updates=true upgrade"
# Packages on hold with apt-mark get unhold's advice instead, since full-upgrade keeps them back too
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

# A reboot pending for updates: status names the packages, once each
touch "$REBOOT_REQUIRED"
printf '%s\n' linux-image-6.8.0-45-generic linux-base linux-image-6.8.0-45-generic > "$REBOOT_REQUIRED.pkgs"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Reboot pending for updates: linux-base, linux-image-6.8.0-45-generic; reboot when no agent runs"
rm "$REBOOT_REQUIRED.pkgs"
# Without a package list, as when something outside dpkg asks for the reboot, status reports it
# and goes on to the items after it
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Reboot pending for updates; reboot when no agent runs"
assert_contains "$RUN_OUTPUT" "openssh-server"
rm "$REBOOT_REQUIRED"

# apt's daily timers off: status says so, and how to turn them on
echo disabled > "$SANDBOX/units/apt-daily-upgrade.timer"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    apt's daily timers enabled and running (run sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer)"
rm "$SANDBOX/units/apt-daily-upgrade.timer"
# Enabled but stopped: a yes enables and starts both
touch "$SANDBOX/units/apt-daily-upgrade.timer.inactive"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turn on apt's daily timers: systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         apt's daily timers enabled and running"
# A failed enable fails the step, and status still reports them
echo disabled > "$SANDBOX/units/apt-daily.timer"
touch "$SANDBOX/timers-fail"
assert_exit 1 main
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    apt's daily timers enabled and running"
rm "$SANDBOX/timers-fail" "$SANDBOX/units/apt-daily.timer"

# sshd starts at boot through ssh.socket, 26.04's default
echo disabled > "$SANDBOX/units/ssh.socket"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    sshd starts at boot (run sudo systemctl enable --now ssh.socket)"
# The step enables it
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Start sshd at boot: systemctl enable --now ssh.socket"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now ssh.socket"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         sshd starts at boot"
# ssh.service enabled in its place, as Ubuntu's docs describe switching back to: sshd starts at
# boot, so the step leaves ssh.socket off, since it couldn't bind sshd's port
echo disabled > "$SANDBOX/units/ssh.socket"
echo enabled > "$SANDBOX/units/ssh.service"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         sshd starts at boot"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "enable --now ssh.socket"
rm "$SANDBOX/units/"*

# Re-run: nothing to do, and no sudo but sudo -n to read the ufw rules
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
    fail "the re-run ran sudo without -n"
fi
assert_file_not_contains "$STUB_LOG" "daemon-reload"

# In a VM, smartd doesn't run, since the host manages the disks, so its hook isn't installed
stub systemd-detect-virt
mv "$SMARTD_HOOK" "$SMARTD_HOOK.gone"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    smartd running: this is a VM"
assert_contains "$RUN_OUTPUT" "skipped    smartd's warning hook: this is a VM"
# The health alerts use the URL in a VM too
assert_contains "$RUN_OUTPUT" "info       ntfy URL for the disk, UPS, health, and boot alerts not set"
assert_contains "$RUN_OUTPUT" "ok         Daily health alert to ntfy (dotfiles-health.timer) enabled and active"
assert_exit 0 main
[ ! -e "$SMARTD_HOOK" ] || fail "smartd's hook was installed in a VM"
mv "$SMARTD_HOOK.gone" "$SMARTD_HOOK"
stub systemd-detect-virt 'exit 1'

# An outdated hook: status says so, and the step replaces it
echo "# older" >> "$SMARTD_HOOK"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    smartd's warnings pushed to ntfy ($SMARTD_HOOK): out of date"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "install $SMARTD_HOOK"
cmp -s "$REPO_DIR/ubuntu/smartd-notify.sh" "$SMARTD_HOOK" || fail "the old hook wasn't replaced"
# setup-alerts.sh saves the ntfy URL, which status reports as set
mkdir -p "$(dirname "$NTFY_URL_FILE")"
echo https://ntfy.sh/topic > "$NTFY_URL_FILE"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         smartd's warnings pushed to ntfy"
assert_contains "$RUN_OUTPUT" "info       ntfy URL for the disk, UPS, health, and boot alerts set ($NTFY_URL_FILE)"

# The health alert's units after the repo moved: status says they differ, and a run from the repo's
# new place points them there
sed -i.orig "s|$REPO_DIR|$SANDBOX/old-repo|" "$USER_UNITS/dotfiles-health.service"
rm "$USER_UNITS/dotfiles-health.service.orig"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    The health alert's user units in ~/.config/systemd/user: differ from what setup writes; re-run the ubuntu step"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$USER_UNITS/dotfiles-health.service" "$REPO_DIR/ubuntu/health-alert.sh"
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
# A failed daemon-reload after the units changed: the next run, whose files already match,
# reloads again, since systemd still runs the old units
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

# Units that run another checkout: from a worktree, setup leaves them alone
OTHER_REPO="$SANDBOX/other-checkout"
for unit in dotfiles-health.service dotfiles-boot-notice.service; do
    sed -i.orig "s|$REPO_DIR|$OTHER_REPO|" "$USER_UNITS/$unit"
    rm "$USER_UNITS/$unit.orig"
done
OTHER_UNIT="$(cat "$USER_UNITS/dotfiles-health.service")"
in_git_worktree() { true; }
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "is a git worktree, so the daily health alert and the boot notice aren't"
assert_eq "$OTHER_UNIT" "$(cat "$USER_UNITS/dotfiles-health.service")" "the units after a run from a worktree"
assert_file_not_contains "$STUB_LOG" "systemctl --user"
# A throwaway machine opts in
DOTFILES_ALLOW_WORKTREE=1 assert_exit 0 configure_health_alerts
assert_file_contains "$USER_UNITS/dotfiles-health.service" "$REPO_DIR/ubuntu/health-alert.sh"
DOTFILES_ALLOW_WORKTREE=1 assert_exit 0 status
in_git_worktree() { false; }

# in_git_worktree tells a linked worktree, and a dir inside one, from the main checkout
eval "$(declare -f real_in_git_worktree | sed '1s/real_//')"
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
in_git_worktree() { false; }

# No wired connection: Wake-on-LAN is skipped
stub nmcli '[ "$*" != "-t -e no -f UUID,TYPE,NAME connection show" ] || echo "2222-bbbb:802-11-wireless:Home"'
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    Wake-on-LAN: no wired connection"
test_done
