# shellcheck shell=bash
# ubuntu/install.sh sets the constants.

nut_installed() {
    local package
    for package in "${NUT_PACKAGES[@]}"; do
        apt_installed "$package" || return 1
    done
}

# Prints <vendor>:<product> per UPS. upower's hwdb tags them, so this needs neither sudo nor NUT.
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

nut_read() {
    read_root_file "$NUT_DIR/$1" -n
}

# nut_value <key> < file: the first quoted value for the key, as nut_config writes it
nut_value() {
    sed -n "s/^[[:space:]]*$1 = \"\(.*\)\"\$/\1/p" | head -n 1
}

# Prints "<driver> <vendor> <product>" for the first UPS in nut-scanner -U's ups.conf output
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
            # NUT 2.8.2+ appends a comment naming other drivers
            sub(/[ \t]*#.*/, "", value)
            gsub(/"/, "", value)
            v[key] = value
            if (key == "driver") driver = value
        }
        END { if (driver != "") print driver, tolower(v["vendorid"]), tolower(v["productid"]) }'
}

# nut_config <file> <driver> <vendor> <product> <password>. The password is hex, from nut_password.
nut_config() {
    local type password="\"$5\""
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
                "	password = $password" "	upsmon primary"
            ;;
        upsmon.conf)
            printf '%s\n' "# From the dotfiles ubuntu step: watch the UPS, push its events, and shut down on a low battery" \
                "MONITOR $UPS_NAME@localhost 1 upsmon $password primary" \
                'SHUTDOWNCMD "/sbin/shutdown -h +0"' \
                "POWERDOWNFLAG $UPS_POWERDOWN_FLAG" \
                "NOTIFYCMD $UPS_NOTIFY"
            for type in ONBATT ONLINE LOWBATT COMMBAD COMMOK SHUTDOWN REPLBATT NOCOMM; do
                echo "NOTIFYFLAG $type SYSLOG+EXEC"
            done
            ;;
    esac
}

# Fallback for a UPS that keeps its power on. If the UPS ignores the cut while mains is out, this
# loops until the battery dies, so the Power cuts manual step checks the UPS cuts its power.
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

# Fails when upsd.users can't be read, so an existing password isn't replaced
nut_password() {
    local users password
    users="$(nut_read upsd.users)" || return 1
    password="$(nut_value password <<< "$users")"
    if [ -z "$password" ]; then
        password="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')" || return 1
    fi
    echo "$password"
}

# nut_file_current <file> <content>: returns 2 when it can't be read without sudo
nut_file_current() {
    local current meta
    current="$(nut_read "$1")" || return 2
    [ "$current" == "$2" ] || return 1
    meta="$({ owner_group_mode "$NUT_DIR/$1" ||
        sudo -n bash -c "$(declare -f file_mode owner_group_mode)"'; owner_group_mode "$1"' _ "$NUT_DIR/$1"; } 2>/dev/null)"
    [ -n "$meta" ] || return 2
    [ "$meta" == "$NUT_OWNER $NUT_GROUP 640" ]
}

# Returns 2 when the files can't be read without sudo
nut_files_current() {
    local conf users driver vendor product password file
    conf="$(nut_read ups.conf)" && users="$(nut_read upsd.users)" || return 2
    driver="$(nut_value driver <<< "$conf")"
    vendor="$(nut_value vendorid <<< "$conf")"
    product="$(nut_value productid <<< "$conf")"
    password="$(nut_value password <<< "$users")"
    [ -n "$driver" ] && [ -n "$password" ] || return 1
    for file in "${NUT_FILES[@]}"; do
        nut_file_current "$file" "$(nut_config "$file" "$driver" "$vendor" "$product" "$password")" ||
            return
    done
}

upsc_value() {
    upsc "$UPS_NAME@localhost" "$1" 2>/dev/null
}

# One at a time: is-active with several units succeeds when any one is active
ups_services_active() {
    local unit
    for unit in "${NUT_UNITS[@]}"; do
        systemctl is-active -q "$unit" 2>/dev/null || return 1
    done
}

ups_notifier_installed() {
    root_copy_current "$UPS_NOTIFY_SRC" "$UPS_NOTIFY" 0755 && ntfy_lib_installed
}

install_ups_notifier() {
    install_ntfy_lib && install_root_copy "$UPS_NOTIFY_SRC" "$UPS_NOTIFY" 0755
}

# ups_configured_for <plugged IDs>: returns 2 when the files can't be read without sudo
ups_configured_for() {
    local conf ids
    conf="$(nut_read ups.conf)" || return 2
    ids="$(nut_value vendorid <<< "$conf"):$(nut_value productid <<< "$conf")"
    grep -qxF "$(tr 'A-F' 'a-f' <<< "$ids")" <<< "$1" || return 1
    nut_files_current
}

