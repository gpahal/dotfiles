# shellcheck shell=bash
# The UPS for the ubuntu step: once a UPS is plugged in on USB, NUT watches it, pushes its events
# to ntfy, and shuts the machine down on a low battery, then has the UPS cut its power, so the
# machine starts again when mains returns. As a fallback for a UPS that keeps its power on, a
# shutdown hook sets an RTC alarm, which starts the machine only on a board that supports it;
# status checks the hook, not the board. Physical machines only.
# ubuntu/install.sh sources this file and sets the constants it uses. It only defines functions.

nut_installed() {
    local package
    for package in "${NUT_PACKAGES[@]}"; do
        apt_installed "$package" || return 1
    done
}

# Print the vendor and product IDs, as <vendor>:<product> in lowercase, of each USB device udev
# tags as a UPS, one per line. upower's hwdb, which Ubuntu Desktop installs, tags each UPS NUT
# knows with UPOWER_BATTERY_TYPE=ups, and anyone may read udev's database, so this needs neither
# sudo nor NUT. Fails when udevadm does.
ups_plugged() {
    udevadm info --export-db 2>/dev/null | awk '
        function flush() {
            if (ups && usb && vendor != "" && product != "") print tolower(vendor ":" product)
            ups = usb = 0; vendor = product = ""
        }
        /^$/ { flush(); next }
        $0 == "E: UPOWER_BATTERY_TYPE=ups" { ups = 1 }
        $0 == "E: DEVTYPE=usb_device" { usb = 1 }
        sub(/^E: ID_VENDOR_ID=/, "") { vendor = $0 }
        sub(/^E: ID_MODEL_ID=/, "") { product = $0 }
        END { flush() }' | sort -u
}

# Print a file in $NUT_DIR, with sudo -n when only root can read it (read_root_file)
nut_read() {
    read_root_file "$NUT_DIR/$1" -n
}

# Print the value of a key in a section of NUT's ini-style files, without its quotes
# e.g. nut_value ups vendorid < ups.conf
nut_value() {
    awk -v section="[$1]" -v key="$2" '
        /^[[:space:]]*\[/ { header = $0; gsub(/[[:space:]]/, "", header); next }
        header == section {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (index(line, key) != 1) next
            rest = substr(line, length(key) + 1)
            if (rest !~ /^[[:space:]]*=/) next
            sub(/^[[:space:]]*=[[:space:]]*/, "", rest)
            gsub(/^"|"[[:space:]]*$/, "", rest)
            print rest
            exit
        }'
}

# Print "<driver> <vendor> <product>" for the first UPS in nut-scanner -U's output on stdin, which
# is in ups.conf's format, e.g.
# [nutdev-usb1]
#         driver = "usbhid-ups"
#         port = "auto"
#         vendorid = "0764"
#         productid = "0501"
ups_scan_parse() {
    awk '
        /^[[:space:]]*\[/ { if (driver != "") exit; next }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line !~ /^(driver|vendorid|productid)[[:space:]]*=/) next
            key = line
            sub(/[[:space:]]*=.*/, "", key)
            value = line
            sub(/^[^=]*=[[:space:]]*/, "", value)
            # NUT 2.8.2 and later follow the driver with a comment naming others that could serve it
            sub(/[ \t]*#.*/, "", value)
            gsub(/"/, "", value)
            v[key] = value
            if (key == "driver") driver = value
        }
        END { if (driver != "") print driver, tolower(v["vendorid"]), tolower(v["productid"]) }'
}

# nut_config <file> <driver> <vendor> <product> <password>: print what the step writes to a file in
# $NUT_DIR
nut_config() {
    local type
    case "$1" in
        nut.conf)
            printf '%s\n' "# From the dotfiles ubuntu step: upsd and upsmon run here, for this machine's own UPS" \
                "MODE=standalone"
            ;;
        ups.conf)
            printf '%s\n' "# From the dotfiles ubuntu step: the UPS nut-scanner found on USB" "[$UPS_NAME]" \
                "	driver = \"$2\"" '	port = "auto"' "	vendorid = \"$3\"" "	productid = \"$4\""
            ;;
        upsd.conf)
            printf '%s\n' "# From the dotfiles ubuntu step: upsd answers only this machine" "LISTEN 127.0.0.1"
            ;;
        upsd.users)
            printf '%s\n' "# From the dotfiles ubuntu step: upsmon's login to upsd" "[upsmon]" \
                "	password = $5" "	upsmon primary"
            ;;
        upsmon.conf)
            printf '%s\n' "# From the dotfiles ubuntu step: watch the UPS, push its events, and shut down on a low battery" \
                "MONITOR $UPS_NAME@localhost 1 upsmon $5 primary" \
                'SHUTDOWNCMD "/sbin/shutdown -h +0"' \
                "POWERDOWNFLAG $UPS_POWERDOWN_FLAG" \
                "NOTIFYCMD $UPS_NOTIFY"
            for type in ONBATT ONLINE LOWBATT COMMBAD COMMOK SHUTDOWN REPLBATT NOCOMM; do
                echo "NOTIFYFLAG $type SYSLOG+EXEC"
            done
            ;;
    esac
}

