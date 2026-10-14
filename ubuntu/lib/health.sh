# shellcheck shell=bash
# Disk and machine health for the ubuntu step: smartd and SMART, fwupd, and the packages whose
# updates need a reboot.
# ubuntu/install.sh sources this file and sets the constants it uses. It only defines functions.

# smartmontools enables smartd when it installs, but it may have been turned off since
smartd_enabled() {
    apt_installed smartmontools && [ "$(systemctl is-enabled "$SMARTD_UNIT" 2>/dev/null)" == enabled ]
}

# The unit's ConditionVirtualization=no skips smartd in a VM, where the host manages the disks
in_vm() {
    systemd-detect-virt -q 2>/dev/null
}

smartd_active() {
    systemctl is-active -q "$SMARTD_UNIT" 2>/dev/null
}

# Enabled, and running outside a VM. An enabled smartd can still be stopped or have failed.
smartd_ready() {
    smartd_enabled && { in_vm || smartd_active; }
}

# Print the path of a command in /usr/sbin, such as smartctl, ufw, or sysctl. A user's PATH may
# lack /usr/sbin.
sbin_cmd() {
    PATH="$PATH:$SBIN_PATH" command -v "$1"
}

smartctl_cmd() {
    sbin_cmd smartctl
}

# Print an item for one disk's SMART health, from smartctl -H. Its exit status is a bit mask:
# 1 the command line didn't parse (or sudo refused it), 2 the device didn't open or is asleep,
# 4 a SMART command failed, 8 the disk reports itself failing, 16 a prefailure attribute is at
# or below its threshold now, 32 one was before, 64 the error log has errors, 128 the self-test
# log does. -n standby leaves a disk that's spun down asleep. -H prints no serial number.
status_smart_disk() {
    local smartctl="$1" dev="$2" label out status=0 health note=""
    shift 2
    label="Disk health (SMART) of $dev"
    out="$(run_bounded 30 sudo -n "$smartctl" -H -n standby "$@" "$dev" 2>&1)" || status=$?
    health="$(sed -n -e 's/^SMART overall-health self-assessment test result: *//p' \
        -e 's/^SMART Health Status: *//p' <<< "$out" | head -n 1)"
    if [ "$status" -eq 124 ]; then
        status_item unknown "$label: smartctl didn't answer within 30 s; check it with sudo smartctl -a $dev"
    elif [ $((status & 8)) -ne 0 ] || [[ "$health" == FAIL* ]]; then
        status_item missing "$label: ${health:-FAILED}; the disk reports itself failing, so back up its data and replace it"
    elif [ $((status & 16)) -ne 0 ]; then
        status_item missing "$label: a prefailure attribute is at or below its threshold; see sudo smartctl -a $dev, and back up its data"
    elif grep -qE 'in (STANDBY|SLEEP)[A-Z_]* mode' <<< "$out"; then
        status_item unverified "$label: in standby, and status doesn't wake it"
    elif [ "$health" == PASSED ] || [ "$health" == OK ]; then
        [ $((status & 32)) -eq 0 ] || note="an attribute was at or below its threshold before"
        if [ $((status & 64)) -ne 0 ]; then
            note="${note:+$note, and }its error log has errors"
        fi
        if [ $((status & 128)) -ne 0 ]; then
            note="${note:+$note, and }its self-test log has errors"
        fi
        status_item ok "$label: $health${note:+, but $note (sudo smartctl -a $dev)}"
    elif grep -qE 'SMART support is: *(Unavailable|Disabled)|lacks SMART capability|SMART Disabled' <<< "$out" ||
        [ $((status & 4)) -ne 0 ]; then
        status_item unverified "$label: it doesn't report SMART health"
    elif [ $((status & 2)) -ne 0 ]; then
        status_item unverified "$label: smartctl couldn't open it"
    elif [ $((status & 1)) -ne 0 ]; then
        status_item unverified "$label: sudo -n couldn't run smartctl; check it with sudo smartctl -H $dev"
    else
        status_item unknown "$label: couldn't read smartctl's output; check it with sudo smartctl -H $dev"
    fi
}

