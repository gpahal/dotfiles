#!/bin/bash
set -euo pipefail

# Set Ubuntu up to run unattended around the clock.
# A temp HOME doesn't isolate this step (sudo, systemctl, loginctl). Test it in an Ubuntu VM with
# systemd, such as an OrbStack machine.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/system.sh"
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
# shellcheck source=lib/paths.sh
source "$UBUNTU_LIB_DIR/paths.sh"
# shellcheck source=lib/services.sh
source "$UBUNTU_LIB_DIR/services.sh"

STEP_OS=ubuntu
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)
# Sorts before 50-cloud-init.conf: sshd keeps the first value it reads
SSHD_DROP_IN=/etc/ssh/sshd_config.d/10-dotfiles.conf
SSHD_CONFIG=/etc/ssh/sshd_config
# sshd -t and -T need it; ssh.service creates it only on the first connection
SSHD_RUN_DIR=/run/sshd
SSHD_BIN=/usr/sbin/sshd
# ssh.service, which this starts on the first connection, is the one that reloads sshd's config
SSH_UNIT=ssh.socket
# System dirs only, since sbin_cmd's result can run under sudo
SBIN_PATH=/usr/sbin:/usr/bin:/sbin:/bin
# Masking alone doesn't stop GNOME offering suspend or trying it on UPS battery
SLEEP_CONF=/etc/systemd/sleep.conf.d/10-dotfiles.conf
SLEEP_CONF_CONTENT='# From the dotfiles ubuntu step: never sleep, alongside the masked sleep targets
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no'
REBOOT_REQUIRED=/var/run/reboot-required
LINGER_DIR=/var/lib/systemd/linger
APT_TIMERS=(apt-daily.timer apt-daily-upgrade.timer)
SYSCTL_CONF=/etc/sysctl.d/90-dotfiles.conf
SYSCTL_SOURCES=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /etc/sysctl.conf)
# Agents' file watchers in many worktrees run out of the default 128 inotify instances
SYSCTL_CONTENT='# From the dotfiles ubuntu step: reboot 10 seconds after a kernel panic
kernel.panic = 10
# Room for the file watchers agents run in many worktrees
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576'
# smartd.service is an alias
SMARTD_UNIT=smartmontools.service
SMARTD_HOOK_SRC="$DOTFILES_DIR/ubuntu/smartd-notify.sh"
SMARTD_CONF=/etc/smartd.conf
# nut-server also ships the udev rules and the system-shutdown hook that cuts UPS power
NUT_PACKAGES=(nut-client nut-server)
NUT_UNITS=(nut-server.service nut-monitor.service)
NUT_DIR=/etc/nut
NUT_FILES=(nut.conf ups.conf upsd.conf upsd.users upsmon.conf)
NUT_OWNER=root
NUT_GROUP=nut
UPOWER_HWDB=/usr/lib/udev/hwdb.d/95-upower-hid.hwdb
UPS_NAME=ups
UPS_POWERDOWN_FLAG=/etc/killpower
# systemd-shutdown kills hooks after 90 s, too soon for NUT's POWEROFF_WAIT, so this sets an RTC
# alarm instead
UPS_RTC_HOOK=/usr/lib/systemd/system-shutdown/dotfiles-rtc-wake
UPS_RTC_WAKE_MINUTES=15
UPS_NOTIFY_SRC="$DOTFILES_DIR/ubuntu/ups-notify.sh"
NTFY_LIB_SRC="$DOTFILES_DIR/ubuntu/lib/ntfy.sh"
NTFY_LIB=/usr/local/lib/dotfiles/ntfy.sh
# Not XDG_CONFIG_HOME: the user manager doesn't see the shell's
HEALTH_UNIT_DIR="$HOME/.config/systemd/user"
HEALTH_UNITS=(dotfiles-health.service dotfiles-health.timer dotfiles-boot-notice.service)
FWUPD_METADATA_DIRS="/var/lib/fwupd/metadata /var/cache/fwupd/metadata"
AUTO_UPGRADES_CONF=/etc/apt/apt.conf.d/20auto-upgrades
AUTO_UPGRADES_CONTENT='APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
# Without these, unattended-upgrades skips an update that ships a conffile you edited
KEEP_CONFFILES_CONF=/etc/apt/apt.conf.d/50dotfiles-keep-conffiles
KEEP_CONFFILES_CONTENT='// From the dotfiles ubuntu step: on an update that ships a new version of a conffile you
// edited, keep yours without asking, so unattended-upgrades installs it
Dpkg::Options {
    "--force-confdef";
    "--force-confold";
};'
# 172.16.0.0/12 is left out: Docker's address pools live there, so containers could try SSH logins
SSH_RANGES=(10.0.0.0/8 192.168.0.0/16 fd00::/8 fe80::/10)
TAILNET_RANGE=100.64.0.0/10
# Denied SSH ahead of the allows: a network with an explicit subnet or IPv6 can use $SSH_RANGES.
# Custom-named bridges and docker_gwbridge aren't covered.
DOCKER_BRIDGES=(docker0 br-+)
# World-readable, unlike the rules
UFW_CONF=/etc/ufw/ufw.conf
UFW_DEFAULTS=/etc/default/ufw
# Without it, devices relay through DERP
TAILSCALE_PORT=41641
TAILSCALE_REPO=https://pkgs.tailscale.com/stable/ubuntu
# Tailscale's updater rewrites the .list, so it can't be deb822
TAILSCALE_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
TAILSCALE_LIST=/etc/apt/sources.list.d/tailscale.list
HOMEBREW_ENV_SRC="$DOTFILES_DIR/ubuntu/environment.d/99-homebrew.conf"
HOMEBREW_ENV_CONF="$HOME/.config/environment.d/99-homebrew.conf"
CRYPTTAB=/etc/crypttab
# Sorts after Ubuntu's default-wifi-powersave-on.conf, which turns it on, so NetworkManager reads it last
WIFI_POWERSAVE_CONF=/etc/NetworkManager/conf.d/dotfiles-wifi-powersave-off.conf
WIFI_POWERSAVE_CONTENT='# From the dotfiles ubuntu step: Wi-Fi power save off (2). With it on, the access point holds
# packets until the radio wakes, which makes SSH lag.
[connection]
wifi.powersave = 2'
CLOUD_INIT_DISABLED=/etc/cloud/cloud-init.disabled
CLOUD_INIT_DISABLED_CONTENT='# From the dotfiles ubuntu step: cloud-init only sets up a fresh install, so it stays off at boot'
CUPS_BROWSED_UNIT=cups-browsed.service

