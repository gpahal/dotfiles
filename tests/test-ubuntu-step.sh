#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail
# timeout: 300

# The ubuntu step: apt's daily timers, replacing the sshd drop-in without removing a working one or
# blaming the config for a missing sshd, the drop-in's settings, turning password logins off only on
# a key login's evidence (or the VM opt-in) and never back on, checking sshd takes the drop-in's
# settings, carrying on when one part fails, and the settings for running unattended: sleep off in
# systemd, sysctl, smartd, the health alerts' user units (reloaded until systemd has them, and not
# installed from a git worktree), the locale, unattended-upgrades with the dpkg options that keep
# edited conffiles, the packages apt holds back, Tailscale's apt source and UDP port, and
# Wake-on-LAN.
# Every path under /etc, /run, and /dev points into the sandbox, and sudo, systemctl, sysctl, sshd,
# ss, ufw, nmcli, tailscale, apt-config, apt-get, locale, locale-gen, and git's worktree check are
# stubs.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ubuntu/install.sh
is_ubuntu() { true; }
# The system dirs sbin_cmd searches for sysctl and ufw, here the stubs
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$STUB_DIR"
ufw_enabled() { [ -e "$SANDBOX/ufw-on" ]; }
lingering() { true; }
# test-diagnostics.sh covers SMART health and firmware updates
status_smart() { :; }
status_firmware() { :; }
# test-ubuntu-ups.sh covers the UPS
ups_todo() { :; }
status_ups() { :; }
warn_no_ups() { :; }
# This checkout may be a worktree, so the check is replaced, and tested on its own below
eval "real_$(declare -f in_git_worktree)"
in_git_worktree() { false; }

# The systemd user manager reads only ~/.config/environment.d, so XDG_CONFIG_HOME doesn't move it
assert_eq "$HOME/.config/environment.d/99-homebrew.conf" \
    "$(export XDG_CONFIG_HOME="$SANDBOX/xdg" && load_script ubuntu/install.sh && echo "$HOMEBREW_ENV_CONF")" \
    "the environment.d file with XDG_CONFIG_HOME set"

# --- the rest runs main and status on a machine set up through sandbox paths ---
# sudo runs the command, and refuses a path under /etc, /run, or /dev
stub sudo 'for a in "$@"; do case "$a" in /etc/* | /run/* | /dev/*) echo "refused: $a" >&2; exit 1 ;; esac; done
exec env "$@"'
stub dpkg-query 'echo "install ok installed"'
# systemctl: the sleep targets are masked, apt's timers and ssh.socket are enabled and ssh.service
# disabled, as on 26.04, unless $SANDBOX/units/<unit> holds another state, which enable
# of ssh.socket or ssh.service sets to enabled. A unit is active unless
# $SANDBOX/units/<unit>.inactive exists. enable --now of apt's timers enables and starts them,
# unless $SANDBOX/timers-fail exists. smartd is enabled and running once systemctl enable --now
# ran, unless $SANDBOX/smartd-failed exists, which only restart clears. A user unit is enabled
# once systemctl --user enable ran, and active once enable --now did. A user unit needs a
# daemon-reload while $SANDBOX/reload-needed exists, which daemon-reload removes, unless
# $SANDBOX/reload-fails exists. A test's own lines go first.
stub_systemctl() {
    stub systemctl "${1:-}"'
case "$1" in
    --user) case "$2" in
        enable) for unit in "${@:3}"; do
                [ "$unit" != --now ] || continue
                touch "'"$SANDBOX"'/user-units/$unit.enabled"
                [[ " $* " != *" --now "* ]] || touch "'"$SANDBOX"'/user-units/$unit.active"
            done ;;
        is-enabled) [ -e "'"$SANDBOX"'/user-units/${!#}.enabled" ] ;;
        is-active) [ -e "'"$SANDBOX"'/user-units/${!#}.active" ] ;;
        show) [ "$4" == NeedDaemonReload ] || exit 0
            [ -e "'"$SANDBOX"'/reload-needed" ] && echo yes || echo no ;;
        daemon-reload) [ ! -e "'"$SANDBOX"'/reload-fails" ] || exit 1
            rm -f "'"$SANDBOX"'/reload-needed" ;;
    esac ;;
    is-enabled) case "$2" in
        smartmontools.service) cat "'"$SANDBOX"'/smartd" 2> /dev/null || echo disabled ;;
        apt-daily.timer | apt-daily-upgrade.timer | ssh.socket) cat "'"$SANDBOX"'/units/$2" 2> /dev/null || echo enabled ;;
        ssh.service) cat "'"$SANDBOX"'/units/$2" 2> /dev/null || echo disabled ;;
        *) echo masked ;;
    esac ;;
    enable)
        case "$3" in ssh.socket | ssh.service) echo enabled > "'"$SANDBOX"'/units/$3"; exit 0 ;; esac
        if [ "$3" == apt-daily.timer ]; then
            [ ! -e "'"$SANDBOX"'/timers-fail" ] || exit 1
            for unit in "${@:3}"; do rm -f "'"$SANDBOX"'/units/$unit" "'"$SANDBOX"'/units/$unit.inactive"; done
            exit 0
        fi
        [ "$3" == smartmontools.service ] || exit 0
        echo enabled > "'"$SANDBOX"'/smartd"
        [ -e "'"$SANDBOX"'/smartd-failed" ] || touch "'"$SANDBOX"'/smartd-active" ;;
    restart) [ "$2" != smartmontools.service ] || { rm -f "'"$SANDBOX"'/smartd-failed"; touch "'"$SANDBOX"'/smartd-active"; } ;;
    is-active) case "$3" in
        smartmontools.service) [ -e "'"$SANDBOX"'/smartd-active" ] ;;
        *) [ ! -e "'"$SANDBOX"'/units/$3.inactive" ] ;;
    esac ;;
esac'
}
stub_systemctl
stub systemd-detect-virt 'exit 1'
# sysctl --system puts the settings of the files in $SANDBOX/sysctl.d in effect. It fails when
# $SANDBOX/sysctl-fails exists. sysctl -n prints one setting.
stub sysctl 'live="'"$SANDBOX"'/sysctl-live"
case "$1" in
    --system) [ ! -e "'"$SANDBOX"'/sysctl-fails" ] || exit 1
        cat "'"$SANDBOX"'/sysctl.d/"*.conf | grep "=" | tr -d " " >> "$live" ;;
    -n) grep "^$2=" "$live" 2> /dev/null | tail -n 1 | cut -d= -f2 ;;
