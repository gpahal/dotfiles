#!/bin/bash
set -euo pipefail

# Set up Ubuntu to run unattended around the clock: never sleep, watch a UPS on USB with NUT once
# one is plugged in, which shuts down on a dying battery and has the UPS cut and restore power,
# reboot after a kernel panic, raise the inotify limits for agents' file watchers, add the
# en_US.UTF-8 locale, watch disk health and push its warnings to ntfy, install security
# updates daily and keep edited conffiles through them, start user services (the T3 Code server)
# at boot without a login, start sshd at boot and take SSH logins only for you, and with keys only
# once a session shows your key logs in, install Tailscale, turn on the firewall, letting SSH in
# only from the private ranges and anything in from the tailnet (tailscale0), which Tailscale's
# ACLs limit, once no SSH session comes from elsewhere, and wake on LAN. These need sudo, so the
# step lists what's missing and asks once. When one part fails, the step still does the others,
# then fails. It also puts Homebrew on PATH for user services, and turns on a daily health alert
# and a boot notice pushed to ntfy, which need no sudo.
#
# A temp HOME doesn't isolate this step, which changes the system with sudo, systemctl, and
# loginctl. Test it in an Ubuntu VM that runs systemd, such as an OrbStack machine.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
UBUNTU_LIB_DIR="$DOTFILES_DIR/ubuntu/lib"
# shellcheck source=lib/ssh.sh
source "$UBUNTU_LIB_DIR/ssh.sh"
# shellcheck source=lib/firewall.sh
source "$UBUNTU_LIB_DIR/firewall.sh"
# shellcheck source=lib/health.sh
source "$UBUNTU_LIB_DIR/health.sh"
# shellcheck source=lib/power.sh
source "$UBUNTU_LIB_DIR/power.sh"
# shellcheck source=lib/updates.sh
source "$UBUNTU_LIB_DIR/updates.sh"
# shellcheck source=lib/tailscale.sh
source "$UBUNTU_LIB_DIR/tailscale.sh"
# shellcheck source=lib/alerts.sh
source "$UBUNTU_LIB_DIR/alerts.sh"
# shellcheck source=lib/ups.sh
source "$UBUNTU_LIB_DIR/ups.sh"
# SMARTD_HOOK, UPS_NOTIFY, and NTFY_URL_FILE
# shellcheck source=lib/paths.sh
source "$UBUNTU_LIB_DIR/paths.sh"