ubuntu_files() {
    "$1" "$HOMEBREW_ENV_SRC" "$HOMEBREW_ENV_CONF"
}

# Only scripts/copy-back.sh calls it
ubuntu_root_files() {
    "$1" "$SMARTD_HOOK_SRC" "$SMARTD_HOOK"
    "$1" "$UPS_NOTIFY_SRC" "$UPS_NOTIFY"
    "$1" "$NTFY_LIB_SRC" "$NTFY_LIB"
}

# root_copy_current <src> <dest> <mode>. The mode is fixed, not the repo file's, since a checkout
# can lose exec bits and run-parts skips a non-executable hook.
root_copy_current() {
    cmp -s "$1" "$2" && { [ "$3" != 0755 ] || [ -x "$2" ]; }
}

install_root_copy() {
    root_copy_current "$@" || install_root_file "$@"
}

# Installed outside the repo, since the UPS notifier runs as nut, who may not be able to read it
ntfy_lib_installed() {
    root_copy_current "$NTFY_LIB_SRC" "$NTFY_LIB" 0644
}

install_ntfy_lib() {
    install_root_copy "$NTFY_LIB_SRC" "$NTFY_LIB" 0644
}

ubuntu_items() {
    items_reset
    item --sudo "Sleep masked" "Never sleep: mask ${SLEEP_TARGETS[*]}" sleep_masked mask_sleep
    item --sudo "Suspend and hibernation off in systemd ($SLEEP_CONF)" \
        "Turn off suspend and hibernation in systemd: write $SLEEP_CONF" sleep_conf_written write_sleep_conf
    item --sudo "Linger, so user services start at boot" \
        "Start your user services at boot, without a login: loginctl enable-linger" lingering enable_linger
    item --sudo "smartd's warnings pushed to ntfy ($SMARTD_HOOK)" "Push smartd's warnings to ntfy once a URL is set: install $SMARTD_HOOK and $NTFY_LIB" \
        smartd_hook_ready install_smartd_hook
    item --sudo "en_US.UTF-8 locale" "Add the en_US.UTF-8 locale that zsh sets LANG to: locale-gen en_US.UTF-8" \
        locale_installed install_locale
    item --sudo "unattended-upgrades runs daily" \
        "Install security updates daily: turn on unattended-upgrades in $AUTO_UPGRADES_CONF" \
        unattended_upgrades_running turn_on_unattended_upgrades
    item --sudo "Updates keep conffiles you edited, so unattended-upgrades doesn't skip them ($KEEP_CONFFILES_CONF)" \
        "Keep conffiles you edited through updates, so unattended-upgrades doesn't skip them: write $KEEP_CONFFILES_CONF" \
        keep_conffiles_written write_keep_conffiles
    item --sudo --hint "run sudo systemctl enable --now ${APT_TIMERS[*]}" "apt's daily timers enabled and running" \
        "Turn on apt's daily timers: systemctl enable --now ${APT_TIMERS[*]}" apt_timers_enabled enable_apt_timers
    item --sudo "openssh-server" "Install openssh-server" openssh_installed install_openssh
    in_vm || item --sudo "cloud-init off, since it only sets up a fresh install ($CLOUD_INIT_DISABLED)" \
        "Turn off cloud-init, which only sets up a fresh install: write $CLOUD_INIT_DISABLED" cloud_init_off turn_off_cloud_init
    item --sudo "cups-browsed masked, so network printers aren't added by themselves" \
        "Mask cups-browsed, which adds network printers by itself; cups still prints" cups_browsed_off mask_cups_browsed
    ! command -v nmcli &>/dev/null ||
        item --sudo "Wi-Fi power save off, so SSH over Wi-Fi doesn't lag ($WIFI_POWERSAVE_CONF)" \
            "Turn off Wi-Fi power save, which makes SSH over Wi-Fi lag: write $WIFI_POWERSAVE_CONF" \
            wifi_powersave_off turn_off_wifi_powersave
    # Driven only once openssh-server is installed
    item --sudo --hint "run sudo systemctl enable --now $SSH_UNIT" "sshd starts at boot" \
        "Start sshd at boot: systemctl enable --now $SSH_UNIT" sshd_enabled enable_sshd
}