esac'
# The en_US.UTF-8 locale is there once locale-gen ran
stub locale 'echo C.utf8; [ ! -e "'"$SANDBOX"'/locale" ] || echo en_US.utf8'
stub locale-gen 'touch "'"$SANDBOX"'/locale"'
# apt-get -s upgrade prints $SANDBOX/apt-upgrade
stub apt-get 'cat "'"$SANDBOX"'/apt-upgrade" 2> /dev/null || true'
# No package is on hold with apt-mark
stub apt-mark
# unattended-upgrades runs daily once a file in apt.conf.d says so. As in apt, the last file
# that sets it wins.
AUTO_UPGRADES_CONF="$SANDBOX/apt.conf.d/20auto-upgrades"
stub_apt_config 'cat "'"$SANDBOX"'/apt.conf.d/"* 2> /dev/null | awk '"'"'{ values[$1] = $0 } END { for (key in values) print values[key] }'"'"''
stub loginctl
stub lsblk
# Tailscale auto-updates, with you as its operator, until $SANDBOX/tailscale-reset exists, as after
# its first login, and its state is in $SANDBOX/tailscale-state
stub tailscale 'case "$1" in
    debug) if [ -e "'"$SANDBOX"'/tailscale-reset" ]; then echo "{}"
        else echo "{\"AutoUpdate\": {\"Apply\": true}, \"OperatorUser\": \"$(id -un)\"}"; fi ;;
    status) echo "{\"BackendState\": \"$(cat "'"$SANDBOX"'/tailscale-state")\"}" ;;
