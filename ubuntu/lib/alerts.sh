# shellcheck shell=bash
# Health alert user units, and the rules for the alerts' URL and token files setup-alerts.sh shares.
# ubuntu/install.sh sets the constants.

# The units run a copy of the script, so they don't depend on what the repo has checked out
health_alert_files() {
    local status=0
    "$1" "$DOTFILES_DIR/ubuntu/health-alert.sh" "$HEALTH_ALERT_DIR/health-alert.sh" || status=1
    "$1" "$DOTFILES_DIR/ubuntu/lib/ntfy.sh" "$HEALTH_ALERT_DIR/ntfy.sh" || status=1
    "$1" "$DOTFILES_DIR/ubuntu/lib/paths.sh" "$HEALTH_ALERT_DIR/paths.sh" || status=1
    "$1" "$DOTFILES_DIR/lib/status-format.sh" "$HEALTH_ALERT_DIR/status-format.sh" || status=1
    "$1" "$DOTFILES_DIR/lib/checkout.sh" "$HEALTH_ALERT_DIR/checkout.sh" || status=1
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

health_units_installed() {
    local unit
    for unit in "${HEALTH_UNITS[@]}"; do
        [ -e "$HEALTH_UNIT_DIR/$unit" ] || return 1
    done
}

health_timer_on() {
    unit_on --user dotfiles-health.timer
}

boot_notice_on() {
    unit_enabled --user dotfiles-boot-notice.service
}

HEALTH_ALERT_LABEL="the daily health alert"

# The boot notice is enabled, not started, so it first pushes at the next boot
configure_health_alerts() {
    local COPIED=false changed
    apply_checkout "$HEALTH_ALERT_LABEL" || return 1
    health_alert_files copy_file || return 1
    changed="$COPIED"
    COPIED=false
    health_unit_files copy_file || return 1
    ! "$COPIED" || changed=true
    user_manager_reachable "the daily health alert and the boot notice aren't on" || return 0
    if ! "$changed" && health_units_loaded && health_timer_on && boot_notice_on; then
        echo "  The daily health alert and the boot notice are already set up."
        return 0
    fi
    if "$COPIED" || ! health_units_loaded; then
        systemctl --user daemon-reload || return 1
    fi
    # A run that failed before the files changed says nothing about them, and status would report
    # it until the next run
    if "$changed"; then
        systemctl --user reset-failed "${HEALTH_UNITS[@]}" || return 1
    fi
    health_timer_on || systemctl --user enable --now dotfiles-health.timer || return 1
    boot_notice_on || systemctl --user enable dotfiles-boot-notice.service || return 1
    echo "  Turned on the daily health alert and the boot notice ($HEALTH_UNIT_DIR). They fail until"
    echo "  just ntfy-user, through just alerts, points them at this machine's ntfy server."
}

# The URL and token files are yours, group nut, mode 0640, so the health alerts (you), the UPS
# notifier (nut), and the smartd hook (root) can all read them without an ACL. Before NUT adds nut,
# they're in your group, and status asks to save them again.
ntfy_url_group() {
    if id nut &>/dev/null; then
        echo nut
    else
        id -gn
    fi
}

# alerts_file_problem <file>: what's wrong with its owner, group, and mode, or nothing
alerts_file_problem() {
    local meta want
    meta="$(owner_group_mode "$1" 2>/dev/null)" || meta=""
    want="$CURRENT_USER $(ntfy_url_group) 640"
    [ "$meta" == "$want" ] || echo "it's ${meta:-unreadable} (owner, group, mode), not $want"
}

# ntfy_token_accepted <token>: the server takes it; also when it can't be asked, which the ntfy
# step's status reports. The token goes through stdin config, out of ps.
ntfy_token_accepted() {
    local code
    code="$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\n' "$NTFY_LOCAL_URL/v1/account" "$1" |
        curl -q -s -o /dev/null -w '%{http_code}' --max-time 5 -K - 2>/dev/null)" || true
    case "$code" in
        200 | 000 | '') return 0 ;;
    esac
    NTFY_TOKEN_STATUS="$code"
    return 1
}

# Prints what's wrong with the saved URL and token, or nothing. Never the URL's path or the token:
# an older ntfy.sh URL's topic was its secret.
ntfy_alerts_problem() {
    local problem url host token re='^tk_[-_A-Za-z0-9]{29}$' NTFY_TOKEN_STATUS=""
    problem="$(alerts_file_problem "$NTFY_URL_FILE")"
    if [ -n "$problem" ]; then
        echo "$NTFY_URL_FILE: $problem"
        return 0
    fi
    if ! url="$(head -n 1 "$NTFY_URL_FILE" 2>/dev/null)"; then
        echo "$NTFY_URL_FILE can't be read"
        return 0
    fi
    if [ "$url" != "$NTFY_ALERTS_URL" ]; then
        host="${url#*://}"
        echo "the URL saved points at ${host%%/*}, not this machine's ntfy server, so they fail"
        return 0
    fi
    if [ ! -e "$NTFY_TOKEN_FILE" ]; then
        echo "$NTFY_TOKEN_FILE is missing"
        return 0
    fi
    problem="$(alerts_file_problem "$NTFY_TOKEN_FILE")"
    if [ -n "$problem" ]; then
        echo "$NTFY_TOKEN_FILE: $problem"
        return 0
    fi
    token="$(head -n 1 "$NTFY_TOKEN_FILE" 2>/dev/null)" || token=""
    if ! [[ "$token" =~ $re ]]; then
        echo "$NTFY_TOKEN_FILE doesn't hold an ntfy token"
    elif ! ntfy_token_accepted "$token"; then
        echo "this machine's ntfy server rejects the token in $NTFY_TOKEN_FILE (HTTP $NTFY_TOKEN_STATUS)"
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
    local url_label="Disk, UPS, health, and boot alerts sent to this machine's ntfy server" problem
    health_alert_files status_file
    health_unit_files status_file
    status_checkout "$HEALTH_ALERT_LABEL"
    # systemd hasn't loaded a unit that was never installed, which the lines above report
    health_units_loaded || ! health_units_installed || ! systemctl --user show-environment &>/dev/null ||
        status_item missing "The health alert's user units in ~/.config/systemd/user: changed since systemd loaded them (re-run the ubuntu step)"
    status_check "Daily health alert to ntfy (dotfiles-health.timer) enabled and active" health_timer_on
    status_check "Boot notice to ntfy (dotfiles-boot-notice.service) enabled" boot_notice_on
    status_last_run "Daily health alert's last run" dotfiles-health.service
    status_last_run "Boot notice's last run" dotfiles-boot-notice.service
    if [ ! -e "$NTFY_URL_FILE" ]; then
        status_item info "$url_label: not set up, so they fail and log why; run just ntfy-user, which runs just alerts"
    elif problem="$(ntfy_alerts_problem)" && [ -n "$problem" ]; then
        status_item missing "$url_label: $problem; run just alerts to save them again"
    else
        status_item ok "$url_label ($NTFY_URL_FILE, $NTFY_TOKEN_FILE)"
    fi
}
