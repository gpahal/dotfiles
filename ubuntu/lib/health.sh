# shellcheck shell=bash
# ubuntu/install.sh sets the constants.

# Read once through a status run, which declares SMARTMONTOOLS_CACHE_STATUS
smartmontools_installed() {
    memo SMARTMONTOOLS_CACHE apt_installed smartmontools > /dev/null
}

smartd_enabled() {
    smartmontools_installed && [ "$(systemctl is-enabled "$SMARTD_UNIT" 2>/dev/null)" == enabled ]
}

# smartd's unit has ConditionVirtualization=no. Cached once cache_checks runs.
in_vm() {
    memo IN_VM_CACHE systemd-detect-virt -q &>/dev/null
}

smartd_active() {
    systemctl is-active -q "$SMARTD_UNIT" 2>/dev/null
}

smartd_ready() {
    smartd_enabled && { in_vm || smartd_active; }
}

# smartctl's exit bits: 1 bad args or sudo refused, 2 open failed or asleep, 4 SMART command
# failed, 8 failing, 16 prefail attribute at threshold, 32 was before, 64 error log, 128 self-test log.
# A status from 125 up without smartctl's banner is timeout's or a signal's, not those bits.
status_smart_disk() {
    local smartctl="$1" dev="$2" label out status=0 health note=""
    shift 2
    label="Disk health (SMART) of $dev"
    out="$(run_bounded 30 sudo -n "$smartctl" -H -n standby "$@" "$dev" 2>&1)" || status=$?
    health="$(sed -n -e 's/^SMART overall-health self-assessment test result: *//p' \
        -e 's/^SMART Health Status: *//p' <<< "$out" | head -n 1)"
    if [ "$status" -eq 124 ]; then
        status_item unknown "$label: smartctl didn't answer within 30 s; check it with sudo smartctl -a $dev"
    elif [ "$status" -ge 125 ] && [[ "$out" != smartctl\ * ]]; then
        status_item unknown "$label: smartctl didn't run (exit $status); check it with sudo smartctl -H $dev"
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

status_smart() {
    local smartctl scan dev rest args
    local label="Disk health (SMART)"
    if in_vm; then
        status_item skipped "$label: this is a VM, whose host manages the disks"
        return 0
    fi
    if ! smartctl="$(sbin_cmd smartctl)"; then
        status_item unknown "$label: smartctl isn't installed; the ubuntu step installs smartmontools"
        return 0
    fi
    if ! sudo_ready; then
        status_item unverified "$label: reading it needs root; run sudo -v, then status, to check it"
        return 0
    fi
    # e.g. /dev/sda -d sat # /dev/sda [SAT], ATA device
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
        read -ra args <<< "${rest%%#*}"
        status_smart_disk "$smartctl" "$dev" ${args[@]+"${args[@]}"}
    done <<< "$scan"
}

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

# fwupdmgr would start fwupd over D-Bus, so a stopped fwupd is left alone
status_firmware() {
    local label="Firmware updates" out status=0 age updates
    if ! command -v fwupdmgr &>/dev/null; then
        status_item skipped "$label: fwupd isn't installed"
        return 0
    fi
    if status_quick; then
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
    elif [ "$status" -eq 124 ]; then
        status_item info "$label: couldn't check (fwupdmgr didn't answer within 60 s)"
    else
        status_item info "$label: couldn't check ($(grep -v '^ *$' <<< "$out" | head -n 1))"
    fi
}

# Recommends pull in a mail server that asks debconf questions. enable --now leaves an enabled
# but failed unit failed, so restart it.
install_smartd() {
    if ! apt_installed smartmontools; then
        apt_install_fresh --no-install-recommends smartmontools || return 1
    fi
    sudo systemctl enable --now "$SMARTD_UNIT" || return 1
    in_vm || smartd_active || sudo systemctl restart "$SMARTD_UNIT"
}

smartd_hook_installed() {
    root_copy_current "$SMARTD_HOOK_SRC" "$SMARTD_HOOK" 0755 && ntfy_lib_installed
}

install_smartd_hook() {
    install_ntfy_lib && install_root_copy "$SMARTD_HOOK_SRC" "$SMARTD_HOOK" 0755
}

smartd_hook_ready() {
    in_vm || smartd_hook_installed
}

smartd_runs_hooks() {
    grep -qE '^[^#]*smartd-runner' "$SMARTD_CONF" 2>/dev/null
}

status_smartd_hook() {
    local label="smartd's warnings pushed to ntfy ($SMARTD_HOOK)"
    if in_vm; then
        status_item skipped "smartd's warning hook: this is a VM, whose host manages the disks"
        return 0
    fi
    if ! smartd_hook_installed; then
        if [ -e "$SMARTD_HOOK" ]; then
            status_item missing "$label: out of date (re-run the ubuntu step)"
        else
            status_item missing "$label"
        fi
    elif smartmontools_installed && ! smartd_runs_hooks; then
        status_item missing "$label: $SMARTD_CONF has no uncommented line with -M exec /usr/share/smartmontools/smartd-runner, which runs the hook; put it back on the DEVICESCAN line"
    else
        status_item ok "$label"
    fi
}

# A reboot asked for outside dpkg has no .pkgs file, and sort failing would end status under pipefail
reboot_packages() {
    [ -f "$REBOOT_REQUIRED.pkgs" ] || return 0
    sort -u "$REBOOT_REQUIRED.pkgs" 2>/dev/null | join_lines ', '
}