# Print an item for each disk's SMART health. smartctl needs root, so it runs with sudo -n, only
# when sudo credentials are cached. smartd also reports failures through the warning hook; a
# failing disk here makes status need attention.
status_smart() {
    local smartctl scan dev rest args
    local label="Disk health (SMART)"
    if in_vm; then
        status_item skipped "$label: this is a VM, whose host manages the disks"
        return 0
    fi
    if ! smartctl="$(smartctl_cmd)"; then
        status_item unknown "$label: smartctl isn't installed; the ubuntu step installs smartmontools"
        return 0
    fi
    if ! sudo_cached; then
        status_item unverified "$label: reading it needs root; run sudo -v, then status, to check it"
        return 0
    fi
    # --scan names each device and its type without opening it, e.g.
    # /dev/sda -d sat # /dev/sda [SAT], ATA device
    if ! scan="$(run_bounded 30 sudo -n "$smartctl" --scan 2>/dev/null)"; then
        status_item unverified "$label: smartctl couldn't list the disks; check them with sudo smartctl --scan"
        return 0
    fi
    if ! grep -q '^/' <<< "$scan"; then
        status_item unverified "$label: smartctl found no disks it can check"
        return 0
    fi
    while read -r dev rest; do
        [[ "$dev" == /* ]] || continue
        # The type, "-d <type>", is two arguments
        read -ra args <<< "${rest%%#*}"
        status_smart_disk "$smartctl" "$dev" ${args[@]+"${args[@]}"}
    done <<< "$scan"
}

# Print how old fwupd's metadata is: from the last 30 days, over 30 days old, or of unknown age
fwupd_metadata_age() {
    local dir found=false
    for dir in $FWUPD_METADATA_DIRS; do
        [ -d "$dir" ] || continue
        if [ -n "$(find "$dir" -type f -name 'metadata*' -mtime -30 2>/dev/null | head -n 1)" ]; then
            echo "metadata from the last 30 days"
            return 0
        fi
        [ -z "$(find "$dir" -type f -name 'metadata*' 2>/dev/null | head -n 1)" ] || found=true
    done
    if "$found"; then
        echo "metadata over 30 days old (fwupdmgr refresh updates it)"
    else
        echo "metadata of unknown age"
    fi
}

# Information, not something setup does: the firmware updates fwupd's existing metadata lists. It
# refreshes nothing and installs nothing. fwupdmgr would start fwupd over D-Bus, so a stopped fwupd
# is left stopped.
status_firmware() {
    local label="Firmware updates" out status=0 age updates
    if ! command -v fwupdmgr &>/dev/null; then
        status_item skipped "$label: fwupd isn't installed"
        return 0
    fi
    if [ -n "${DOTFILES_STATUS_QUICK:-}" ]; then
        status_item unverified "$label: skipped by --quick"
        return 0
    fi
    if ! systemctl is-active --quiet fwupd.service 2>/dev/null; then
        status_item info "$label: fwupd isn't running, and status doesn't start it; fwupdmgr get-updates checks"
        return 0
    fi
    age="$(fwupd_metadata_age)"
    out="$(run_bounded 60 fwupdmgr get-updates --json --no-unreported-check --no-metadata-check \
        --no-reboot-check 2>&1)" || status=$?
    if [ "$status" -eq 0 ] && grep -q '^ *{' <<< "$out"; then
        # Each device with a release, as "<name> (<version> to <new version>)"
        if command -v jq &>/dev/null; then
            updates="$(sed -n '/^ *{/,$p' <<< "$out" | jq -r '[.Devices[]? | select((.Releases // []) | length > 0)
                | "\(.Name) (\(.Version) to \(.Releases[0].Version))"] | join(", ")' 2>/dev/null)" || updates="?"
        else
            updates="?"
        fi
        case "$updates" in
            "") status_item info "$label: none available, by $age" ;;
            "?") status_item info "$label: couldn't read fwupdmgr's JSON without jq; fwupdmgr get-updates lists them" ;;
            *) status_item info "$label: available for $updates, by $age; fwupdmgr update installs them" ;;
        esac
    elif grep -qiE 'No (updatable|supported) devices' <<< "$out"; then
        status_item info "$label: no device here that fwupd updates"
    elif [ "$status" -eq 2 ] || grep -qiE 'No updates available|no available firmware updates' <<< "$out"; then
        status_item info "$label: none available, by $age"
    elif [ "$status" -eq 124 ]; then
        status_item info "$label: couldn't check (fwupdmgr didn't answer within 60 s)"
    else
        status_item info "$label: couldn't check ($(grep -v '^ *$' <<< "$out" | head -n 1))"
    fi
}

# Recommends would pull in a mail server, such as postfix, which asks debconf questions. enable
# --now leaves a failed unit failed when it's already enabled, so a restart follows. The step
# doesn't edit /etc/smartd.conf.
install_smartd() {
    if ! apt_installed smartmontools; then
        apt_get install -y --no-install-recommends smartmontools || return 1
    fi
    sudo systemctl enable --now "$SMARTD_UNIT" || return 1
    in_vm || smartd_active || sudo systemctl restart "$SMARTD_UNIT"
}

# The ntfy code smartd's hook and the UPS notifier source. They run away from the repo, which the
# notifier's nut user may not be able to read, so it's installed for them.
ntfy_lib_installed() {
    cmp -s "$NTFY_LIB_SRC" "$NTFY_LIB"
}

install_ntfy_lib() {
    ntfy_lib_installed && return 0
    sudo mkdir -p "$(dirname "$NTFY_LIB")" && sudo install -m 0644 "$NTFY_LIB_SRC" "$NTFY_LIB"
}

# The hook is root's and runs as root, so it's installed whole, executable, with the ntfy code
smartd_hook_installed() {
    cmp -s "$SMARTD_HOOK_SRC" "$SMARTD_HOOK" && [ -x "$SMARTD_HOOK" ] && ntfy_lib_installed
}

# install_root_executable <source> <destination>
install_root_executable() {
    sudo mkdir -p "$(dirname "$2")" && sudo install -m 0755 "$1" "$2"
}

install_smartd_hook() {
    install_root_executable "$SMARTD_HOOK_SRC" "$SMARTD_HOOK" && install_ntfy_lib
}

# The hook that pushes smartd's warnings, and the ntfy code it sources. In a VM smartd doesn't run,
# so it doesn't matter there. status_health_alerts reports the ntfy URL.
status_smartd_hook() {
    local label="smartd's warnings pushed to ntfy ($SMARTD_HOOK)"
    if in_vm; then
        status_item skipped "smartd's warning hook: this is a VM, whose host manages the disks"
        return 0
    fi
    if smartd_hook_installed; then
        status_item ok "$label"
    elif [ -e "$SMARTD_HOOK" ]; then
        status_item missing "$label: out of date (re-run the ubuntu step)"
    else
        status_item missing "$label"
    fi
}

# Print the packages whose updates need a reboot, comma-separated
reboot_packages() {
    sort -u "$REBOOT_REQUIRED.pkgs" 2>/dev/null | join_lines ', '
}
