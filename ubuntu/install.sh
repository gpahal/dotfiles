#!/bin/bash
set -euo pipefail

# Set Ubuntu up to run unattended around the clock.
# A temp HOME doesn't isolate this step (sudo, systemctl, loginctl). Test it in an Ubuntu VM with
# systemd, such as an OrbStack machine.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=../lib/systemd.sh
source "$DOTFILES_DIR/lib/systemd.sh"
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
# shellcheck source=../lib/checkout.sh
source "$DOTFILES_DIR/lib/checkout.sh"
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
# Masking alone doesn't stop GNOME offering suspend or trying it on UPS battery
SLEEP_CONF=/etc/systemd/sleep.conf.d/10-dotfiles.conf
SLEEP_CONF_CONTENT='# From the dotfiles ubuntu step: never sleep, alongside the masked sleep targets
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no'
REBOOT_REQUIRED=/var/run/reboot-required
APT_TIMERS=(apt-daily.timer apt-daily-upgrade.timer)
SYSCTL_CONF=/etc/sysctl.d/90-dotfiles.conf
SYSCTL_SOURCES=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /etc/sysctl.conf)
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
# Not XDG_DATA_HOME either: the units run the script from %h/.local/share
HEALTH_ALERT_DIR="$HOME/.local/share/dotfiles/health-alert"
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
# Denied SSH ahead of the allows: a network with an explicit subnet or IPv6 can use $SSH_RANGES.
# Custom-named bridges and docker_gwbridge aren't covered.
DOCKER_BRIDGES=(docker0 br-+)
# World-readable, unlike the rules
UFW_CONF=/etc/ufw/ufw.conf
UFW_DEFAULTS=/etc/default/ufw
# Without it, devices relay through DERP
TAILSCALE_PORT=41641
TAILSCALE_REPO=https://pkgs.tailscale.com/stable/ubuntu
TAILSCALE_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
# Tailscale's updater rewrites the .list, so it can't be deb822
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
# shellcheck disable=SC2034 # write_root_content reads it
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

# Installed outside the repo, since the UPS notifier runs as nut, who may not be able to read it
ntfy_lib_installed() {
    root_copy_current "$NTFY_LIB_SRC" "$NTFY_LIB" 0644
}

install_ntfy_lib() {
    install_root_copy "$NTFY_LIB_SRC" "$NTFY_LIB" 0644
}