# Print the system-shutdown hook that sets the RTC alarm. When the UPS cuts its power, the BIOS's
# power-on after AC loss starts the machine once mains returns, and the alarm, which needs power,
# does nothing. When it doesn't, as some don't when mains came back during the shutdown, the alarm
# starts the machine. A UPS that ignores the command while mains is still out makes a loop: the
# alarm starts the machine on battery, upsmon sees a low battery and shuts it down again, setting
# the alarm again, until the battery dies. The hook can't tell that case apart, since the UPS's
# status is gone by then, so the Power cuts manual step has you check the UPS cuts its power.
ups_rtc_hook() {
    printf '%s\n' "#!/bin/sh" \
        "# From the dotfiles ubuntu step: after a UPS shutdown, which leaves $UPS_POWERDOWN_FLAG, start the" \
        "# machine in $UPS_RTC_WAKE_MINUTES minutes in case the UPS doesn't cut its power" \
        "[ -e $UPS_POWERDOWN_FLAG ] || exit 0" \
        "exec /usr/sbin/rtcwake -m no -s $((UPS_RTC_WAKE_MINUTES * 60))"
}

ups_rtc_hook_installed() {
    file_is "$UPS_RTC_HOOK" "$(ups_rtc_hook)" && [ -x "$UPS_RTC_HOOK" ]
}

install_ups_rtc_hook() {
    write_root_file "$UPS_RTC_HOOK" "$(ups_rtc_hook)" 0755
}

# Print upsmon's password from upsd.users, or a new one when there's none. Fails when the file
# can't be read, so an existing password isn't replaced.
nut_password() {
    local users password
    users="$(nut_read upsd.users)" || return 1
    password="$(nut_value upsmon password <<< "$users")"
    if [ -z "$password" ]; then
        password="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')" || return 1
    fi
    echo "$password"
}

# nut_file_current <file> <content>: succeeds when a file in $NUT_DIR has the content, and the nut
# group, which upsd and upsmon read it through. Returns 2 when it can't be read without sudo.
nut_file_current() {
    local current group
    current="$(nut_read "$1")" || return 2
    [ "$current" == "$2" ] || return 1
    # Through sudo -n, as nut_read reads, when $NUT_DIR is closed to you
    group="$({ ls -ld "$NUT_DIR/$1" || sudo -n ls -ld "$NUT_DIR/$1"; } 2>/dev/null | awk '{ print $4 }')"
    [ -n "$group" ] || return 2
    [ "$group" == "$NUT_GROUP" ]
}

# Succeeds when each file in $NUT_DIR is what the step writes for the configured UPS. Returns 2
# when they can't be read without sudo.
nut_files_current() {
    local conf users driver vendor product password file
    conf="$(nut_read ups.conf)" && users="$(nut_read upsd.users)" || return 2
    driver="$(nut_value "$UPS_NAME" driver <<< "$conf")"
    vendor="$(nut_value "$UPS_NAME" vendorid <<< "$conf")"
    product="$(nut_value "$UPS_NAME" productid <<< "$conf")"
    password="$(nut_value upsmon password <<< "$users")"
    [ -n "$driver" ] && [ -n "$password" ] || return 1
    for file in "${NUT_FILES[@]}"; do
        nut_file_current "$file" "$(nut_config "$file" "$driver" "$vendor" "$product" "$password")" ||
            return
    done
}

# Print a variable upsd reports for the UPS, such as ups.status. Anyone may read them.
upsc_value() {
    upsc "$UPS_NAME@localhost" "$1" 2>/dev/null
}

# Each unit on its own, since systemctl is-active succeeds when any one of several is active
ups_services_active() {
    local unit
    for unit in "${NUT_UNITS[@]}"; do
        systemctl is-active -q "$unit" 2>/dev/null || return 1
    done
}

# The notifier runs as the nut user, from outside the repo, so the ntfy code it sources is
# installed with it
ups_notifier_installed() {
    root_copy_current "$UPS_NOTIFY_SRC" "$UPS_NOTIFY" 0755 && root_copy_current "$NTFY_LIB_SRC" "$NTFY_LIB" 0644
}

install_ups_notifier() {
    install_root_copy "$UPS_NOTIFY_SRC" "$UPS_NOTIFY" 0755 && install_root_copy "$NTFY_LIB_SRC" "$NTFY_LIB" 0644
}