# Masking these stops every suspend, whether GNOME's idle timer, the login screen's, or a command
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)
# Sorts before 50-cloud-init.conf: sshd keeps the first value it reads for most settings
SSHD_DROP_IN=/etc/ssh/sshd_config.d/10-dotfiles.conf
# sshd -t and -T need this directory, which ssh.service creates, and Ubuntu only starts that
# service on the first connection
SSHD_RUN_DIR=/run/sshd
# openssh-server's daemon, outside the PATH of a user who isn't root
SSHD_BIN=/usr/sbin/sshd
# The unit that starts sshd at boot, 26.04's default. ssh.service, which it starts on the first
# connection, is the one that reloads sshd's config.
SSH_UNIT=ssh.socket
# The only dirs sbin_cmd looks in for a command such as ufw or smartctl: system dirs, since the
# result can run under sudo
SBIN_PATH=/usr/sbin:/usr/bin:/sbin:/bin
# Stops what masking can't: GNOME then hides suspend, and stops trying it on UPS battery
SLEEP_CONF=/etc/systemd/sleep.conf.d/10-dotfiles.conf
SLEEP_CONF_CONTENT='# From the dotfiles ubuntu step: never sleep, alongside the masked sleep targets
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no'
# Packages write this, and their names to .pkgs, when an update needs a reboot
REBOOT_REQUIRED=/var/run/reboot-required
# systemd keeps a file here for each user who lingers, whose user services start at boot
LINGER_DIR=/var/lib/systemd/linger
# The timers that download and install updates, which unattended-upgrades relies on
APT_TIMERS=(apt-daily.timer apt-daily-upgrade.timer)
SYSCTL_CONF=/etc/sysctl.d/90-dotfiles.conf
# Where sysctl --system reads settings from, to name the file that overrides one of the step's
SYSCTL_SOURCES=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /etc/sysctl.conf)
# The file watchers agents run in many worktrees (dev servers, editors, test watchers) each open
# inotify instances, so the default 128 instances run out before the watches do
SYSCTL_CONTENT='# From the dotfiles ubuntu step: reboot 10 seconds after a kernel panic
kernel.panic = 10
# Room for the file watchers agents run in many worktrees
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576'
# The unit smartmontools installs; smartd.service is its alias
SMARTD_UNIT=smartmontools.service
# smartd's warning hook, installed as $SMARTD_HOOK
SMARTD_HOOK_SRC="$DOTFILES_DIR/ubuntu/smartd-notify.sh"
# NUT, which watches a UPS on USB. nut-server ships the drivers, upsd, nut-scanner, the udev rules
# that name the UPSes it knows, and the system-shutdown hook that has the UPS cut its power when
# upsmon left POWERDOWNFLAG. nut-client ships upsmon and upsc.
NUT_PACKAGES=(nut-client nut-server)
NUT_UNITS=(nut-server.service nut-monitor.service)
NUT_DIR=/etc/nut
# The files the step writes in $NUT_DIR, all readable only by root and the nut group
NUT_FILES=(nut.conf ups.conf upsd.conf upsd.users upsmon.conf)
NUT_GROUP=nut
# upower's hwdb, whose UPOWER_BATTERY_TYPE=ups tag tells a UPS on USB (ups_plugged)
UPOWER_HWDB=/usr/lib/udev/hwdb.d/95-upower-hid.hwdb
# The UPS's name in ups.conf, as upsc ups@localhost reads it
UPS_NAME=ups
UPS_POWERDOWN_FLAG=/etc/killpower
# systemd-shutdown runs each executable here just before it powers off, and kills any still
# running after 90 s, so NUT's POWEROFF_WAIT can't wait long enough for a UPS that doesn't cut
# its output. This hook sets an RTC alarm instead (ups_rtc_hook).
UPS_RTC_HOOK=/usr/lib/systemd/system-shutdown/dotfiles-rtc-wake
# Minutes after a UPS shutdown the alarm starts the machine, if the UPS didn't cut its output
UPS_RTC_WAKE_MINUTES=15
# upsmon's NOTIFYCMD, installed as $UPS_NOTIFY
UPS_NOTIFY_SRC="$DOTFILES_DIR/ubuntu/ups-notify.sh"
# The ntfy code the UPS notifier and smartd's hook source
NTFY_LIB_SRC="$DOTFILES_DIR/ubuntu/lib/ntfy.sh"
NTFY_LIB=/usr/local/lib/dotfiles/ntfy.sh
# The health alerts' user units, which run ubuntu/health-alert.sh. The user manager doesn't see an
# XDG_CONFIG_HOME set in the shell, so they go in ~/.config.
HEALTH_UNIT_DIR="$HOME/.config/systemd/user"
HEALTH_UNITS=(dotfiles-health.service dotfiles-health.timer dotfiles-boot-notice.service)
# Where fwupd keeps each remote's metadata, whose age says how current its update list is
FWUPD_METADATA_DIRS="/var/lib/fwupd/metadata /var/cache/fwupd/metadata"
# The file unattended-upgrades' package writes, and the lines dpkg-reconfigure writes when it's on,
# which the step merges into it
AUTO_UPGRADES_CONF=/etc/apt/apt.conf.d/20auto-upgrades
AUTO_UPGRADES_CONTENT='APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
# unattended-upgrades skips an update that ships a new version of a conffile you edited, such as
# NUT's files in /etc/nut, since dpkg would ask which to keep. These options keep yours without
# asking, so the update installs.
KEEP_CONFFILES_CONF=/etc/apt/apt.conf.d/50dotfiles-keep-conffiles
KEEP_CONFFILES_CONTENT='// From the dotfiles ubuntu step: on an update that ships a new version of a conffile you
// edited, keep yours without asking, so unattended-upgrades installs it
Dpkg::Options {
    "--force-confdef";
    "--force-confold";
};'
# The private address ranges ufw lets SSH in from: RFC 1918's, IPv6's unique local addresses, and
# link-local ones. Fixed, so a new network or a rotated IPv6 prefix needs no new rules. RFC 1918's
# 172.16.0.0/12 is left out: Docker's bridges take their subnets from it (172.17.0.0/16 and up), so
# allowing it would let any container try logins on sshd.
SSH_RANGES=(10.0.0.0/8 192.168.0.0/16 fd00::/8 fe80::/10)
# ufw's settings, which anyone may read: whether it's on, and its default policy and IPv6 setting
UFW_CONF=/etc/ufw/ufw.conf
UFW_DEFAULTS=/etc/default/ufw
# Tailscale's port for direct connections. Without it, devices relay through DERP servers.
TAILSCALE_PORT=41641
TAILSCALE_REPO=https://pkgs.tailscale.com/stable/ubuntu
# The keyring path and source file Tailscale's install script uses. Tailscale's updater rewrites
# that file, so it has to stay a one-line .list rather than deb822.
TAILSCALE_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
TAILSCALE_LIST=/etc/apt/sources.list.d/tailscale.list
# User services, such as tmux at boot and the T3 Code server, get the user manager's PATH, which
# has neither Homebrew nor ~/.local/bin. The user manager doesn't see an XDG_CONFIG_HOME set in the
# shell, so the file goes in ~/.config.
HOMEBREW_ENV_SRC="$DOTFILES_DIR/ubuntu/environment.d/99-homebrew.conf"
HOMEBREW_ENV_CONF="$HOME/.config/environment.d/99-homebrew.conf"