# Status reports the items by check, beside what it checks itself. With apply, this also declares
# what only apply drives, in the order apply lists and fixes them, from apply's locals (ufw,
# tailscale_repo, tailscale_source, and auto_upgrades_unchecked). What's unknown without sudo is
# checked for real only once sudo_confirmed: before that, its checks read the driver's pending list
# so far, so it's listed only beside other changes.
ubuntu_items() {
    local apply=false text why="" wol="" uuid name
    [ "${1:-}" != apply ] || apply=true
    items_reset
    item --sudo "Sleep masked" "Never sleep: mask ${SLEEP_TARGETS[*]}" sleep_masked mask_sleep
    item --sudo "Suspend and hibernation off in systemd ($SLEEP_CONF)" \
        "Turn off suspend and hibernation in systemd: write $SLEEP_CONF" \
        sleep_conf_written "write_root_content SLEEP_CONF SLEEP_CONF_CONTENT"
    text="Reboot 10 s after a kernel panic, and raise the inotify limits: write $SYSCTL_CONF"
    ! sysctl_file_written || text="Put $SYSCTL_CONF in effect, which an earlier run wrote: sysctl --system"
    item --sudo "Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF)" \
        "$text" sysctl_written apply_sysctl
    item --sudo "Linger, so user services start at boot" \
        "Start your user services at boot, without a login: loginctl enable-linger" lingering enable_linger
    if "$apply"; then
        text="Watch disk health: enable smartd, installing smartmontools without its recommends"
        ! smartd_enabled || text="Watch disk health: start smartd, which is enabled but not running"
        item --sudo "" "$text" smartd_ready install_smartd
    fi
    item --sudo "smartd's warnings pushed to ntfy ($SMARTD_HOOK)" "Push smartd's warnings to ntfy once just alerts has run: install $SMARTD_HOOK and $NTFY_LIB" \
        smartd_hook_ready install_smartd_hook
    if "$apply"; then
        text="$(ups_todo)"
        [ -z "$text" ] || item --sudo "" "$text" false setup_ups
    fi
    item --sudo "en_US.UTF-8 locale" "Add the en_US.UTF-8 locale that zsh sets LANG to: locale-gen en_US.UTF-8" \
        locale_installed install_locale
    item --sudo "unattended-upgrades runs daily" \
        "Install security updates daily: turn on unattended-upgrades in $AUTO_UPGRADES_CONF" \
        "unattended_upgrades_checked ${auto_upgrades_unchecked:-false}" turn_on_unattended_upgrades
    item --sudo "Updates keep conffiles you edited, so unattended-upgrades doesn't skip them ($KEEP_CONFFILES_CONF)" \
        "Keep conffiles you edited through updates, so unattended-upgrades doesn't skip them: write $KEEP_CONFFILES_CONF" \
        keep_conffiles_written "write_root_content KEEP_CONFFILES_CONF KEEP_CONFFILES_CONTENT"
    item --sudo --hint "run sudo systemctl enable --now ${APT_TIMERS[*]}" "apt's daily timers enabled and running" \
        "Turn on apt's daily timers: systemctl enable --now ${APT_TIMERS[*]}" apt_timers_enabled "enable_units_now ${APT_TIMERS[*]}"
    item --sudo "openssh-server" "Install openssh-server" openssh_installed install_openssh
    # Skipped in a VM, which may need cloud-init at every boot for its network and users
    in_vm || item --sudo "cloud-init off, since it only sets up a fresh install ($CLOUD_INIT_DISABLED)" \
        "Turn off cloud-init, which only sets up a fresh install: write $CLOUD_INIT_DISABLED" cloud_init_off \
        "write_root_content CLOUD_INIT_DISABLED CLOUD_INIT_DISABLED_CONTENT"
    item --sudo "cups-browsed masked, so network printers aren't added by themselves" \
        "Mask cups-browsed, which adds network printers by itself; cups still prints" cups_browsed_off mask_cups_browsed
    ! command -v nmcli &>/dev/null ||
        item --sudo "Wi-Fi power save off, so SSH over Wi-Fi doesn't lag ($WIFI_POWERSAVE_CONF)" \
            "Turn off Wi-Fi power save, which makes SSH over Wi-Fi lag: write $WIFI_POWERSAVE_CONF" \
            wifi_powersave_off turn_off_wifi_powersave
    item --sudo --hint "run sudo systemctl enable --now $SSH_UNIT" "sshd starts at boot" \
        "Start sshd at boot: systemctl enable --now $SSH_UNIT" sshd_enabled_once_installed "enable_units_now $SSH_UNIT"
    "$apply" || return 0
    [ -z "$(key_only_todo 2>/dev/null)" ] || why="$(key_only_reason)" || why=""
    item --sudo "" "Write $SSHD_DROP_IN${why:+, turning off SSH password logins since $why}: $(sshd_drop_in | grep -v '^#' | tr '\n' ' ')" \
        sshd_configured configure_sshd
    if "$tailscale_repo"; then
        text="Install Tailscale from its apt repo: write $TAILSCALE_LIST and its key"
        ! command -v tailscale &>/dev/null ||
            text="Rewrite Tailscale's apt source for $(ubuntu_codename) ($tailscale_source), which Tailscale updates from: write $TAILSCALE_LIST and its key"
        item --sudo "" "$text" false install_tailscale
    fi
    # A fresh install needs a login first
    if command -v tailscale &>/dev/null && ! tailscale_configured && ! tailscale_needs_login; then
        item --sudo "" "Turn on Tailscale's auto-update and make $CURRENT_USER its operator" false set_up_tailscale
    fi
    if [ "$ufw" -eq 1 ] && ufw_enabled && ! ufw_stopped -n; then
        text="add the missing ufw rules"
    elif [ "$ufw" -eq 1 ]; then
        text="install and turn on ufw"
    else
        text="check the ufw rules, and add any that are missing"
    fi
    [ "$ufw" -eq 0 ] ||
        item --sudo "" "Firewall: $text, so ufw denies incoming connections but SSH from ${SSH_RANGES[*]}, anything on tailscale0, and Tailscale's $TAILSCALE_PORT/udp, and denies SSH on Docker's bridges" \
            "ufw_settled $ufw" configure_ufw
    # One item, listed a line per connection
    while IFS=$'\t' read -r uuid name; do
        wake_on_lan_on "$uuid" && continue
        [ -z "$wol" ] || wol="$wol"$'\n'"    - "
        wol="${wol}Wake-on-LAN: set 802-3-ethernet.wake-on-lan to magic on \"$name\""
    done < <(wired_connections)
    [ -z "$wol" ] || item --sudo "" "$wol" false turn_on_wake_on_lan
    ! "$auto_upgrades_unchecked" ||
        item --sudo "" "Check unattended-upgrades' settings in $AUTO_UPGRADES_CONF, which only root can read, and turn it on there if it's off" \
            auto_upgrades_settled true
}