esac'
echo Running > "$SANDBOX/tailscale-state"
# sshd -t fails on any drop-in with a "Bogus" line, naming the file the way sshd does. sshd -T
# prints the port, and the settings the drop-in sets as sshd reads them: the first value in the
# drop-ins in name order, or sshd's default, and every AllowUsers line's users. With -C
# user=<user>,..., a "Match User <user>" block's first value wins over those. sshd -T fails while
# $SANDBOX/sshd-T-fails exists.
mkdir -p "$SANDBOX/sshd_config.d"
SSHD_DROP_IN="$SANDBOX/sshd_config.d/10-dotfiles.conf"
SSHD_RUN_DIR="$SANDBOX/run-sshd"
mkdir -p "$SSHD_RUN_DIR"
SSHD_BIN="$STUB_DIR/sshd"
# No SSH sessions, as at the console. test-ufw-recheck.sh covers them.
stub ss
stub sshd 'case "$1" in
    -T) [ ! -e "'"$SANDBOX"'/sshd-T-fails" ] || exit 255
        user=""
        [ "${2:-}" != -C ] || user="$(sed -n "s/^user=\([^,]*\).*/\1/p" <<< "$3")"
        echo "port 22"
        cat "'"$SANDBOX"'"/sshd_config.d/*.conf 2> /dev/null | awk -v user="$user" '"'"'
            { k = tolower($1) }
            k == "match" { matched = tolower($2) == "user" && $3 == user; inmatch = 1; next }
            inmatch && !matched { next }
            k == "allowusers" { for (i = 2; i <= NF; i++) users = users " " $i; next }
            k ~ /^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)$/ {
                if (inmatch) { if (!(k in m)) m[k] = $2 } else if (!(k in v)) v[k] = $2
            }
            END {
                for (k in m) v[k] = m[k]
                print "passwordauthentication", ("passwordauthentication" in v) ? v["passwordauthentication"] : "yes"
                print "kbdinteractiveauthentication", ("kbdinteractiveauthentication" in v) ? v["kbdinteractiveauthentication"] : "yes"
                print "permitrootlogin", ("permitrootlogin" in v) ? v["permitrootlogin"] : "without-password"
                n = split(users, u, " ")
                for (i = 1; i <= n; i++) print "allowusers", u[i]
            }'"'"' ;;
    -t) for f in "'"$SANDBOX"'"/sshd_config.d/*.conf; do
            if grep -q "^Bogus" "$f"; then echo "$f: line 1: Bad configuration option: Bogus" >&2; exit 255; fi
        done ;;
esac'
# ufw status lists every rule the step adds, once it has run ufw --force enable
stub ufw 'case "$1" in
    --force) touch "'"$SANDBOX"'/ufw-on" ;;
    status) [ -e "'"$SANDBOX"'/ufw-on" ] && printf "%s\n" "Status: active" "" \
        "22/tcp                     ALLOW       10.0.0.0/8" \
        "22/tcp                     ALLOW       172.16.0.0/12" \
        "22/tcp                     ALLOW       192.168.0.0/16" \
        "22/tcp                     ALLOW       fd00::/8" \
        "22/tcp                     ALLOW       fe80::/10" \
        "Anywhere on tailscale0     ALLOW       Anywhere" \
        "41641/udp                  ALLOW       Anywhere" ;;
esac'
# One wired connection, "Wired connection 1", whose Wake-on-LAN setting is in $SANDBOX/wol, and
# a Wi-Fi one. The step names connections by UUID, since two can share a name.
stub nmcli 'case "$*" in
    "-t -f UUID,TYPE,NAME connection show") printf "%s\n" "1111-aaaa:802-3-ethernet:Wired connection 1" "2222-bbbb:802-11-wireless:Home\\:5G" ;;
    *"-g 802-3-ethernet.wake-on-lan connection show uuid 1111-aaaa") cat "'"$SANDBOX"'/wol" ;;
    "connection modify uuid 1111-aaaa 802-3-ethernet.wake-on-lan magic") echo magic > "'"$SANDBOX"'/wol" ;;
esac'
echo default > "$SANDBOX/wol"
mkdir "$SANDBOX/units" "$SANDBOX/user-units"
REBOOT_REQUIRED="$SANDBOX/reboot-required"
SLEEP_CONF="$SANDBOX/sleep.conf.d/10-dotfiles.conf"
SYSCTL_CONF="$SANDBOX/sysctl.d/90-dotfiles.conf"
SMARTD_HOOK="$SANDBOX/run.d/50dotfiles-notify"
NTFY_LIB="$SANDBOX/lib-dotfiles/ntfy.sh"
NTFY_URL_FILE="$SANDBOX/etc-dotfiles/ntfy-url"
KEEP_CONFFILES_CONF="$SANDBOX/apt.conf.d/50dotfiles-keep-conffiles"
KEEP_CONFFILES="Updates keep conffiles you edited, so unattended-upgrades doesn't skip them ($KEEP_CONFFILES_CONF)"
# Tailscale's apt source, as its install script writes it
TAILSCALE_ENTRY="deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu resolute main"
echo "$TAILSCALE_ENTRY" > "$APT_SOURCES_DIR/tailscale.list"

# Not set up yet: status lists each new item as missing
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Suspend and hibernation off in systemd ($SLEEP_CONF)"
assert_contains "$RUN_OUTPUT" "missing    Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF)"
assert_contains "$RUN_OUTPUT" "missing    smartmontools, with smartd enabled at boot"
assert_contains "$RUN_OUTPUT" "missing    smartd running"
assert_contains "$RUN_OUTPUT" "missing    smartd's warnings pushed to ntfy ($SMARTD_HOOK)"
assert_contains "$RUN_OUTPUT" "info       ntfy URL for the disk, UPS, health, and boot alerts not set; just alerts <ntfy-url> sets it"
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
installed_unedited "$ENV_CONF" || fail "the environment.d file wasn't recorded"
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
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-client, nut-server, ubuntu-drivers-common; sudo apt full-upgrade shows what installing them takes"
assert_file_contains "$STUB_LOG" "apt-get -s -o APT::Get::Upgrade-Allow-New=true -o APT::Get::Always-Include-Phased-Updates=true upgrade"
# Packages on hold with apt-mark get unhold's advice instead, since full-upgrade keeps them back too
stub apt-mark '[ "$1" != showhold ] || printf "%s\n" nut-server ubuntu-drivers-common linux-generic'
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-client; sudo apt full-upgrade shows what installing them takes"
assert_contains "$RUN_OUTPUT" "missing    Packages apt holds back from updates: nut-server, ubuntu-drivers-common, on hold with apt-mark; sudo apt-mark unhold nut-server ubuntu-drivers-common lets them update"
stub apt-mark
printf '%s\n' "The following upgrades have been deferred due to phasing:" "  libfoo1" \
    "0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded." > "$SANDBOX/apt-upgrade"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         No packages held back from updates"
rm "$SANDBOX/apt-upgrade"
# The conffile options edited: status says so, and the step writes them again
echo "// mine" > "$KEEP_CONFFILES_CONF"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $KEEP_CONFFILES"
assert_exit 0 main
assert_eq "$KEEP_CONFFILES_CONTENT" "$(cat "$KEEP_CONFFILES_CONF")" "the conffile options rewritten"

# A reboot pending for updates: status names the packages, once each
touch "$REBOOT_REQUIRED"
printf '%s\n' linux-image-6.8.0-45-generic linux-base linux-image-6.8.0-45-generic > "$REBOOT_REQUIRED.pkgs"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Reboot pending for updates: linux-base, linux-image-6.8.0-45-generic; reboot when no agent runs"
rm "$REBOOT_REQUIRED" "$REBOOT_REQUIRED.pkgs"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         No reboot pending for updates"

# apt's daily timers off: status says so, and how to turn them on
for unit in apt-daily.timer apt-daily-upgrade.timer; do
    echo disabled > "$SANDBOX/units/$unit"
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    apt's daily timers enabled and running (run sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer)"
    rm "$SANDBOX/units/$unit"
done
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         apt's daily timers enabled and running"
# Disabled, or enabled but stopped: setup lists them, a no leaves them, and a yes enables and
# starts both
for state in disabled inactive; do
    if [ "$state" == disabled ]; then
        echo disabled > "$SANDBOX/units/apt-daily.timer"
    else
        touch "$SANDBOX/units/apt-daily-upgrade.timer.inactive"
    fi
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    apt's daily timers enabled and running"
    : > "$STUB_LOG"
    DOTFILES_ASSUME_YES=0 assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Turn on apt's daily timers: systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
    assert_contains "$RUN_OUTPUT" "Left unchanged"
    assert_file_not_contains "$STUB_LOG" "systemctl enable --now apt-daily.timer"
    assert_exit 0 main
    assert_file_contains "$STUB_LOG" "sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "ok         apt's daily timers enabled and running"
done
# A failed enable fails the step, and status still reports them
echo disabled > "$SANDBOX/units/apt-daily.timer"
touch "$SANDBOX/timers-fail"
assert_exit 1 main
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    apt's daily timers enabled and running"
rm "$SANDBOX/timers-fail" "$SANDBOX/units/apt-daily.timer"

# sshd starts at boot through the unit the system uses: ssh.socket when it's enabled, else
# ssh.service when it is. With neither, Ubuntu's default, ssh.socket.
echo disabled > "$SANDBOX/units/ssh.socket"
echo disabled > "$SANDBOX/units/ssh.service"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    sshd starts at boot (run sudo systemctl enable --now ssh.socket)"
echo enabled > "$SANDBOX/units/ssh.service"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         sshd starts at boot"
rm "$SANDBOX/units/"*
# The step enables the unit status names, after asking
echo disabled > "$SANDBOX/units/ssh.socket"
: > "$STUB_LOG"
DOTFILES_ASSUME_YES=0 assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Start sshd at boot: systemctl enable --now ssh.socket"
assert_file_not_contains "$STUB_LOG" "enable --now ssh"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now ssh.socket"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         sshd starts at boot"
rm "$SANDBOX/units/"*

# Re-run: nothing to do, and no sudo but sudo -n to read the ufw rules
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "already set up"
if grep '^sudo' "$STUB_LOG" | grep -qv '^sudo -n '; then
    fail "the re-run ran sudo without -n"
fi
assert_file_not_contains "$STUB_LOG" "daemon-reload"

# No user manager to reload (a container, or no login yet): the file applies at the next one
rm "$ENV_CONF"
stub_systemctl '[ "$1" != --user ] || exit 1'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "after the next reboot or login"
assert_contains "$RUN_OUTPUT" "the daily health alert and the boot notice"
stub_systemctl

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
# The ntfy code it sources missing: status says the hook is out of date, and the step installs it
rm "$NTFY_LIB"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    smartd's warnings pushed to ntfy ($SMARTD_HOOK): out of date"
assert_exit 0 main
cmp -s "$REPO_DIR/ubuntu/lib/ntfy.sh" "$NTFY_LIB" || fail "the hook's ntfy code wasn't reinstalled"
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
# A stopped timer is started again
rm "$SANDBOX/user-units/dotfiles-health.timer.active"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Daily health alert to ntfy (dotfiles-health.timer) enabled and active"
assert_exit 0 main
assert_exit 0 status
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

# Units that run another checkout: from a worktree, status only notes that it checks them from the
# main checkout, and setup leaves them alone
OTHER_REPO="$SANDBOX/other-checkout"
for unit in dotfiles-health.service dotfiles-boot-notice.service; do
    sed -i.orig "s|$REPO_DIR|$OTHER_REPO|" "$USER_UNITS/$unit"
    rm "$USER_UNITS/$unit.orig"
done
OTHER_UNIT="$(cat "$USER_UNITS/dotfiles-health.service")"
in_git_worktree() { true; }
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "info       The health alert's user units in ~/.config/systemd/user: checked only from the main checkout, which setup installs them from"
# No units at all: missing, from a worktree too
mv "$USER_UNITS/dotfiles-health.service" "$SANDBOX/health.service.away"
run status
assert_contains "$RUN_OUTPUT" "missing    The health alert's user units in ~/.config/systemd/user: not installed; run the ubuntu step from the main checkout"
mv "$SANDBOX/health.service.away" "$USER_UNITS/dotfiles-health.service"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "is a git worktree, so the daily health alert and the boot notice aren't"
assert_eq "$OTHER_UNIT" "$(cat "$USER_UNITS/dotfiles-health.service")" "the units after a run from a worktree"
assert_file_not_contains "$STUB_LOG" "systemctl --user"
# A throwaway machine opts in
DOTFILES_ALLOW_WORKTREE=1 assert_exit 0 configure_health_alerts
assert_file_contains "$USER_UNITS/dotfiles-health.service" "$REPO_DIR/ubuntu/health-alert.sh"
DOTFILES_ALLOW_WORKTREE=1 assert_exit 0 status
# Units that run this worktree, without the opt-in: status says they stop when it's removed, and a
# run says they run it rather than that they aren't set up
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    The health alert's user units in ~/.config/systemd/user: they run this git worktree, so the alerts stop when it's removed; re-run the ubuntu step from the main checkout"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "The daily health alert and the boot notice run this git worktree, $REPO_DIR, so"
in_git_worktree() { false; }
assert_exit 0 main
assert_file_contains "$USER_UNITS/dotfiles-health.service" "$REPO_DIR/ubuntu/health-alert.sh"
assert_exit 0 status

# in_git_worktree tells a linked worktree, and a dir inside one, from the main checkout
eval "$(declare -f real_in_git_worktree | sed '1s/real_//')"
GIT_REPO="$SANDBOX/git-main"
git init -q "$GIT_REPO"
mkdir "$GIT_REPO/sub"
git -C "$GIT_REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$GIT_REPO" worktree add -q "$SANDBOX/git-wt" -b wt
mkdir "$SANDBOX/git-wt/sub"
assert_exit 1 in_git_worktree "$GIT_REPO"
assert_exit 1 in_git_worktree "$GIT_REPO/sub"
assert_exit 0 in_git_worktree "$SANDBOX/git-wt"
assert_exit 0 in_git_worktree "$SANDBOX/git-wt/sub"
assert_exit 1 in_git_worktree "$SANDBOX"
in_git_worktree() { false; }

# No wired connection: Wake-on-LAN is skipped
stub nmcli '[ "$*" != "-t -f UUID,TYPE,NAME connection show" ] || echo "2222-bbbb:802-11-wireless:Home"'
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "skipped    Wake-on-LAN: no wired connection"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "No wired connection"

# Tailscale not logged in: status says so
echo NeedsLogin > "$SANDBOX/tailscale-state"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Tailscale connected (run sudo tailscale up)"
echo Running > "$SANDBOX/tailscale-state"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Tailscale connected"

# Before its first login, Tailscale's auto-update and operator wait, since tailscale up resets them:
# status reports them missing, and the step leaves them until it runs after the login
touch "$SANDBOX/tailscale-reset"
echo NeedsLogin > "$SANDBOX/tailscale-state"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Tailscale auto-updates, with $(id -un) as its operator"
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Turn on Tailscale's auto-update"
assert_contains "$RUN_OUTPUT" "Run sudo tailscale up, then bash setup.sh ubuntu"
assert_file_not_contains "$STUB_LOG" "tailscale set"
echo Running > "$SANDBOX/tailscale-state"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turn on Tailscale's auto-update and make $(id -un) its operator"
assert_file_contains "$STUB_LOG" "sudo tailscale set --auto-update --operator=$(id -un)"
rm "$SANDBOX/tailscale-reset"

# Tailscale's apt source deleted, turned off by a release upgrade, for an older release, or with
# another repo's line in tailscale.list, which the step owns: status says so, and a yes writes the
# key and the one-line tailscale.list for this release, and updates from it alone
TAILSCALE_KEYRING="$SANDBOX/keyrings/tailscale-archive-keyring.gpg"
mkdir -p "$SANDBOX/keyrings"
fetch() {
    echo "fetch $1" >> "$STUB_LOG"
    echo key > "$2"
}
# curl answers the HEAD request for Tailscale's Release file with $SANDBOX/http-status
stub curl 'cat "'"$SANDBOX"'/http-status"'
echo 200 > "$SANDBOX/http-status"
TAILSCALE_ENTRY="deb [signed-by=$TAILSCALE_KEYRING] https://pkgs.tailscale.com/stable/ubuntu resolute main"
echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Tailscale's apt source ($TAILSCALE_LIST)"
for state in deleted disabled jammy other-repo; do
    case "$state" in
        deleted) rm "$TAILSCALE_LIST" ;;
        disabled) echo "# $TAILSCALE_ENTRY # disabled on upgrade to resolute" > "$TAILSCALE_LIST" ;;
        jammy) echo "${TAILSCALE_ENTRY/resolute/jammy}" > "$TAILSCALE_LIST" ;;
        other-repo) printf '%s\n' "$TAILSCALE_ENTRY" "deb http://example.com/ubuntu resolute main" > "$TAILSCALE_LIST" ;;
    esac
    assert_exit 3 status
    if [ "$state" == deleted ]; then
        assert_contains "$RUN_OUTPUT" "missing    Tailscale's apt source ($TAILSCALE_LIST): missing; re-run the ubuntu step"
    else
        assert_contains "$RUN_OUTPUT" "missing    Tailscale's apt source ($TAILSCALE_LIST): differs from what setup writes; re-run the ubuntu step"
    fi
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Rewrite Tailscale's apt source for resolute"
    assert_file_contains "$STUB_LOG" "fetch https://pkgs.tailscale.com/stable/ubuntu/resolute.noarmor.gpg"
    assert_file_contains "$STUB_LOG" "update --error-on=any -o Dir::Etc::sourcelist=$TAILSCALE_LIST -o Dir::Etc::sourceparts=-"
    assert_file_not_contains "$STUB_LOG" "install -y tailscale"
    assert_eq key "$(cat "$TAILSCALE_KEYRING")" "Tailscale's key after repairing a $state source"
    assert_eq "$TAILSCALE_ENTRY" "$(cat "$TAILSCALE_LIST")" "Tailscale's source after repairing a $state one"
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "ok         Tailscale's apt source ($TAILSCALE_LIST)"
done

# Tailscale has no packages for this release yet: the step says so, and waits without failing,
# changing the source, or listing the rewrite. Status says what it waits for.
echo "${TAILSCALE_ENTRY/resolute/jammy}" > "$TAILSCALE_LIST"
echo 404 > "$SANDBOX/http-status"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Tailscale hasn't published packages for Ubuntu resolute yet; re-run this step later."
assert_not_contains "$RUN_OUTPUT" "Rewrite Tailscale's apt source"
run status
assert_contains "$RUN_OUTPUT" "missing    Tailscale's apt source ($TAILSCALE_LIST): differs from what setup writes; Tailscale hasn't published packages for Ubuntu resolute yet"
assert_eq "${TAILSCALE_ENTRY/resolute/jammy}" "$(cat "$TAILSCALE_LIST")" "Tailscale's source while it has no packages for resolute"
assert_file_not_contains "$STUB_LOG" "fetch"
assert_file_not_contains "$STUB_LOG" "update --error-on=any"
echo 200 > "$SANDBOX/http-status"
echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"

# apt-get update fails with the new source: a source the step wrote goes, and an older one comes
# back, so later updates still work. The old key comes back too, or the new one goes.
stub apt-get '[ "$1" != -o ] || [ "$3" != update ] || exit 100'
rm "$TAILSCALE_LIST" "$TAILSCALE_KEYRING"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "apt-get update failed with the new $TAILSCALE_LIST alone, so it was removed"
[ ! -e "$TAILSCALE_LIST" ] || fail "a source apt-get update failed with was kept"
[ ! -e "$TAILSCALE_KEYRING" ] || fail "a key whose source apt-get update failed with was kept"
echo "${TAILSCALE_ENTRY/resolute/jammy}" > "$TAILSCALE_LIST"
echo old-key > "$TAILSCALE_KEYRING"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "so the old one is back"
assert_eq "${TAILSCALE_ENTRY/resolute/jammy}" "$(cat "$TAILSCALE_LIST")" "Tailscale's source after a failed update"
assert_eq old-key "$(cat "$TAILSCALE_KEYRING")" "Tailscale's key after a failed update"
echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"

# Tailscale not installed: a yes adds its repo, then installs it from there. In a subshell, since
# hide changes PATH for the rest of the test.
failures="$TEST_FAILURES"
rm "$TAILSCALE_LIST"
(
    cp "$STUB_DIR/tailscale" "$SANDBOX/tailscale-stub"
    hide tailscale
    stub apt-get 'case "$*" in
        *"install -y tailscale") cp "'"$SANDBOX"'/tailscale-stub" "$STUB_DIR/tailscale" ;;
        *) cat "'"$SANDBOX"'/apt-upgrade" 2> /dev/null || true ;;
    esac'
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    Tailscale"
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Install Tailscale from its apt repo: write $TAILSCALE_LIST and its key"
    assert_eq "$TAILSCALE_ENTRY" "$(cat "$TAILSCALE_LIST")" "Tailscale's source after installing it"
    assert_eq "update --error-on=any
install -y tailscale" "$(grep -oE '^apt-get -o DPkg::Lock::Timeout=300 (update --error-on=any|install -y tailscale)' "$STUB_LOG" |
        sed 's/^apt-get -o DPkg::Lock::Timeout=300 //')" "apt-get's runs to install Tailscale"
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "ok         Tailscale's apt source ($TAILSCALE_LIST)"
    # Before Tailscale publishes packages for this release, a yes installs nothing, and the step
    # doesn't fail
    rm "$STUB_DIR/tailscale" "$TAILSCALE_LIST"
    echo 404 > "$SANDBOX/http-status"
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Tailscale hasn't published packages for Ubuntu resolute yet"
    assert_file_not_contains "$STUB_LOG" "install -y tailscale"
    [ ! -e "$TAILSCALE_LIST" ] || fail "tailscale.list was written before Tailscale published packages for resolute"
    [ "$TEST_FAILURES" -eq "$failures" ]
) || fail "installing Tailscale"
echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"
stub apt-get 'cat "'"$SANDBOX"'/apt-upgrade" 2> /dev/null || true'

# smartd enabled but stopped, or failed: status says so, and a yes starts it, restarting a failed
# one that enable --now didn't start
for state in stopped failed; do
    rm "$SANDBOX/smartd-active"
    [ "$state" != failed ] || touch "$SANDBOX/smartd-failed"
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "ok         smartmontools, with smartd enabled at boot"
    assert_contains "$RUN_OUTPUT" "missing    smartd running"
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Watch disk health: start smartd"
    assert_file_contains "$STUB_LOG" "sudo systemctl enable --now smartmontools.service"
    if [ "$state" == failed ]; then
        assert_file_contains "$STUB_LOG" "sudo systemctl restart smartmontools.service"
    else
        assert_file_not_contains "$STUB_LOG" "systemctl restart"
    fi
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "ok         smartd running"
done

# A failed sysctl --system leaves the file written but not in effect: status says so, and a re-run
# applies it without rewriting the file
rm -f "$SYSCTL_CONF" "$SANDBOX/sysctl-live"
touch "$SANDBOX/sysctl-fails"
assert_exit 1 main
assert_file_contains "$SYSCTL_CONF" "kernel.panic = 10"
rm "$SANDBOX/sysctl-fails"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF): written but not in effect"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Put $SYSCTL_CONF in effect"
assert_file_contains "$STUB_LOG" "sudo sysctl --system"
assert_file_not_contains "$STUB_LOG" "tee $SYSCTL_CONF"
assert_exit 0 status
assert_not_contains "$RUN_OUTPUT" "missing"

# sysctl is in /usr/sbin, which a user's PATH may lack: the check looks there too
mkdir -p "$SANDBOX/sbin"
mv "$STUB_DIR/sysctl" "$SANDBOX/sbin/"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$SANDBOX/sbin"
no_sbin_path="$(tr : '\n' <<< "$PATH" | grep -vxE '/usr/sbin|/sbin' | paste -sd: -)"
sysctl_without_sbin() { PATH="$no_sbin_path" sysctl_in_effect; }
assert_exit 0 sysctl_without_sbin
mv "$SANDBOX/sbin/sysctl" "$STUB_DIR/"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$STUB_DIR"

# --- the sshd drop-in ---
# A changed drop-in sshd accepts replaces the old one, and sshd reloads
echo "# old" > "$SSHD_DROP_IN"
: > "$STUB_LOG"
assert_exit 0 main
assert_eq "$(sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the new drop-in"
assert_file_contains "$STUB_LOG" "sudo systemctl try-reload-or-restart ssh.service"

# Failed activation restores the previous file, so a rerun retries it.
echo '# old, working' > "$SSHD_DROP_IN"
stub_systemctl '[ "$1" != try-reload-or-restart ] || exit 1'
assert_exit 1 main
assert_eq '# old, working' "$(cat "$SSHD_DROP_IN")" "sshd rollback after failed activation"
stub_systemctl
: > "$STUB_LOG"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl try-reload-or-restart ssh.service"

# A failed write leaves the old drop-in whole, its settings and all, and sshd isn't reloaded
printf '%s\n' "PermitRootLogin no" "PasswordAuthentication no" "# old" > "$SSHD_DROP_IN"
cp "$SSHD_DROP_IN" "$SANDBOX/drop-in-before"
stub mv 'case "$*" in *10-dotfiles.conf*) exit 1 ;; esac
exec /bin/mv "$@"'
: > "$STUB_LOG"
assert_exit 1 configure_sshd
rm "$STUB_DIR/mv"
assert_exit 0 cmp -s "$SSHD_DROP_IN" "$SANDBOX/drop-in-before"
assert_eq 10-dotfiles.conf "$(/bin/ls -A "$SANDBOX/sshd_config.d")" "files beside the drop-in after a failed write"
assert_file_not_contains "$STUB_LOG" "try-reload-or-restart ssh.service"

# A broken file elsewhere: the working drop-in stays, sshd isn't reloaded, the step names the
# file, and still does the rest
echo "# old, working" > "$SSHD_DROP_IN"
echo "Bogus yes" > "$SANDBOX/sshd_config.d/50-other.conf"
rm "$SLEEP_CONF"
: > "$STUB_LOG"
assert_exit 1 main
assert_eq "# old, working" "$(cat "$SSHD_DROP_IN")" "the drop-in beside a broken file"
assert_contains "$RUN_OUTPUT" "$SANDBOX/sshd_config.d/50-other.conf"
assert_file_not_contains "$STUB_LOG" "try-reload-or-restart ssh.service"
[ -e "$SLEEP_CONF" ] || fail "the step stopped at the sshd failure"
rm "$SANDBOX/sshd_config.d/50-other.conf"

# A new drop-in sshd rejects: the old one goes back
sshd_drop_in() { echo "Bogus new"; }
: > "$STUB_LOG"
assert_exit 1 main
assert_eq "# old, working" "$(cat "$SSHD_DROP_IN")" "the drop-in after sshd rejected the new one"
assert_contains "$RUN_OUTPUT" "$SSHD_DROP_IN"
assert_file_not_contains "$STUB_LOG" "try-reload-or-restart ssh.service"

# The same with no drop-in before: the rejected one is removed
rm "$SSHD_DROP_IN"
assert_exit 1 main
[ ! -e "$SSHD_DROP_IN" ] || fail "a rejected drop-in was kept"

# No sshd, as when installing openssh-server failed: the step says so, rather than blaming the
# config, and runs no sshd -t
unset -f sshd_drop_in
SSHD_BIN="$SANDBOX/no-sshd"
: > "$STUB_LOG"
assert_exit 1 configure_sshd
assert_contains "$RUN_OUTPUT" "sshd isn't installed"
assert_not_contains "$RUN_OUTPUT" "already fails sshd -t"
assert_file_not_contains "$STUB_LOG" "sshd -t"
[ ! -e "$SSHD_DROP_IN" ] || fail "a drop-in was written without sshd"
# shellcheck disable=SC2034 # configure_sshd reads it
SSHD_BIN="$STUB_DIR/sshd"

# A failed systemctl mask still sets up the rest, then fails
unset -f sshd_drop_in
# The override above took the real sshd_drop_in with it, so reload the step and point it back into
# the sandbox
load_script ubuntu/install.sh
is_ubuntu() { true; }
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$STUB_DIR"
ufw_enabled() { [ -e "$SANDBOX/ufw-on" ]; }
lingering() { true; }
status_smart() { :; }
status_firmware() { :; }
ups_todo() { :; }
status_ups() { :; }
warn_no_ups() { :; }
in_git_worktree() { false; }
SSHD_DROP_IN="$SANDBOX/sshd_config.d/10-dotfiles.conf"
SSHD_RUN_DIR="$SANDBOX/run-sshd"
# shellcheck disable=SC2034 # the step reads it
SSHD_BIN="$STUB_DIR/sshd"
SLEEP_CONF="$SANDBOX/sleep.conf.d/10-dotfiles.conf"
SYSCTL_CONF="$SANDBOX/sysctl.d/90-dotfiles.conf"
AUTO_UPGRADES_CONF="$SANDBOX/apt.conf.d/20auto-upgrades"
# shellcheck disable=SC2034
SMARTD_HOOK="$SANDBOX/run.d/50dotfiles-notify"
# shellcheck disable=SC2034
NTFY_LIB="$SANDBOX/lib-dotfiles/ntfy.sh"
# shellcheck disable=SC2034
KEEP_CONFFILES_CONF="$SANDBOX/apt.conf.d/50dotfiles-keep-conffiles"
# tailscale.list names this keyring, so the source stays the one the step writes
TAILSCALE_KEYRING="$SANDBOX/keyrings/tailscale-archive-keyring.gpg"
stub systemctl 'case "$1" in is-enabled) echo enabled ;; mask) exit 1 ;; esac'
rm -f "$SANDBOX/ufw-on" "$SSHD_DROP_IN"
: > "$STUB_LOG"
assert_exit 1 main
assert_file_contains "$STUB_LOG" "sudo systemctl mask"
assert_eq "$(sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the drop-in after a failed mask"
assert_file_contains "$STUB_LOG" "sudo ufw --force enable"

# --- Wi-Fi that connects only after login ---
# A name with a colon or a backslash, which nmcli -t escapes, is read whole and shown decoded,
# and the commands name the connection by UUID
stub nmcli 'case "$*" in
    "-t -f UUID,TYPE,NAME connection show --active") printf "%s\n" "1111-aaaa:802-3-ethernet:Wired" \
        "2222-bbbb:802-11-wireless:Home\\:5G" "3333-cccc:802-11-wireless:Back\\\\slash" ;;
    "-g connection.permissions connection show uuid 2222-bbbb") echo "user:me" ;;
    "-g 802-11-wireless-security.psk-flags connection show uuid 3333-cccc") echo "1 (agent-owned)" ;;
esac'
run warn_wifi_needs_login
assert_contains "$RUN_OUTPUT" 'Wi-Fi "Home:5G" only connects after you log in'
assert_contains "$RUN_OUTPUT" 'sudo nmcli --ask connection up uuid 2222-bbbb'
assert_contains "$RUN_OUTPUT" 'sudo nmcli connection modify uuid 2222-bbbb connection.permissions'
assert_contains "$RUN_OUTPUT" 'Wi-Fi "Back\slash" only connects after you log in'
assert_contains "$RUN_OUTPUT" 'sudo nmcli --ask connection up uuid 3333-cccc'
assert_not_contains "$RUN_OUTPUT" "Wired"

# --- disk encryption ---
# lsblk -rno TYPE lists the open mappings, and -rno FSTYPE,LABEL the partitions, from
# $SANDBOX/lsblk-types and $SANDBOX/lsblk-labels
stub lsblk 'case "$2" in
    TYPE) cat "'"$SANDBOX"'/lsblk-types" ;;
    FSTYPE,LABEL) cat "'"$SANDBOX"'/lsblk-labels" ;;
esac'
disk() { printf '%s\n' disk part "$@" > "$SANDBOX/lsblk-types"; }
labels() { printf '%s\n' "vfat " "$@" > "$SANDBOX/lsblk-labels"; }
# Not encrypted: nothing to say
disk
labels "ext4 "
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption without encryption"
# A LUKS passphrase, as the installer sets up without TPM: waits at the console, and says what
# avoids it
disk crypt lvm
labels "crypto_LUKS " "LVM2_member "
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase. Every boot waits for it at the console"
assert_contains "$RUN_OUTPUT" "binding the disk to the TPM (systemd-cryptenroll)"
assert_not_contains "$RUN_OUTPUT" "Only a reinstall"
# Bound to the TPM with systemd-cryptenroll, which keeps the label: nothing to say
CRYPTTAB="$SANDBOX/crypttab"
echo "dm_crypt-0 UUID=1234 none luks,tpm2-device=auto" > "$CRYPTTAB"
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption with a disk bound to the TPM"
echo "dm_crypt-0 UUID=1234 none luks" > "$CRYPTTAB"
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase"
# TPM-backed encryption, which snapd labels ubuntu-<role>-enc: nothing to say
disk crypt crypt
labels "crypto_LUKS ubuntu-save-enc" "crypto_LUKS ubuntu-data-enc"
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption with TPM-backed encryption"
# TPM-backed encryption for the system, and a passphrase for another disk: waits at the console
disk crypt crypt crypt
labels "crypto_LUKS ubuntu-save-enc" "crypto_LUKS ubuntu-data-enc" "crypto_LUKS "
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase"

# --- the sshd drop-in's settings ---
# Earlier sections leave other parts unset, so these check only the SSH items
stub_systemctl
# Always: no root logins, a keepalive, only you, and sshd's record of each session's login in
# $SSH_USER_AUTH
unset DOTFILES_SSH_KEY_ONLY SSH_USER_AUTH
rm -f "$SSHD_DROP_IN"
me="$(id -un)"
drop_in="$(sshd_drop_in)"
assert_contains "$drop_in" "PermitRootLogin no"
assert_contains "$drop_in" "ClientAliveInterval 60"
assert_contains "$drop_in" "AllowUsers $me"
assert_contains "$drop_in" "ExposeAuthInfo yes"
# No key yet: password logins stay on
assert_not_contains "$drop_in" "PasswordAuthentication"
mkdir -p "$HOME/.ssh"
chmod 755 "$HOME"
chmod 700 "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/login-key"
ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/other-key"
# ssh-keygen also accepts authorized_keys options, as sshd does
printf 'restrict,command="echo hello" %s\n' "$(cat "$SANDBOX/login-key.pub")" > "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
# sshd writes a line per method the session logged in with, with the key for publickey, and
# removes the file when the session ends
SSH_AUTH_FILE="$SANDBOX/sshauth.XXXX"
key_session() {
    printf 'publickey %s\n' "$(cut -d' ' -f1,2 "$SANDBOX/$1.pub")" > "$SSH_AUTH_FILE"
    export SSH_USER_AUTH="$SSH_AUTH_FILE"
}
key_only_pending() {
    assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication" "the drop-in $2"
    : > "$STUB_LOG"
    run main
    assert_file_not_contains "$SSHD_DROP_IN" "PasswordAuthentication"
    assert_contains "$RUN_OUTPUT" "Password logins stay on: $1"
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off ($1"
    assert_contains "$RUN_OUTPUT" "ssh-copy-id <alias> from the Mac, with the alias just ssh-host added, or this machine's LAN IP before Tailscale is up"
}
# A console run: a key in authorized_keys, and DOTFILES_ASSUME_YES, don't prove it logs in
key_only_pending "this run isn't in an SSH session that sshd recorded the login of" "on the console"
# An invalid line, or a truncated key, is no key either
for invalid in 'not-a-key ssh-just-a-note' 'ssh-ed25519 AAAAC3Nza me@mac'; do
    printf 'publickey %s\n' "$invalid" > "$SSH_AUTH_FILE"
    export SSH_USER_AUTH="$SSH_AUTH_FILE"
    assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication" "the drop-in for an invalid key"
done
# A password session, or one that took a password after the key
printf 'password\n' > "$SSH_AUTH_FILE"
key_only_pending "this SSH session logged in with a password" "in a password session"
key_session login-key
printf 'keyboard-interactive/pam\n' >> "$SSH_AUTH_FILE"
key_only_pending "this SSH session logged in with a password" "in a session that also took a password"
# ssh may have reused a connection that logged in with a password, so the step says how to close it
hint="If you logged in with your key, ssh reused an earlier connection: on the Mac, run ssh -O exit <alias>, then SSH in again."
assert_contains "$RUN_OUTPUT" "(this SSH session logged in with a password. $hint Copy your key over"
run main
assert_contains "$RUN_OUTPUT" "Password logins stay on: this SSH session logged in with a password. $hint"
# A tmux pane that outlived its SSH session: sshd removed the file
export SSH_USER_AUTH="$SANDBOX/sshauth.gone"
key_only_pending "the SSH session this shell started in has ended" "in a stale tmux pane"
# A key that authorized_keys doesn't list, or no longer does
key_session other-key
key_only_pending "the key this SSH session logged in with isn't in ~/.ssh/authorized_keys" "with another key"
# A key session: password logins go off, once you agree
key_session login-key
assert_contains "$(sshd_drop_in)" "PasswordAuthentication no"
DOTFILES_ASSUME_YES=0 run main
assert_contains "$RUN_OUTPUT" "Turn off SSH password logins in $SSHD_DROP_IN: this SSH session logged in with your key SHA256:"
assert_contains "$RUN_OUTPUT" "Left unchanged"
assert_file_not_contains "$SSHD_DROP_IN" "PasswordAuthentication"
run main
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
assert_file_contains "$SSHD_DROP_IN" "KbdInteractiveAuthentication no"
assert_contains "$RUN_OUTPUT" "Keep this session open, and on the Mac check a fresh login with: ssh -S none <alias> true"
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
# A second run changes nothing, even from the console, and asks nothing
unset SSH_USER_AUTH
: > "$STUB_LOG"
run main
assert_not_contains "$RUN_OUTPUT" "$SSHD_DROP_IN"
assert_file_not_contains "$STUB_LOG" "tee $SSHD_DROP_IN"
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
# Never turned back on: not with the key gone from authorized_keys
mv "$HOME/.ssh/authorized_keys" "$SANDBOX/authorized_keys"
assert_contains "$(sshd_drop_in)" "PasswordAuthentication no" "the drop-in once the key is gone"
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
# The opt-in for disposable VMs turns them off without a key login, or any key
rm "$SSHD_DROP_IN"
assert_not_contains "$(sshd_drop_in)" "PasswordAuthentication" "the drop-in without a key"
export DOTFILES_SSH_KEY_ONLY=1
run main
assert_contains "$RUN_OUTPUT" "Turn off SSH password logins in $SSHD_DROP_IN: DOTFILES_SSH_KEY_ONLY=1 is set"
assert_file_contains "$SSHD_DROP_IN" "PasswordAuthentication no"
unset DOTFILES_SSH_KEY_ONLY
run status
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
mv "$SANDBOX/authorized_keys" "$HOME/.ssh/authorized_keys"

# Run as root: no AllowUsers root, which with PermitRootLogin no would refuse everyone. Password
# logins that are off stay off, but root's key doesn't turn them off.
id() { if [ "${1:-}" == -u ]; then echo 0; else echo root; fi; }
drop_in="$(sshd_drop_in)"
fresh_drop_in="$(sshd_drop_in "")"
unset -f id
assert_contains "$drop_in" "PermitRootLogin no"
assert_not_contains "$drop_in" "AllowUsers"
assert_contains "$drop_in" "PasswordAuthentication no"
assert_contains "$drop_in" "KbdInteractiveAuthentication no"
assert_not_contains "$fresh_drop_in" "PasswordAuthentication"

# --- packages missing: smartmontools without its recommends, which pull in a mail server, and
# unattended-upgrades and locales before they're used ---
stub dpkg-query 'case "$*" in *smartmontools* | *unattended-upgrades* | *locales*) ;; *) echo "install ok installed" ;; esac'
stub apt-get
stub_systemctl
rm -f "$SANDBOX/smartd" "$SANDBOX/locale" "$AUTO_UPGRADES_CONF"
: > "$STUB_LOG"
run main
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends smartmontools"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y unattended-upgrades"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y locales"
assert_file_contains "$STUB_LOG" "sudo locale-gen en_US.UTF-8"
assert_file_contains "$AUTO_UPGRADES_CONF" 'APT::Periodic::Unattended-Upgrade "1";'
# Only the pending items run: sysctl is already set up
assert_file_not_contains "$STUB_LOG" "sysctl --system"

# Another file in apt.conf.d that turns unattended-upgrades off wins over the step's: it says so
# and fails
stub dpkg-query 'echo "install ok installed"'
echo 'APT::Periodic::Unattended-Upgrade "0";' > "$SANDBOX/apt.conf.d/99off"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "effective periodic settings still disable daily updates"
rm "$SANDBOX/apt.conf.d/99off"

# --- sshd's effective settings ---
# sshd keeps the first value it reads, so an earlier drop-in can turn a setting back on. Once the
# step writes the drop-in, it reads sshd -T and fails, naming each setting sshd doesn't take, and
# leaves the other file alone. Status reads sshd -T too, with sudo -n.
# sudo -n works here, as with cached credentials
stub sudo '[ "$1" != -n ] || shift
for a in "$@"; do case "$a" in /etc/* | /run/* | /dev/*) echo "refused: $a" >&2; exit 1 ;; esac; done
exec env "$@"'
unset SSH_USER_AUTH
DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in > "$SSHD_DROP_IN"
item="sshd's effective settings match $SSHD_DROP_IN"
: > "$STUB_LOG"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $item"
assert_contains "$RUN_OUTPUT" "ok         Password and keyboard-interactive SSH logins off"
assert_file_contains "$STUB_LOG" "sudo -n sshd -T"
printf '%s\n' "PasswordAuthentication yes" "AllowUsers someone" > "$SANDBOX/sshd_config.d/00-local.conf"
# A later file loses to the drop-in, so it isn't named
echo "PermitRootLogin yes" > "$SANDBOX/sshd_config.d/50-cloud-init.conf"
problems="AllowUsers is someone $me; PasswordAuthentication is yes"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $item ($problems; another file sets them first, which sudo grep -ri <setting> /etc/ssh finds)"
assert_contains "$RUN_OUTPUT" "missing    Password and keyboard-interactive SSH logins off (PasswordAuthentication is yes)"
# The step checks them once it writes the drop-in
rm "$SSHD_DROP_IN"
: > "$STUB_LOG"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sshd doesn't take these settings from $SSHD_DROP_IN, since another file sets them first:
    AllowUsers is someone $me
    PasswordAuthentication is yes"
assert_file_contains "$STUB_LOG" "sudo sshd -T"
assert_eq "PasswordAuthentication yes
AllowUsers someone" "$(cat "$SANDBOX/sshd_config.d/00-local.conf")" "the other drop-in"
# Password logins stay on, so the step doesn't say they're off
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/00-local.conf" "$SANDBOX/sshd_config.d/50-cloud-init.conf"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $item"
# A Match block for you counts too: sshd -T applies it for a login by you from this machine
printf '%s\n' "Match User $me" "    PasswordAuthentication yes" > "$SANDBOX/sshd_config.d/99-match.conf"
: > "$STUB_LOG"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $item (PasswordAuthentication is yes;"
assert_file_contains "$STUB_LOG" "sshd -T -C user=$me,host=localhost,addr=127.0.0.1"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "    PasswordAuthentication is yes"
assert_not_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/99-match.conf"
# Another setting sshd doesn't take fails the step, but password logins went off when sshd
# reloaded, so it says so
echo "PermitRootLogin yes" > "$SANDBOX/sshd_config.d/00-local.conf"
rm "$SSHD_DROP_IN"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "    PermitRootLogin is yes"
assert_contains "$RUN_OUTPUT" "Password logins are off now"
rm "$SANDBOX/sshd_config.d/00-local.conf"
# sshd -T failing after the reload leaves the settings unchecked: the step fails, keeps the new
# drop-in, which sshd took, and says password logins are off. With ufw off, the SSH ports can't be
# read either, so the firewall is left as it is.
touch "$SANDBOX/sshd-T-fails"
rm "$SSHD_DROP_IN" "$SANDBOX/ufw-on"
: > "$STUB_LOG"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sudo sshd -T -C user=$me,host=localhost,addr=127.0.0.1 failed, so whether sshd takes $SSHD_DROP_IN is
  unchecked"
assert_eq "$(DOTFILES_SSH_KEY_ONLY=1 sshd_drop_in)" "$(cat "$SSHD_DROP_IN")" "the drop-in when sshd -T fails"
assert_contains "$RUN_OUTPUT" "Password logins are off now"
assert_contains "$RUN_OUTPUT" "Couldn't read the SSH ports with sudo sshd -T, so the firewall is left unchanged"
assert_file_not_contains "$STUB_LOG" "ufw default"
assert_file_not_contains "$STUB_LOG" "ufw allow"
assert_file_not_contains "$STUB_LOG" "ufw --force enable"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "unverified $item (sudo sshd -T -C user=$me,host=localhost,addr=127.0.0.1 failed; run it to see why)"
rm "$SANDBOX/sshd-T-fails"
DOTFILES_SSH_KEY_ONLY=1 assert_exit 0 main
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $item"
# Without cached sudo credentials, sshd -T can't run: unverified
stub sudo '[ "$1" != -n ] || exit 1
exec env "$@"'
: > "$STUB_LOG"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified $item (the effective values need sudo -v; run sudo -v, then status, to check them)"
assert_file_not_contains "$STUB_LOG" "sshd -T"
# Nor before sshd first ran, which creates $SSHD_RUN_DIR
stub sudo '[ "$1" != -n ] || shift
exec env "$@"'
rmdir "$SSHD_RUN_DIR"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified $item (sshd -T needs $SSHD_RUN_DIR, which the first SSH connection creates)"
mkdir "$SSHD_RUN_DIR"
stub sudo 'for a in "$@"; do case "$a" in /etc/* | /run/* | /dev/*) echo "refused: $a" >&2; exit 1 ;; esac; done
exec env "$@"'

# Software & Updates writes other APT::Periodic keys into 20auto-upgrades: turning
# unattended-upgrades on sets only the step's keys, keeps the rest, and a re-run writes nothing
printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Download-Upgradeable-Packages "1";' \
    'APT::Periodic::AutocleanInterval "7";' 'APT::Periodic::Unattended-Upgrade "0";' > "$AUTO_UPGRADES_CONF"
run main
assert_eq 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Enable "1";' "$(cat "$AUTO_UPGRADES_CONF")" "20auto-upgrades after the merge"
: > "$STUB_LOG"
run main
assert_file_not_contains "$STUB_LOG" "tee $AUTO_UPGRADES_CONF"
test_done