# Pass each file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
ubuntu_files() {
    "$1" "$HOMEBREW_ENV_SRC" "$HOMEBREW_ENV_CONF"
}

# The same for the files the step installs as root. Nothing in the step calls it:
# scripts/check-docs.sh does, to check README "Maintenance" copies each one back.
ubuntu_root_files() {
    "$1" "$SMARTD_HOOK_SRC" "$SMARTD_HOOK"
    "$1" "$UPS_NOTIFY_SRC" "$UPS_NOTIFY"
    "$1" "$NTFY_LIB_SRC" "$NTFY_LIB"
}

# root_copy_current <src> <dest>: succeeds when a file installed as root is a copy of the repo's,
# executable when the repo's is
root_copy_current() {
    cmp -s "$1" "$2" && { [ ! -x "$1" ] || [ -x "$2" ]; }
}

# install_root_copy <src> <dest>: install a copy of the repo's file as root's, 755 when the repo's
# is executable and 644 otherwise, unless it's already current
install_root_copy() {
    local mode=0644
    [ ! -x "$1" ] || mode=0755
    root_copy_current "$1" "$2" || install_root_file "$1" "$2" "$mode"
}

# Add the step's simple sudo items, which status and apply drive by their check functions. The
# rest branch, so they stay in status and apply. Added at run time, since their texts name paths
# tests point elsewhere.
ubuntu_sudo_items() {
    sudo_items_reset
    sudo_item "Sleep masked" "Never sleep: mask ${SLEEP_TARGETS[*]}" sleep_masked mask_sleep
    sudo_item "Suspend and hibernation off in systemd ($SLEEP_CONF)" \
        "Turn off suspend and hibernation in systemd: write $SLEEP_CONF" sleep_conf_written write_sleep_conf
    sudo_item "Linger, so user services start at boot" \
        "Start your user services at boot, without a login: loginctl enable-linger" lingering enable_linger
    # status_smartd_hook reports it, skipped in a VM and out of date apart
    sudo_item "smartd's warnings pushed to ntfy ($SMARTD_HOOK)" "Push smartd's warnings to ntfy once a URL is set: install $SMARTD_HOOK and $NTFY_LIB" \
        smartd_hook_ready install_smartd_hook
    sudo_item "en_US.UTF-8 locale" "Add the en_US.UTF-8 locale that zsh sets LANG to: locale-gen en_US.UTF-8" \
        locale_installed install_locale
    sudo_item "unattended-upgrades runs daily" \
        "Install security updates daily: turn on unattended-upgrades in $AUTO_UPGRADES_CONF" \
        unattended_upgrades_running turn_on_unattended_upgrades
    sudo_item "Updates keep conffiles you edited, so unattended-upgrades doesn't skip them ($KEEP_CONFFILES_CONF)" \
        "Keep conffiles you edited through updates, so unattended-upgrades doesn't skip them: write $KEEP_CONFFILES_CONF" \
        keep_conffiles_written write_keep_conffiles
    # status says how to turn them on
    sudo_item "apt's daily timers enabled and running" "Turn on apt's daily timers: systemctl enable --now ${APT_TIMERS[*]}" \
        apt_timers_enabled enable_apt_timers
}

