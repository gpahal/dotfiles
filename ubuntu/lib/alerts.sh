# shellcheck shell=bash
# Health alert user units for the ubuntu step. ubuntu/install.sh sets the constants.

health_unit() {
    local script
    script="$(systemd_quote "$DOTFILES_DIR/ubuntu/health-alert.sh")"
    case "$1" in
        dotfiles-health.service)
            printf '%s\n' "# From the dotfiles ubuntu step: push what status needs attention to ntfy" \
                "[Unit]" "Description=Push what dotfiles status reports needs attention to ntfy" "" \
                "[Service]" "Type=oneshot" "ExecStart=/bin/bash $script status" "TimeoutStartSec=30min"
            ;;
        dotfiles-health.timer)
            printf '%s\n' "# From the dotfiles ubuntu step: run dotfiles-health.service daily" \
                "[Unit]" "Description=Check dotfiles status daily" "" \
                "[Timer]" "OnCalendar=daily" "Persistent=true" "RandomizedDelaySec=1h" "" \
                "[Install]" "WantedBy=timers.target"
            ;;
        dotfiles-boot-notice.service)
            printf '%s\n' "# From the dotfiles ubuntu step: push a notice to ntfy when the machine starts" \
                "[Unit]" "Description=Push to ntfy that this machine started" "" \
                "[Service]" "Type=oneshot" "ExecStart=/bin/bash $script boot" "TimeoutStartSec=10min" "" \
                "[Install]" "WantedBy=default.target"
            ;;
    esac
}

health_units_exist() {
    local unit
    for unit in "${HEALTH_UNITS[@]}"; do
        [ -e "$HEALTH_UNIT_DIR/$unit" ] || return 1
    done
}

health_units_written() {
    local unit
    for unit in "${HEALTH_UNITS[@]}"; do
        file_is "$HEALTH_UNIT_DIR/$unit" "$(health_unit "$unit")" || return 1
    done
}

# The units run the script by path, so a removed worktree would break them
in_git_worktree() {
    local git_dir common_dir
    command -v git &>/dev/null || return 1
    git_dir="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
    common_dir="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ "$git_dir" != "$common_dir" ]
}

health_units_worktree() {
    [ "${DOTFILES_ALLOW_WORKTREE:-}" != 1 ] && in_git_worktree "$DOTFILES_DIR"
}

# A failed daemon-reload leaves the old ExecStart running though the files match
health_units_loaded() {
    local unit
    for unit in "${HEALTH_UNITS[@]}"; do
        [ "$(systemctl --user show -p NeedDaemonReload --value "$unit" 2>/dev/null)" == no ] || return 1
    done
}

health_timer_on() {
    systemctl --user is-enabled --quiet dotfiles-health.timer 2>/dev/null &&
        systemctl --user is-active --quiet dotfiles-health.timer 2>/dev/null
}

boot_notice_on() {
    systemctl --user is-enabled --quiet dotfiles-boot-notice.service 2>/dev/null
}

# The boot notice is enabled, not started, so it first pushes at the next boot
configure_health_alerts() {
    local unit changed=false
    if health_units_worktree; then
        if health_units_written; then
            echo "  The daily health alert and the boot notice run this git worktree, $DOTFILES_DIR, so"
            echo "  they'll stop when it's removed. Re-run the step from the main checkout."
        else
            echo "  $DOTFILES_DIR is a git worktree, so the daily health alert and the boot notice aren't"
            echo "  set up from it: they'd stop when it's removed. Re-run the step from the main checkout."
        fi
        return 0
    fi
    for unit in "${HEALTH_UNITS[@]}"; do
        file_is "$HEALTH_UNIT_DIR/$unit" "$(health_unit "$unit")" && continue
        mkdir -p "$HEALTH_UNIT_DIR" && health_unit "$unit" > "$HEALTH_UNIT_DIR/$unit" || return 1
        changed=true
    done
    if ! systemctl --user show-environment &>/dev/null; then
        echo "  Couldn't reach your systemd user manager, so the daily health alert and the boot notice"
        echo "  aren't on yet. Re-run the step after the next reboot or login."
        return 0
    fi
    if ! "$changed" && health_units_loaded && health_timer_on && boot_notice_on; then
        echo "  The daily health alert and the boot notice are already set up."
        return 0
    fi
    if "$changed" || ! health_units_loaded; then
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
    local label="The health alert's user units in ~/.config/systemd/user"
    local url_label="ntfy URL for the disk, UPS, health, and boot alerts" problem
    if health_units_worktree && health_units_written; then
        status_item missing "$label: they run this git worktree, so the alerts stop when it's removed; re-run the ubuntu step from the main checkout"
    elif health_units_worktree && ! health_units_exist; then
        status_item missing "$label: not installed; run the ubuntu step from the main checkout"
    elif health_units_worktree; then
        status_item info "$label: checked only from the main checkout, which setup installs them from"
    elif ! health_units_written; then
        status_item missing "$label: differ from what setup writes; re-run the ubuntu step"
    elif ! health_units_loaded && systemctl --user show-environment &>/dev/null; then
        status_item missing "$label: changed since systemd loaded them (re-run the ubuntu step)"
    else
        status_item ok "$label"
    fi
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