# Callers declare the *_CACHE vars local first; the checks run many times, some in subshells
cache_checks() {
    local vm=no status=0 cached=no
    ! in_vm || vm=yes
    KEY_LOGIN_CACHE="$(key_login)" || status=$?
    ! sudo_cached || cached=yes
    # Set last, since the checks above read them once set
    IN_VM_CACHE="$vm"
    KEY_LOGIN_STATUS="$status"
    SUDO_CACHED_CACHE="$cached"
}

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

# nm_connections <type> [nmcli args]: prints "UUID\tname" per line. UUID, since names can repeat.
# -e no leaves the name unescaped; it's the rest of the line, as UUID and type have no colons.
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

wake_on_lan_on() {
    [[ "$(nmcli -g 802-3-ethernet.wake-on-lan connection show uuid "$1" 2>/dev/null)" == *magic* ]]
}

lingering() {
    [ -e "$LINGER_DIR/$(id -un)" ]
}

enable_linger() {
    sudo loginctl enable-linger "$(id -un)"
}

# Root-only state is checked with sudo -n when credentials are cached, else left unverified
status() {
    local uuid name wired=false item packages overrides
    local IN_VM_CACHE="" KEY_LOGIN_CACHE="" KEY_LOGIN_STATUS="" SUDO_CACHED_CACHE=""
    cache_checks
    ubuntu_items
    items_status sleep_masked sleep_conf_written
    item="Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF)"
    if ! sysctl_file_written; then
        status_item missing "$item"
    elif ! sysctl_in_effect; then
        overrides="$(sysctl_overrides | join_lines '; ')"
        status_item missing "$item: written but not in effect (${overrides:+$overrides; change or remove them there, and }re-run the ubuntu step)"
    else
        status_item ok "$item"
    fi
    items_status lingering
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
    items_status locale_installed
    status_unattended_upgrades
    items_status keep_conffiles_written
    status_held_back
    items_status apt_timers_enabled cloud_init_off cups_browsed_off
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
        items_status wifi_powersave_off
        while IFS=$'\t' read -r uuid name; do
            status_check "Wi-Fi \"$name\" connects at boot, without a login (bash setup.sh ubuntu says how)" \
                wifi_connects_at_boot "$uuid"
        done < <(nm_connections 802-11-wireless --active)
    fi
    # info, since a passphrase is often chosen on purpose and only a reinstall or TPM binding changes it
    ! disk_needs_passphrase ||
        status_item info "Disk encrypted with a passphrase, so every boot waits for it at the console (bash setup.sh ubuntu says how to avoid it)"
    status_disk_space / "$HOME" /var
    status_firmware
    status_result
}