# NUT's units hang off nut.target; disabled, they don't start after a reboot
nut_target_enabled() {
    systemctl is-enabled -q nut.target 2>/dev/null
}

# Unreadable files don't count against it, so a run doesn't ask for sudo just to read them
ups_ready() {
    local configured=0
    ups_configured_for "$1" || configured=$?
    [ "$configured" -ne 1 ] && ups_notifier_installed && ups_rtc_hook_installed &&
        ups_services_active && nut_target_enabled && upsc_value ups.status > /dev/null
}

# Sets UPS_STATE (vm, unknown, none, or plugged) and UPS_PLUGGED, once per run of a caller that
# declares UPS_STATE="" local
ups_state() {
    [ -z "${UPS_STATE:-}" ] || return 0
    UPS_PLUGGED=""
    if in_vm; then
        UPS_STATE=vm
    elif [ ! -e "$UPOWER_HWDB" ] || ! UPS_PLUGGED="$(ups_plugged)"; then
        UPS_STATE=unknown
    elif [ -z "$UPS_PLUGGED" ]; then
        UPS_STATE=none
    else
        UPS_STATE=plugged
    fi
}

# Prints the sudo change needed, or nothing. NUT is installed only when a UPS is plugged in.
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

ups_unknown() {
    echo "can't tell whether a UPS is on USB: $UPOWER_HWDB is missing (install upower), or udevadm info --export-db failed"
}

warn_no_ups() {
    ups_state
    case "$UPS_STATE" in
        none) echo "  No UPS on USB, so NUT isn't set up. Plug in the UPS's USB cable and re-run the step." ;;
        unknown) echo "  NUT isn't set up, since it $(ups_unknown)." ;;
    esac
}

write_nut_file() {
    write_root_file "$NUT_DIR/$1" "$2" 0640 "$NUT_GROUP"
}

# The enumerator creates nut-driver@<name> from ups.conf, so it goes first
restart_nut() {
    sudo systemctl restart nut-driver-enumerator.service &&
        sudo systemctl restart "nut-driver@$UPS_NAME.service" "${NUT_UNITS[@]}"
}

setup_ups() {
    local scan driver vendor product password file content changed=false notifier=false rtc=false
    local target=false scan_err scan_status=0
    if ! nut_installed; then
        apt_install_fresh "${NUT_PACKAGES[@]}" || return 1
        # nut-server's postinst re-runs udev only if /etc/init.d/udev exists, which Ubuntu lacks,
        # so a plugged-in UPS wouldn't get the nut group
        sudo udevadm trigger --settle --subsystem-match=usb --action=change || return 1
    fi
    # nut-scanner (NUT 2.8.4) exits 0 whether or not it finds a UPS and prints library warnings
    # to stderr, so only a non-zero exit fails, and only then is stderr shown.
    scan_err="$(mktemp)" || return 1
    scan="$(sudo nut-scanner -U -q 2>"$scan_err")" || scan_status=$?
    if [ "$scan_status" -ne 0 ]; then
        echo "  nut-scanner -U failed (exit $scan_status), so NUT isn't set up:" >&2
        sed 's/^/    /' "$scan_err" >&2
        rm -f "$scan_err"
        return 1
    fi
    rm -f "$scan_err"
    scan="$(ups_scan_parse <<< "$scan")" || return 1
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
    nut_target_enabled || target=true
    sudo systemctl enable nut.target "${NUT_UNITS[@]}" || return 1
    if "$changed"; then
        restart_nut || return 1
        echo "  NUT watches the UPS on USB ($vendor:$product) with $driver; test it as the README's manual steps say."
    elif ! ups_services_active; then
        sudo systemctl start "${NUT_UNITS[@]}" || return 1
    elif ! upsc_value ups.status > /dev/null; then
        restart_nut || return 1
        echo "  Restarted NUT's driver for the UPS on USB ($vendor:$product), since upsd didn't answer for it."
    elif "$notifier"; then
        echo "  Updated the UPS notifier, $UPS_NOTIFY."
    elif "$rtc"; then
        echo "  Installed the RTC wake hook, $UPS_RTC_HOOK."
    elif "$target"; then
        echo "  Enabled nut.target, so NUT starts at boot."
    else
        echo "  NUT is already set up for the UPS on USB ($vendor:$product)."
    fi
}

status_ups() {
    local label="UPS monitored by NUT" state charge item configured=0
    ups_state
    case "$UPS_STATE" in
        vm) status_item skipped "$label: this is a VM" ;;
        # info, not unknown: a machine without upower may have no UPS, and the daily alert would nag
        unknown) status_item info "$label: $(ups_unknown)" ;;
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
