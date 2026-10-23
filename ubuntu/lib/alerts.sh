# shellcheck shell=bash
# Health alert user units for the ubuntu step. ubuntu/install.sh sets the constants.

# The units run a copy of the script, so they don't depend on what the repo has checked out
health_alert_files() {
    local status=0
    "$1" "$DOTFILES_DIR/ubuntu/health-alert.sh" "$HEALTH_ALERT_DIR/health-alert.sh" || status=1
    "$1" "$DOTFILES_DIR/ubuntu/lib/ntfy.sh" "$HEALTH_ALERT_DIR/ntfy.sh" || status=1
    "$1" "$DOTFILES_DIR/ubuntu/lib/paths.sh" "$HEALTH_ALERT_DIR/paths.sh" || status=1
    "$1" "$DOTFILES_DIR/lib/status-format.sh" "$HEALTH_ALERT_DIR/status-format.sh" || status=1
    return "$status"
}

health_unit_files() {
    local unit status=0
    for unit in "${HEALTH_UNITS[@]}"; do
        "$1" "$DOTFILES_DIR/ubuntu/systemd/$unit" "$HEALTH_UNIT_DIR/$unit" || status=1
    done
    return "$status"
}

health_units_loaded() {
    unit_loaded_current --user "${HEALTH_UNITS[@]}"
}

health_timer_on() {
    unit_on --user dotfiles-health.timer
}

boot_notice_on() {
    unit_enabled --user dotfiles-boot-notice.service
}

# The boot notice is enabled, not started, so it first pushes at the next boot
configure_health_alerts() {
    local COPIED=false
    health_alert_files copy_file || return 1
    COPIED=false
    health_unit_files copy_file || return 1
    user_manager_reachable "the daily health alert and the boot notice aren't on" || return 0
    if ! "$COPIED" && health_units_loaded && health_timer_on && boot_notice_on; then
        echo "  The daily health alert and the boot notice are already set up."
        return 0
    fi
    if "$COPIED" || ! health_units_loaded; then
        systemctl --user daemon-reload || return 1
    fi
    health_timer_on || systemctl --user enable --now dotfiles-health.timer || return 1
    boot_notice_on || systemctl --user enable dotfiles-boot-notice.service || return 1
    echo "  Turned on the daily health alert and the boot notice ($HEALTH_UNIT_DIR). They push to"
    echo "  ntfy once just alerts saves a URL."
}

NTFY_TOPIC_MIN=20

# ntfy.sh topics are public by name, so a short one can be guessed
ntfy_topic_ok() {
    [ "${#1}" -ge "$NTFY_TOPIC_MIN" ] && [ "${#1}" -le 64 ]
}

# The URL file is yours, group nut, mode 0640, so the health alerts (you), the UPS notifier (nut),
# and the smartd hook (root) can all read it without an ACL. Before NUT adds nut, it's in your
# group, and status asks to save it again.
ntfy_url_group() {
    if id nut &>/dev/null; then
        echo nut
    else
        id -gn
    fi
}

# Prints what's wrong with the saved URL file, or nothing
ntfy_url_file_problem() {
    local meta want topic
    meta="$(owner_group_mode "$NTFY_URL_FILE" 2>/dev/null)" || meta=""
    want="$(id -un) $(ntfy_url_group) 640"
    if [ "$meta" != "$want" ]; then
        echo "it's ${meta:-unreadable} (owner, group, mode), not $want"
    elif ! topic="$(head -n 1 "$NTFY_URL_FILE" 2>/dev/null)"; then
        echo "it can't be read"
    elif ! ntfy_topic_ok "${topic##*/}"; then
        echo "its topic isn't $NTFY_TOPIC_MIN to 64 characters, so it can be guessed"
    fi
}

# status_last_run <label> <unit>
status_last_run() {
    local result
    [ -e "$HEALTH_UNIT_DIR/$2" ] || return 0
    result="$(systemctl --user show -p Result --value "$2" 2>/dev/null)" || return 0
    case "$result" in
        '' | success) ;;
        *) status_item missing "$1: its last run failed ($result); journalctl --user -u $2 says why" ;;
    esac
}

status_health_alerts() {
    local url_label="ntfy URL for the disk, UPS, health, and boot alerts" problem
    health_alert_files status_file
    health_unit_files status_file
    health_units_loaded || ! systemctl --user show-environment &>/dev/null ||
        status_item missing "The health alert's user units in ~/.config/systemd/user: changed since systemd loaded them (re-run the ubuntu step)"
    status_check "Daily health alert to ntfy (dotfiles-health.timer) enabled and active" health_timer_on
    status_check "Boot notice to ntfy (dotfiles-boot-notice.service) enabled" boot_notice_on
    status_last_run "Daily health alert's last run" dotfiles-health.service
    status_last_run "Boot notice's last run" dotfiles-boot-notice.service
    if [ ! -e "$NTFY_URL_FILE" ]; then
        status_item info "$url_label not set; just alerts sets it"
    elif problem="$(ntfy_url_file_problem)" && [ -n "$problem" ]; then
        status_item missing "$url_label ($NTFY_URL_FILE): $problem; run just alerts to save it again"
    else
        status_item info "$url_label set ($NTFY_URL_FILE)"
    fi
}