# status and apply run in_vm and key_login many times, some in subshells, so they declare
# IN_VM_CACHE, KEY_LOGIN_CACHE, and KEY_LOGIN_STATUS local and call this first to set them once
cache_checks() {
    local vm=no status=0
    ! in_vm || vm=yes
    KEY_LOGIN_CACHE="$(key_login)" || status=$?
    # Set last, since in_vm and key_login read them once set
    IN_VM_CACHE="$vm"
    KEY_LOGIN_STATUS="$status"
}

# Copy the environment.d file. When it changes, reload the user manager, which reads environment.d
# then, so services it starts from now on get the new PATH. Running ones keep theirs until they
# restart, which the step leaves to you.
configure_homebrew_env() {
    local changed=true
    ! cmp -s "$HOMEBREW_ENV_SRC" "$HOMEBREW_ENV_CONF" || changed=false
    ubuntu_files copy_file || return 1
    "$changed" || return 0
    if systemctl --user daemon-reload &>/dev/null; then
        echo "  User services started from now on get Homebrew on PATH. Running ones, such as tmux and"
        echo "  T3 Code, get it when they restart."
    else
        echo "  Couldn't reach your systemd user manager. User services get Homebrew on PATH"
        echo "  after the next reboot or login."
    fi
}

install_locale() {
    if ! apt_installed locales; then
        apt_get install -y locales || return 1
    fi
    sudo locale-gen en_US.UTF-8 > /dev/null
}

# Print the UUID and name of each NetworkManager connection of a type, tab-separated, one per
# line. Commands name a connection by UUID, since two can share a name. Extra arguments go to
# nmcli connection show, e.g. --active. -e no leaves a colon or backslash in a name unescaped, and
# the name is the rest of the line, since the UUID and type have neither.
# e.g. nm_connections 802-11-wireless --active
nm_connections() {
    local type="$1"
    shift
    command -v nmcli &>/dev/null || return 0
    nmcli -t -e no -f UUID,TYPE,NAME connection show "$@" 2>/dev/null |
        awk -F: -v type="$type" '$2 == type { print $1 "\t" substr($0, length($1) + length($2) + 3) }'
}

wired_connections() {
    nm_connections 802-3-ethernet
}

# Succeeds when this connection enables waking on a Wake-on-LAN magic packet
wake_on_lan_on() {
    [[ "$(nmcli -g 802-3-ethernet.wake-on-lan connection show uuid "$1" 2>/dev/null)" == *magic* ]]
}

lingering() {
    [ -e "$LINGER_DIR/$(id -un)" ]
}

enable_linger() {
    sudo loginctl enable-linger "$(id -un)"
}

# Never asks for sudo and writes nothing. What only root can read is checked with sudo -n when sudo
# credentials are cached, and is otherwise unverified.
status() {
    local uuid name wired=false item packages overrides
    local IN_VM_CACHE="" KEY_LOGIN_CACHE="" KEY_LOGIN_STATUS=""
    if ! is_ubuntu; then
        status_item skipped "Running around the clock: Ubuntu only"
        return 0
    fi
    cache_checks
    ubuntu_sudo_items
    sudo_items_status sleep_masked sleep_conf_written
    item="Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF)"
    if ! sysctl_file_written; then
        status_item missing "$item"
    elif ! sysctl_in_effect; then
        overrides="$(sysctl_overrides | join_lines '; ')"
        status_item missing "$item: written but not in effect (${overrides:+$overrides; change or remove them there, and }re-run the ubuntu step)"
    else
        status_item ok "$item"
    fi
    sudo_items_status lingering
    status_check "smartmontools, with smartd enabled at boot" smartd_enabled
    if in_vm; then
        status_item skipped "smartd running: this is a VM, whose host manages the disks"
    else
        status_check "smartd running (check a drive with sudo smartctl -a /dev/<disk>)" smartd_active
    fi
    status_smart
    status_smartd_hook
    status_health_alerts
    status_ups
    sudo_items_status locale_installed unattended_upgrades_running keep_conffiles_written
    status_held_back
    if apt_timers_enabled; then
        status_item ok "apt's daily timers enabled and running"
    else
        status_item missing "apt's daily timers enabled and running (run sudo systemctl enable --now ${APT_TIMERS[*]})"
    fi
    if [ -e "$REBOOT_REQUIRED" ]; then
        packages="$(reboot_packages)"
        status_item missing "Reboot pending for updates${packages:+: $packages}; reboot when no agent runs"
    else
        status_item ok "No reboot pending for updates"
    fi
    ubuntu_files status_file
    status_sshd
    if ! command -v tailscale &>/dev/null; then
        status_item missing "Tailscale"
    elif status_require_cmd jq "Tailscale's auto-update, operator, and connection"; then
        status_item ok "Tailscale"
        ! apt_installed tailscale ||
            status_apt_source Tailscale "$TAILSCALE_LIST" "$(tailscale_list_line)" ubuntu "$(tailscale_release_url)"
        status_check "Tailscale auto-updates, with $(id -un) as its operator" tailscale_configured
        if tailscale_running; then
            status_item ok "Tailscale connected"
        else
            status_item missing "Tailscale connected (run sudo tailscale up)"
        fi
    fi
    status_ufw
    if ! command -v nmcli &>/dev/null; then
        status_item skipped "Wake-on-LAN: NetworkManager (nmcli) isn't installed"
    else
        while IFS=$'\t' read -r uuid name; do
            wired=true
            status_check "Wake-on-LAN on \"$name\" (also needs the BIOS settings in the README)" wake_on_lan_on "$uuid"
        done < <(wired_connections)
        "$wired" || status_item skipped "Wake-on-LAN: no wired connection"
    fi
    status_disk_space / "$HOME" /var
    status_firmware
    status_result
}

