# Helpers for systemd units, the system's and your user manager's. Source after lib/common.sh;
# install_root_unit also needs lib/system.sh, and start_user_service and status_user_service
# lib/gnome.sh.
# shellcheck shell=bash

# unit_enabled [--user] <unit>...: is-enabled prints enabled for each; enabled-runtime ends at the
# next boot. Like unit_active and unit_on, it works as an item check string, such as
# "unit_on docker.socket".
unit_enabled() {
    _unit_is is-enabled "$@"
}

# One unit at a time: is-active with several succeeds when any one is active
unit_active() {
    _unit_is is-active "$@"
}

# Enabled and active
unit_on() {
    unit_enabled "$@" && unit_active "$@"
}

_unit_is() {
    local query="$1" user="" unit
    shift
    [ "${1:-}" != --user ] || { user=--user; shift; }
    for unit; do
        if [ "$query" == is-enabled ]; then
            [ "$(systemctl ${user:+--user} is-enabled "$unit" 2>/dev/null)" == enabled ] || return 1
        else
            systemctl ${user:+--user} "$query" --quiet "$unit" 2>/dev/null || return 1
        fi
    done
}

# enable_units_now [-q] <unit>...
enable_units_now() {
    sudo systemctl enable --now "$@"
}

# install_root_unit <src> <dest>: installs a system unit, then reloads systemd to load it
install_root_unit() {
    install_root_file "$1" "$2" 0644 && sudo systemctl daemon-reload
}

# unit_loaded_current [--user] <unit>...: systemd has loaded each as its files are now. A failed or
# skipped daemon-reload leaves the old unit running though its files changed.
unit_loaded_current() {
    local user="" unit props
    [ "${1:-}" != --user ] || { user=--user; shift; }
    for unit; do
        props="$(systemctl ${user:+--user} show -p LoadState -p NeedDaemonReload "$unit" 2>/dev/null)" &&
            grep -qx LoadState=loaded <<< "$props" && grep -qx NeedDaemonReload=no <<< "$props" || return 1
    done
}

# user_manager_reachable <what isn't so> [next step]: fails, saying so, when systemctl --user can't
# reach your user manager, as in a session started without one
user_manager_reachable() {
    systemctl --user show-environment &>/dev/null && return 0
    echo "  Couldn't reach your systemd user manager, so $1 yet."
    echo "  ${2:-Re-run the step after the next reboot or login.}"
    return 1
}

# start_user_service <unit> <label> <changed>: reloads systemd when <changed> is true or it hasn't
# loaded the unit as it is, and enables the unit. Then, in a desktop session, restarts it when
# changed, or starts it; without one, it starts at the next login. <label> names it in messages,
# such as "the Stream Deck daemon".
start_user_service() {
    local unit="$1" label="$2" changed="$3"
    if "$changed" || ! unit_loaded_current --user "$unit"; then
        systemctl --user daemon-reload || return 1
    fi
    unit_enabled --user "$unit" || systemctl --user enable "$unit" || return 1
    if ! gnome_session_running; then
        echo "  No desktop session, so $label starts at your next login."
    elif "$changed"; then
        systemctl --user restart "$unit" || return 1
        echo "  Restarted $label."
    elif ! unit_active --user "$unit"; then
        systemctl --user start "$unit" || return 1
        echo "  Started $label."
    else
        echo "  $(tr '[:lower:]' '[:upper:]' <<< "${label:0:1}")${label:1} is already running."
    fi
}

# status_user_service <unit> <label>: whether it starts at login and is running
status_user_service() {
    status_check "$2 starts at login" unit_enabled --user "$1"
    if ! gnome_session_running; then
        status_item unverified "$2 running: no desktop session; it starts at the next login"
    elif unit_active --user "$1"; then
        status_item ok "$2 running"
    else
        status_item missing "$2 running: journalctl --user -u $1 says why it stopped"
    fi
}