apply() {
    echo "Setting up Ubuntu to run around the clock..."
    local pending=() wol_pending=()
    local ufw=0 result=0 uuid name wired=false tailscale_source="" tailscale_repo=false ufw_todo=""
    local IN_VM_CACHE="" KEY_LOGIN_CACHE="" KEY_LOGIN_STATUS="" SUDO_CACHED_CACHE="" UPS_STATE="" UPS_PLUGGED=""
    require_cmd jq || return 1
    # A release upgrade turns Tailscale's apt source off, and its updater reads only tailscale.list
    if command -v tailscale &>/dev/null && apt_installed tailscale; then
        tailscale_source="$(apt_source_state "$TAILSCALE_LIST" "$(tailscale_list_line)")"
    fi
    if ! command -v tailscale &>/dev/null || [ -n "$tailscale_source" ]; then
        require_cmd curl || return 1
        # add_apt_repo needs it, after other changes
        require_cmd gpg || return 1
        ! apt_repo_published Tailscale "$(tailscale_release_url)" || tailscale_repo=true
    fi
    cache_checks
    ups_state
    ubuntu_items
    configure_homebrew_env || result=1
    configure_health_alerts || result=1

    items_pending sleep_masked sleep_conf_written
    if ! sysctl_file_written; then
        pending+=("Reboot 10 s after a kernel panic, and raise the inotify limits: write $SYSCTL_CONF")
    elif ! sysctl_in_effect; then
        pending+=("Put $SYSCTL_CONF in effect, which an earlier run wrote: sysctl --system")
    fi
    items_pending lingering
    if ! smartd_enabled; then
        pending+=("Watch disk health: enable smartd, installing smartmontools without its recommends")
    elif ! smartd_ready; then
        pending+=("Watch disk health: start smartd, which is enabled but not running")
    fi
    items_pending smartd_hook_ready
    local ups_todo
    ups_todo="$(UPS_STATE_CACHED=true ups_todo)"
    [ -z "$ups_todo" ] || pending+=("$ups_todo")
    # Root-only: checked with sudo only when other changes need it
    local auto_upgrades_unchecked=false
    items_pending locale_installed
    if auto_upgrades_unreadable && ! sudo_ready; then
        auto_upgrades_unchecked=true
    else
        items_pending unattended_upgrades_running
    fi
    items_pending keep_conffiles_written apt_timers_enabled openssh_installed cloud_init_off cups_browsed_off \
        wifi_powersave_off
    ! openssh_installed || items_pending sshd_enabled
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
    # A fresh install needs a login first
    local tailscale_set=false
    if command -v tailscale &>/dev/null && ! tailscale_configured && ! tailscale_needs_login; then
        tailscale_set=true
        pending+=("Turn on Tailscale's auto-update and make $(id -un) its operator")
    fi
    # 2: unverified without cached sudo; not worth asking for sudo just to read
    ufw_configured -n || ufw=$?
    if [ "$ufw" -eq 1 ] && ufw_enabled && ! ufw_stopped -n; then
        ufw_todo="add the missing ufw rules"
    elif [ "$ufw" -eq 1 ]; then
        ufw_todo="install and turn on ufw"
    elif [ "$ufw" -eq 2 ] && [ ${#pending[@]} -gt 0 ]; then
        ufw_todo="check the ufw rules, and add any that are missing"
    fi
    [ -z "$ufw_todo" ] ||
        pending+=("Firewall: $ufw_todo, so ufw denies incoming connections but SSH from ${SSH_RANGES[*]}, anything on tailscale0, and Tailscale's $TAILSCALE_PORT/udp, and denies SSH on Docker's bridges")
    while IFS=$'\t' read -r uuid name; do
        wired=true
        wake_on_lan_on "$uuid" && continue
        wol_pending+=("$uuid")
        pending+=("Wake-on-LAN: set 802-3-ethernet.wake-on-lan to magic on \"$name\"")
    done < <(wired_connections)
    ! "$auto_upgrades_unchecked" || [ ${#pending[@]} -eq 0 ] ||
        pending+=("Check unattended-upgrades' settings in $AUTO_UPGRADES_CONF, which only root can read, and turn it on there if it's off")

    if [ ${#pending[@]} -eq 0 ]; then
        echo "  Everything it can check is already set up."
        if [ "$ufw" -ne 0 ] && [ -d "$SSHD_RUN_DIR" ] && sudo_ready; then
            echo "  ufw is on, but its rules couldn't be checked: sudo ufw status or sudo sshd -T fails."
        elif [ "$ufw" -ne 0 ] && [ -d "$SSHD_RUN_DIR" ]; then
            echo "  ufw is on. Its rules can't be checked without sudo; run sudo -v and re-run this step to check them."
        elif [ "$ufw" -ne 0 ]; then
            echo "  ufw is on. Its rules can't be checked until sshd has run, which the first SSH connection does."
        fi
        ! "$auto_upgrades_unchecked" ||
            echo "  Only root can read $AUTO_UPGRADES_CONF; run sudo -v and re-run this step to check unattended-upgrades."
    elif confirm_sudo_changes "${pending[@]}"; then
        items_apply sleep_masked sleep_conf_written || result=1
        sysctl_written || apply_sysctl || result=1
        items_apply lingering || result=1
        smartd_ready || install_smartd || result=1
        items_apply smartd_hook_ready || result=1
        [ -z "$ups_todo" ] || setup_ups || result=1
        items_apply locale_installed unattended_upgrades_running keep_conffiles_written \
            apt_timers_enabled openssh_installed cloud_init_off cups_browsed_off wifi_powersave_off || result=1
        ! openssh_installed || items_apply sshd_enabled || result=1
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
        if [ "$ufw" -ne 0 ]; then
            ensure_sshd_run_dir && { ufw_configured || configure_ufw; } || result=1
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
    [ -z "$key_only_todo" ] || echo "  Password logins stay on: $key_only_todo."

    # Not Tailscale SSH (--ssh): it drops every session when auto-update restarts tailscaled
    if command -v tailscale &>/dev/null && ! tailscale_running; then
        echo "  Tailscale isn't connected. Run sudo tailscale up, then bash setup.sh ubuntu to persist"
        echo "  auto-update and operator settings after login. Turn off key expiry for this machine in"
        echo "  the Tailscale admin console, so it doesn't drop off the tailnet after 180 days."
    fi
    [ -n "$ups_todo" ] || UPS_STATE_CACHED=true warn_no_ups
    warn_wifi_needs_login
    warn_disk_encryption
    return "$result"
}

wifi_devices() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" { print $1 }'
}

# The value NetworkManager reads, so a drop-in sorting later that turns it back on shows up
wifi_powersave_off() {
    local nm
    file_is "$WIFI_POWERSAVE_CONF" "$WIFI_POWERSAVE_CONTENT" && nm="$(sbin_cmd NetworkManager)" || return 1
    [ "$("$nm" --print-config 2>/dev/null |
        awk -F= '/^\[/ { section = $0 } section == "[connection]" && $1 == "wifi.powersave" { v = $2 } END { print v }')" == 2 ]
}

# NetworkManager applies the drop-in when Wi-Fi next connects; iw turns it off now, without
# dropping an SSH session over Wi-Fi
turn_off_wifi_powersave() {
    local iw dev
    write_root_file "$WIFI_POWERSAVE_CONF" "$WIFI_POWERSAVE_CONTENT" && sudo nmcli general reload conf || return 1
    if ! iw="$(sbin_cmd iw)"; then
        echo "  Wi-Fi power save goes off when Wi-Fi next connects; install iw to turn it off now."
        return 0
    fi
    for dev in $(wifi_devices); do
        sudo "$iw" dev "$dev" set power_save off || return 1
    done
}

# A user-limited connection, or psk-flags 1 or 2 (password not kept by the system), waits for a
# login, so the machine stays offline after a reboot
wifi_connects_at_boot() {
    local permissions psk_flags n
    permissions="$(nmcli -g connection.permissions connection show uuid "$1" 2>/dev/null)"
    psk_flags="$(nmcli -g 802-11-wireless-security.psk-flags connection show uuid "$1" 2>/dev/null)"
    n="${psk_flags%% *}"
    case "$n" in '' | *[!0-9]*) n=0 ;; esac
    [ -z "$permissions" ] && (((n & 3) == 0))
}

warn_wifi_needs_login() {
    local uuid name
    while IFS=$'\t' read -r uuid name; do
        wifi_connects_at_boot "$uuid" && continue
        echo "  Wi-Fi \"$name\" only connects after you log in. Use Ethernet, or make it connect at boot."
        echo "  Run these at the machine, not over this Wi-Fi: the second reconnects it, asks for the"
        echo "  password, and saves it."
        echo "    sudo nmcli connection modify uuid $uuid connection.permissions \"\" 802-11-wireless-security.psk-flags 0"
        echo "    sudo nmcli --ask connection up uuid $uuid"
    done < <(nm_connections 802-11-wireless --active)
}

# snapd labels TPM-backed LUKS ubuntu-<role>-enc; systemd-cryptenroll keeps the label, so a
# crypttab tpm2-device option also counts. TPM+PIN can't be told apart and isn't warned about.
disk_needs_passphrase() {
    lsblk -rno TYPE 2>/dev/null | grep -qx crypt || return 1
    lsblk -rno FSTYPE,LABEL 2>/dev/null |
        awk '$1 == "crypto_LUKS" && $2 !~ /^ubuntu-.*-enc$/ { found = 1 } END { exit !found }' || return 1
    ! grep -qE '^[^#]*tpm2-device=' "$CRYPTTAB" 2>/dev/null
}

warn_disk_encryption() {
    disk_needs_passphrase || return 0
    echo "  The disk is encrypted with a passphrase. Every boot waits for it at the console, so the"
    echo "  machine can't come back by itself after a power cut. Reinstalling with TPM-backed"
    echo "  encryption, or binding the disk to the TPM (systemd-cryptenroll), avoids it."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