# Succeeds when NUT is set up for one of the plugged-in UPSes, given their IDs: ups.conf names one
# of them, and the files are current. Returns 2 when they can't be read without sudo.
ups_configured_for() {
    local conf ids
    conf="$(nut_read ups.conf)" || return 2
    ids="$(nut_value "$UPS_NAME" vendorid <<< "$conf"):$(nut_value "$UPS_NAME" productid <<< "$conf")"
    grep -qxF "$(tr 'A-F' 'a-f' <<< "$ids")" <<< "$1" || return 1
    nut_files_current
}

# Ubuntu's NUT units are wanted by nut.target, which multi-user.target wants once it's enabled. With
# it disabled, the services run now but not after a reboot.
nut_target_enabled() {
    systemctl is-enabled -q nut.target 2>/dev/null
}

# Succeeds when NUT watches a plugged-in UPS: it's set up for it, upsd answers for it, the services
# run and start at boot, and the notifier and the RTC hook are current. Files it can't read without sudo don't count
# against it, so a run without cached credentials doesn't ask for sudo only to read them.
ups_ready() {
    local configured=0
    ups_configured_for "$1" || configured=$?
    [ "$configured" -ne 1 ] && ups_notifier_installed && ups_rtc_hook_installed &&
        ups_services_active && nut_target_enabled && upsc_value ups.status > /dev/null
}

# Set UPS_STATE to the UPS part's state: vm, nohwdb (upower's hwdb, which tells a UPS, is
# missing), noudev (udevadm failed), none (no UPS on USB), or plugged, with UPS_PLUGGED the
# plugged-in UPSes' IDs. Needs no sudo. apply works it out once and sets UPS_STATE_CACHED for the
# calls after, since it reads all of udev's database.
ups_state() {
    [ "${UPS_STATE_CACHED:-}" != true ] || return 0
    UPS_PLUGGED=""
    if in_vm; then
        UPS_STATE=vm
    elif [ ! -e "$UPOWER_HWDB" ]; then
        UPS_STATE=nohwdb
    elif ! UPS_PLUGGED="$(ups_plugged)"; then
        UPS_STATE=noudev
    elif [ -z "$UPS_PLUGGED" ]; then
        UPS_STATE=none
    else
        UPS_STATE=plugged
    fi
}

# Print the change the UPS part needs, for the step's list of sudo changes, or nothing when NUT is
# set up for the UPS on USB, or there's none, which status reports. NUT is installed only for a
# UPS, so a machine without one gets none of it. Needs no sudo: upsd says what it watches.
ups_todo() {
    local ids what
    ups_state
    [ "$UPS_STATE" == plugged ] || return 0
    ids="$(join_lines ', ' <<< "$UPS_PLUGGED")"
    what="write ${NUT_FILES[*]} in $NUT_DIR, install the notifier $UPS_NOTIFY and the RTC wake hook $UPS_RTC_HOOK, and start nut-server and nut-monitor, now and at boot"
    if ! nut_installed; then
        echo "UPS: install nut-client and nut-server, and set up NUT for the UPS on USB ($ids): $what"
    elif ! ups_ready "$UPS_PLUGGED"; then
        echo "UPS: set up NUT for the UPS on USB ($ids): $what"
    fi
}

# Say why NUT isn't set up, when ups_todo leaves it for a later run
warn_no_ups() {
    ups_state
    case "$UPS_STATE" in
        none) echo "  No UPS on USB, so NUT isn't set up. Plug in the UPS's USB cable and re-run the step." ;;
        nohwdb) echo "  Can't tell whether a UPS is on USB: $UPOWER_HWDB is missing. Install upower and re-run the step." ;;
        noudev) echo "  Can't tell whether a UPS is on USB: udevadm info --export-db failed." ;;
    esac
}

# Write a file in $NUT_DIR, root's and readable by the nut group, as the packages ship them. The
# group is set in the same install, so no failure leaves the file without it.
write_nut_file() {
    write_root_file "$NUT_DIR/$1" "$2" 0640 "$NUT_GROUP"
}

# The enumerator turns ups.conf's sections into nut-driver@<name> units, so it runs before the
# driver restarts
restart_nut() {
    sudo systemctl restart nut-driver-enumerator.service &&
        sudo systemctl restart "nut-driver@$UPS_NAME.service" "${NUT_UNITS[@]}"
}