apply() {
    echo "Setting up Ubuntu to run around the clock..."
    if ! is_ubuntu; then
        echo "  Not Ubuntu; skipping."
        return 0
    fi
    local pending=() wol_pending=()
    local ufw=0 result=0 uuid name wired=false tailscale_source="" tailscale_repo=false unchecked=""
    local IN_VM_CACHE="" KEY_LOGIN_CACHE="" KEY_LOGIN_STATUS="" UPS_STATE="" UPS_PLUGGED=""
    require_cmd jq || return 1
    # A release upgrade turns Tailscale's apt source off, and Tailscale's updates come from it. Its
    # updater reads only tailscale.list (aptSourcesFile in its clientupdate.go), so the step owns
    # that file. Its apt key is downloaded to install it or re-add its apt repo.
    if command -v tailscale &>/dev/null && apt_installed tailscale; then
        tailscale_source="$(apt_source_state "$TAILSCALE_LIST" "$(tailscale_list_line)")"
    fi
    if ! command -v tailscale &>/dev/null || [ -n "$tailscale_source" ]; then
        require_cmd curl || return 1
        ! apt_repo_published Tailscale "$(tailscale_release_url)" || tailscale_repo=true
    fi
    cache_checks
    ups_state
    ubuntu_sudo_items
    configure_homebrew_env || result=1
    configure_health_alerts || result=1

    sudo_items_pending sleep_masked sleep_conf_written
    if ! sysctl_file_written; then
        pending+=("Reboot 10 s after a kernel panic, and raise the inotify limits: write $SYSCTL_CONF")
    elif ! sysctl_in_effect; then
        pending+=("Put $SYSCTL_CONF in effect, which an earlier run wrote: sysctl --system")
    fi
    sudo_items_pending lingering
    if ! smartd_enabled; then
        pending+=("Watch disk health: enable smartd, installing smartmontools without its recommends")
    elif ! smartd_ready; then
        pending+=("Watch disk health: start smartd, which is enabled but not running")
    fi
    sudo_items_pending smartd_hook_ready
    local ups_todo
    ups_todo="$(UPS_STATE_CACHED=true ups_todo)"
    [ -z "$ups_todo" ] || pending+=("$ups_todo")
    sudo_items_pending locale_installed unattended_upgrades_running keep_conffiles_written apt_timers_enabled
    if ! apt_installed openssh-server; then
        pending+=("Install openssh-server")
    elif ! sshd_enabled; then
        pending+=("Start sshd at boot: systemctl enable --now $SSH_UNIT")
    fi
    # Unreadable, the drop-in may already turn them off, which configure_sshd keeps. Turning them
    # off is a change to the drop-in, so the item for it names why.
    local key_only_todo="" key_only_why="" drop_in_lines
    if key_only_todo="$(key_only_todo)" && [ -n "$key_only_todo" ] &&
        key_only_why="$(key_only_reason)"; then
        key_only_todo=""
    fi
    if ! sshd_configured; then
        drop_in_lines="$(sshd_drop_in | grep -v '^#' | tr '\n' ' ')"
        pending+=("Write $SSHD_DROP_IN${key_only_why:+, turning off SSH password logins since $key_only_why}: $drop_in_lines")
    fi
    if "$tailscale_repo" && ! command -v tailscale &>/dev/null; then
        pending+=("Install Tailscale from its apt repo: write $TAILSCALE_LIST and its key")
    elif "$tailscale_repo"; then
        pending+=("Rewrite Tailscale's apt source for $(ubuntu_codename) ($tailscale_source), which Tailscale updates from: write $TAILSCALE_LIST and its key")
    fi
    # A fresh install needs a login first, which a later run follows
    local tailscale_set=false
    if command -v tailscale &>/dev/null && ! tailscale_configured && ! tailscale_needs_login; then
        tailscale_set=true
        pending+=("Turn on Tailscale's auto-update and make $(id -un) its operator")
    fi
    # Checked now only when sudo credentials are cached. Otherwise the rules are unverified (2),
    # and asking for sudo only to read them isn't worth it.
    ufw_configured -n || ufw=$?
    if [ "$ufw" -eq 1 ]; then
        pending+=("Firewall: install and enable ufw, denying incoming connections except SSH from ${SSH_RANGES[*]}, anything on tailscale0, and Tailscale's $TAILSCALE_PORT/udp")
    elif [ "$ufw" -eq 2 ] && [ ${#pending[@]} -gt 0 ]; then
        pending+=("Check the ufw rules for SSH from the private ranges, tailscale0, and Tailscale's $TAILSCALE_PORT/udp, and add any that are missing")
    fi
    while IFS=$'\t' read -r uuid name; do
        wired=true
        wake_on_lan_on "$uuid" && continue
        wol_pending+=("$uuid")
        pending+=("Wake-on-LAN: set 802-3-ethernet.wake-on-lan to magic on \"$name\"")
    done < <(wired_connections)

    if [ ${#pending[@]} -eq 0 ]; then
        if [ "$ufw" -eq 0 ]; then
            echo "  Sleep, power, linger, smartd, the locale, updates, OpenSSH, Tailscale, and the firewall"
            echo "  are already set up."
        else
            unchecked="Its rules can't be checked without sudo; run sudo -v and re-run this step to check them."
            [ -d "$SSHD_RUN_DIR" ] ||
                unchecked="Its rules can't be checked until sshd has run, which the first SSH connection does."
            echo "  Sleep, power, linger, smartd, the locale, updates, OpenSSH, and Tailscale are already set up."
            echo "  ufw is on. $unchecked"
        fi
    elif confirm_sudo_changes "${pending[@]}"; then
        # Each part runs whether or not the one before it failed
        sudo_items_apply sleep_masked sleep_conf_written || result=1
        sysctl_written || apply_sysctl || result=1
        sudo_items_apply lingering || result=1
        smartd_ready || install_smartd || result=1
        sudo_items_apply smartd_hook_ready || result=1
        [ -z "$ups_todo" ] || setup_ups || result=1
        sudo_items_apply locale_installed unattended_upgrades_running keep_conffiles_written \
            apt_timers_enabled || result=1
        if ! apt_installed openssh-server; then
            apt_get install -y openssh-server || result=1
        fi
        # Installing the package enables sshd, so this catches one turned off since
        if apt_installed openssh-server && ! sshd_enabled; then
            sudo systemctl enable --now "$SSH_UNIT" || result=1
        fi
        sshd_configured || configure_sshd || result=1
        if "$tailscale_repo"; then
            if add_tailscale_repo; then
                command -v tailscale &>/dev/null || apt_get install -y tailscale || result=1
            else
                result=1
            fi
        fi
        if "$tailscale_set"; then
            sudo tailscale set --auto-update --operator="$(id -un)" || result=1
        fi
        # sudo is in use now, so the rules can be read
        if [ "$ufw" -ne 0 ]; then
            setup_ufw || result=1
        fi
        for uuid in ${wol_pending[@]+"${wol_pending[@]}"}; do
            sudo nmcli connection modify uuid "$uuid" 802-3-ethernet.wake-on-lan magic || result=1
        done
        if [ ${#wol_pending[@]} -gt 0 ]; then
            echo "  Wake-on-LAN applies the next time the connection comes up. It also needs the BIOS settings"
            echo "  in the README's Manual steps: Wake-on-LAN on, and ErP/EuP off."
        fi
        if [ "$result" -eq 0 ]; then
            echo "  Applied."
        else
            echo "  Applied the rest. Some changes failed; see the errors above." >&2
        fi
    fi
    if command -v nmcli &>/dev/null && ! "$wired"; then
        echo "  No wired connection, so Wake-on-LAN is left off. It works only over Ethernet."
    fi
    if [ -n "$key_only_todo" ]; then
        echo "  Password logins stay on: ${key_only_todo%%. Copy*}. Copy your key over (ssh-copy-id <alias>"
        echo "  from the Mac, with the alias just ssh-host added, or this machine's LAN IP before Tailscale"
        echo "  is up), SSH in with it, and re-run the step."
    fi

    # Signing in to Tailscale opens a link, so it's yours to do. SSH goes through OpenSSH on the
    # tailnet address: Tailscale SSH (--ssh) drops every session when tailscaled restarts, which
    # auto-update does.
    if command -v tailscale &>/dev/null && ! tailscale_running; then
        echo "  Tailscale isn't connected. Run sudo tailscale up, then bash setup.sh ubuntu to persist"
        echo "  auto-update and operator settings after login. Turn off key expiry for this machine in"
        echo "  the Tailscale admin console, so it doesn't drop off the tailnet after 180 days."
    fi
    # ups_todo is set only for a plugged-in UPS, which warn_no_ups doesn't report
    [ -n "$ups_todo" ] || UPS_STATE_CACHED=true warn_no_ups
    warn_wifi_needs_login
    warn_disk_encryption
    return "$result"
}

# NetworkManager only brings up a Wi-Fi connection limited to your user, or whose password is in
# your login keyring, once you log in, so after a reboot the machine stays offline. nmcli prints
# psk-flags as e.g. "3 (agent-owned, not-saved)"; flag 1 (agent-owned) or 2 (not-saved) means the
# system doesn't keep the password.
warn_wifi_needs_login() {
    local uuid name permissions psk_flags n
    while IFS=$'\t' read -r uuid name; do
        permissions="$(nmcli -g connection.permissions connection show uuid "$uuid" 2>/dev/null)"
        psk_flags="$(nmcli -g 802-11-wireless-security.psk-flags connection show uuid "$uuid" 2>/dev/null)"
        n="${psk_flags%% *}"
        case "$n" in '' | *[!0-9]*) n=0 ;; esac
        if [ -n "$permissions" ] || (((n & 3) != 0)); then
            echo "  Wi-Fi \"$name\" only connects after you log in. Use Ethernet, or make it connect at boot."
            echo "  Run these at the machine, not over this Wi-Fi: the second reconnects it, asks for the"
            echo "  password, and saves it."
            echo "    sudo nmcli connection modify uuid $uuid connection.permissions \"\" 802-11-wireless-security.psk-flags 0"
            echo "    sudo nmcli --ask connection up uuid $uuid"
        fi
    done < <(nm_connections 802-11-wireless --active)
}

# A disk that asks for a passphrase at boot can't come back on its own after a power cut or reboot.
# Warns when a disk is unlocked and a LUKS partition lacks the ubuntu-<role>-enc label snapd gives
# TPM-backed encryption (as fwupd also relies on), as with the installer's encryption without TPM.
# TPM-backed encryption that also asks for a PIN gets no warning: only snapd's API tells it apart.
# Neither does a disk bound to the TPM with systemd-cryptenroll, which keeps its label, so a
# tpm2-device option in crypttab counts as bound.
CRYPTTAB=/etc/crypttab
warn_disk_encryption() {
    lsblk -rno TYPE 2>/dev/null | grep -qx crypt || return 0
    lsblk -rno FSTYPE,LABEL 2>/dev/null |
        awk '$1 == "crypto_LUKS" && $2 !~ /^ubuntu-.*-enc$/ { found = 1 } END { exit !found }' || return 0
    ! grep -qE '^[^#]*tpm2-device=' "$CRYPTTAB" 2>/dev/null || return 0
    echo "  The disk is encrypted with a passphrase. Every boot waits for it at the console, so the"
    echo "  machine can't come back by itself after a power cut. Reinstalling with TPM-backed"
    echo "  encryption, or binding the disk to the TPM (systemd-cryptenroll), avoids it."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