# unattended_upgrades_checked <unchecked>: when only root can read $AUTO_UPGRADES_CONF, it's
# checked only once other changes ask for sudo
unattended_upgrades_checked() {
    { "$1" && ! sudo_confirmed; } || unattended_upgrades_running
}

auto_upgrades_settled() {
    sudo_confirmed || [ ${#pending[@]} -eq 0 ]
}

# ufw_settled <ufw_configured -n's status>: rules unverified without cached sudo aren't worth
# asking for sudo just to read
ufw_settled() {
    if sudo_confirmed; then
        [ "$1" -eq 0 ] || ufw_configured
    else
        [ "$1" -eq 0 ] || { [ "$1" -eq 2 ] && [ ${#pending[@]} -eq 0 ]; }
    fi
}

sshd_enabled_once_installed() {
    ! openssh_installed || sshd_enabled
}

# Fills the caller's memo scope with what checks also read inside a $( )
cache_checks() {
    in_vm || true
    key_login > /dev/null || true
    sudo_ready || true
}

configure_homebrew_env() {
    local changed=true
    ! cmp -s "$HOMEBREW_ENV_SRC" "$HOMEBREW_ENV_CONF" || changed=false
    ubuntu_files copy_file || return 1
    "$changed" || return 0
    user_manager_reachable "user services don't get Homebrew on PATH" \
        "They get it after the next reboot or login." || return 0
    systemctl --user daemon-reload || return 1
    echo "  User services started from now on get Homebrew on PATH. Running ones, such as tmux and"
    echo "  T3 Code, get it when they restart."
}

# The homebrew step installs locales
install_locale() {
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

turn_on_wake_on_lan() {
    local uuid name result=0
    while IFS=$'\t' read -r uuid name; do
        wake_on_lan_on "$uuid" ||
            sudo nmcli connection modify uuid "$uuid" 802-3-ethernet.wake-on-lan magic < /dev/null || result=1
    done < <(wired_connections)
    echo "  Wake-on-LAN applies the next time the connection comes up. It also needs the BIOS settings"
    echo "  in the README's Manual steps: Wake-on-LAN on, and ErP/EuP off."
    return "$result"
}

enable_linger() {
    sudo loginctl enable-linger "$CURRENT_USER"
}

# Root-only state is checked with sudo -n when credentials are cached, else left unverified
status() {
    local uuid name wired=false packages MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    cache_checks
    ubuntu_items
    items_status sleep_masked sleep_conf_written sysctl_written lingering
    status_check "smartmontools, with smartd enabled at boot" smartd_enabled
    if in_vm; then
        status_item skipped "smartd running: this is a VM, whose host manages the disks"
    else
        status_check "smartd running (check a drive with sudo smartctl -a /dev/<disk>)" unit_active "$SMARTD_UNIT"
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
        # Its checks read it inside $( )
        tailscale_prefs > /dev/null || true
        ! apt_installed tailscale ||
            status_apt_source Tailscale "$TAILSCALE_LIST" "$(tailscale_list_line)" ubuntu "$(apt_release_url "$TAILSCALE_REPO")"
        status_check "Tailscale auto-updates, with $CURRENT_USER as its operator" tailscale_configured
        if tailscale_running; then
            status_item ok "Tailscale connected"
        else
            status_item missing "Tailscale connected (run sudo tailscale up)"
        fi
        status_tailscale_exposure
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
}

apply() {
    echo "Setting up Ubuntu to run around the clock..."
    local ufw=0 result=0 auto_upgrades_unchecked=false stay_on="" done_message
    local tailscale_source="" tailscale_repo=false MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    require_cmd jq || return 1
    # A release upgrade turns Tailscale's apt source off, and its updater reads only tailscale.list
    if command -v tailscale &>/dev/null && apt_installed tailscale; then
        tailscale_source="$(apt_source_state "$TAILSCALE_LIST" "$(tailscale_list_line)")"
    fi
    if ! command -v tailscale &>/dev/null || [ -n "$tailscale_source" ]; then
        require_cmd curl || return 1
        # add_apt_repo needs it, after other changes
        require_cmd gpg || return 1
        ! apt_repo_published Tailscale "$(apt_release_url "$TAILSCALE_REPO")" || tailscale_repo=true
    fi
    cache_checks
    ups_state
    if stay_on="$(key_only_todo)" && [ -n "$stay_on" ] && key_only_reason > /dev/null; then
        stay_on=""
    fi
    # Root-only $AUTO_UPGRADES_CONF: checked with sudo only when other changes need it
    ! auto_upgrades_unreadable || sudo_ready || auto_upgrades_unchecked=true
    # 2: unverified without cached sudo
    ufw_configured -n || ufw=$?
    ubuntu_items apply
    configure_homebrew_env || result=1
    configure_health_alerts || result=1

    done_message="  Everything it can check is already set up."
    if [ "$ufw" -ne 0 ] && sudo_ready; then
        done_message="$done_message"$'\n'"  ufw is on, but its rules couldn't be checked: sudo ufw status fails."
    elif [ "$ufw" -ne 0 ]; then
        done_message="$done_message"$'\n'"  ufw is on. Its rules can't be checked without sudo; run sudo -v and re-run this step to check them."
    fi
    ! "$auto_upgrades_unchecked" ||
        done_message="$done_message"$'\n'"  Only root can read $AUTO_UPGRADES_CONF; run sudo -v and re-run this step to check unattended-upgrades."
    items_apply_confirmed --done "$done_message" || result=1
    if command -v nmcli &>/dev/null && [ -z "$(wired_connections)" ]; then
        echo "  No wired connection, so Wake-on-LAN is left off. It works only over Ethernet."
    fi
    [ -z "$stay_on" ] || echo "  Password logins stay on: $stay_on."

    # Not Tailscale SSH (--ssh): it drops every session when auto-update restarts tailscaled
    if command -v tailscale &>/dev/null && ! tailscale_running; then
        echo "  Tailscale isn't connected. Run sudo tailscale up, then bash setup.sh ubuntu to persist"
        echo "  auto-update and operator settings after login. Turn off key expiry for this machine in"
        echo "  the Tailscale admin console, so it doesn't drop off the tailnet after 180 days."
    fi
    warn_no_ups
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