# Install NUT, find the UPS with nut-scanner, and set NUT up for it, replacing only the files that
# differ
setup_ups() {
    local scan driver vendor product password file content changed=false notifier=false rtc=false
    if ! nut_installed; then
        apt_get install -y "${NUT_PACKAGES[@]}" || return 1
        # nut-server's udev rules give the nut group the UPS, but its postinst re-runs udev only
        # where /etc/init.d/udev exists, which Ubuntu lacks, so a UPS already plugged in keeps
        # root's
        sudo udevadm trigger --settle --subsystem-match=usb --action=change || return 1
    fi
    scan="$(sudo nut-scanner -U -q 2>/dev/null | ups_scan_parse)" || true
    if [ -z "$scan" ]; then
        echo "  No UPS found on USB. Plug in the UPS's USB cable and re-run the step."
        return 0
    fi
    read -r driver vendor product <<< "$scan"
    password="$(nut_password)" || {
        echo "  Couldn't read $NUT_DIR/upsd.users for upsmon's password." >&2
        return 1
    }
    for file in "${NUT_FILES[@]}"; do
        content="$(nut_config "$file" "$driver" "$vendor" "$product" "$password")"
        ! nut_file_current "$file" "$content" || continue
        write_nut_file "$file" "$content" || return 1
        changed=true
    done
    if ! ups_notifier_installed; then
        install_ups_notifier || return 1
        notifier=true
    fi
    if ! ups_rtc_hook_installed; then
        install_ups_rtc_hook || return 1
        rtc=true
    fi
    sudo systemctl enable nut.target "${NUT_UNITS[@]}" || return 1
    if "$changed"; then
        restart_nut || return 1
        echo "  NUT watches the UPS on USB ($vendor:$product) with $driver, and shuts the machine down on"
        echo "  a low battery. Test it as the README's manual steps say."
    elif ! ups_services_active; then
        sudo systemctl start "${NUT_UNITS[@]}" || return 1
    elif ! upsc_value ups.status > /dev/null; then
        # The driver isn't running, or lost the UPS
        restart_nut || return 1
        echo "  Restarted NUT's driver for the UPS on USB ($vendor:$product), since upsd didn't answer for it."
    elif "$notifier"; then
        echo "  Updated the UPS notifier, $UPS_NOTIFY."
    elif "$rtc"; then
        echo "  Installed the RTC wake hook, $UPS_RTC_HOOK."
    else
        echo "  NUT is already set up for the UPS on USB ($vendor:$product)."
    fi
}

# Print the status items for the UPS. Reads nothing that needs root, but the files, with sudo -n.
status_ups() {
    local label="UPS monitored by NUT" state charge item configured=0
    ups_state
    case "$UPS_STATE" in
        vm) status_item skipped "$label: this is a VM" ;;
        # Information: a machine without upower may have no UPS, and the daily alert would nag
        nohwdb) status_item info "$label: can't tell whether a UPS is on USB, since $UPOWER_HWDB is missing; install upower" ;;
        noudev) status_item unknown "$label: can't tell whether a UPS is on USB, since udevadm info --export-db failed" ;;
        none) status_item skipped "$label: no UPS on USB; plug in the UPS's USB cable and re-run the ubuntu step" ;;
    esac
    [ "$UPS_STATE" == plugged ] || return 0
    label="UPS on USB ($(join_lines ', ' <<< "$UPS_PLUGGED")) monitored by NUT"
    if ! nut_installed; then
        status_item missing "$label: nut-client and nut-server aren't installed (re-run the ubuntu step)"
        return 0
    fi
    ups_configured_for "$UPS_PLUGGED" || configured=$?
    case "$configured" in
        0) status_item ok "$label" ;;
        1) status_item missing "$label: not set up for it (re-run the ubuntu step)" ;;
        *) status_item unverified "$label: can't read NUT configuration files in $NUT_DIR without sudo; run sudo -v, then status, to check them" ;;
    esac
    if state="$(upsc_value ups.status)" && [ -n "$state" ]; then
        case " $state " in
            *" OL "*) status_item ok "UPS on mains power (ups.status $state)" ;;
            *" OB "*) status_item info "UPS status: $state (on battery)" ;;
            *) status_item info "UPS status: $state" ;;
        esac
        charge="$(upsc_value battery.charge)" || true
        [ -z "$charge" ] || status_item info "UPS battery charge: $charge%"
    else
        status_item missing "upsd answers for $UPS_NAME@localhost (upsc $UPS_NAME@localhost)"
    fi
    status_check "nut-server and nut-monitor running" ups_services_active
    status_check "nut.target enabled, so NUT starts at boot" nut_target_enabled
    if ups_notifier_installed; then
        status_item ok "UPS events pushed to ntfy ($UPS_NOTIFY)"
    else
        status_item missing "UPS events pushed to ntfy ($UPS_NOTIFY): missing or out of date (re-run the ubuntu step)"
    fi
    item="RTC wake hook ($UPS_RTC_HOOK)"
    if ups_rtc_hook_installed; then
        status_item ok "$item installed: asks the board to start the machine $UPS_RTC_WAKE_MINUTES minutes after a UPS shutdown if the UPS keeps its power on; check once that your board wakes (see the Power cuts manual step)"
    else
        status_item missing "$item: missing or out of date (re-run the ubuntu step)"
    fi
}
