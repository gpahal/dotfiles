# shellcheck shell=bash
# The stream-deck step on Ubuntu: the daemon (stream-deck/linux) as a user service, the GNOME
# extension it needs, the Agenda and Gmail app windows, and the root helper the Power key reads.

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DECK_DIR="$DATA_HOME/dotfiles/stream-deck"
LINUX_SRC="$DOTFILES_DIR/stream-deck/linux"
EXTENSION_UUID=dotfiles@gpahal.com
EXTENSION_SRC="$LINUX_SRC/gnome-extension/$EXTENSION_UUID"
EXTENSION_DIR="$DATA_HOME/gnome-shell/extensions/$EXTENSION_UUID"
APPS_DIR="$DATA_HOME/applications"
DECK_UNIT_NAME=dotfiles-stream-deck.service
DECK_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$DECK_UNIT_NAME"
DECK_NODE="${MISE_DATA_DIR:-$DATA_HOME/mise}/installs/node/lts/bin/node"
# The deps' lockfile as last installed, so a changed one reinstalls
DECK_DEPS_STAMP="$DECK_DIR/node_modules/.dotfiles-lock"
# Kept from a change to the daemon's files until the daemon restarts on them
DECK_RESTART_PENDING="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/stream-deck-restart-pending"
POWER_SCRIPT=/usr/local/libexec/dotfiles-power
POWER_UNIT=/etc/systemd/system/dotfiles-power.service
RAPL_DIR=/sys/class/powercap
HIDRAW_DIR=/sys/class/hidraw
DEV_DIR=/dev
# Chrome names an --app window's class after its URL, without the fragment
GMAIL_URL=https://mail.google.com/mail/u/0/#inbox
GMAIL_CLASS=chrome-mail.google.com__mail_u_0_-Default
AGENDA_URL=https://garvitpahal.com/x/agenda
AGENDA_CLASS=chrome-garvitpahal.com__x_agenda-Default
# The Chrome app windows the keys of the same names open: each is dotfiles-<id>.desktop, written by
# <id>_desktop
APP_WINDOWS="gmail agenda"

stream_deck_ubuntu_files() {
    local file status=0
    for file in daemon.js package.json pnpm-lock.yaml pnpm-workspace.yaml bin/open-in; do
        "$1" "$LINUX_SRC/$file" "$DECK_DIR/$file" || status=1
    done
    "$1" "$DOTFILES_DIR/stream-deck/$PLUGIN/bin/open-in-lib.sh" "$DECK_DIR/bin/open-in-lib.sh" || status=1
    for file in keys.js stats.js layout.json manifest.json; do
        "$1" "$DOTFILES_DIR/stream-deck/$PLUGIN/$file" "$DECK_DIR/$file" || status=1
    done
    # The keys' images, and the app windows' icons
    for file in "$DOTFILES_DIR/stream-deck/$PLUGIN/images/"{key-*.svg,key-*@2x.png,gmail.svg,agenda.svg}; do
        "$1" "$file" "$DECK_DIR/images/${file##*/}" || status=1
    done
    for file in metadata.json extension.js; do
        "$1" "$EXTENSION_SRC/$file" "$EXTENSION_DIR/$file" || status=1
    done
    return "$status"
}

gmail_desktop() {
    printf '%s\n' "# From the dotfiles stream-deck step: Gmail in its own window, for the Stream Deck's Gmail key" \
        "[Desktop Entry]" "Type=Application" "Name=Gmail" "Comment=Gmail in a Google Chrome app window" \
        "Exec=google-chrome --app=$GMAIL_URL" "Icon=$DECK_DIR/images/gmail.svg" \
        "StartupWMClass=$GMAIL_CLASS" "Categories=Network;Email;" "Terminal=false"
}

agenda_desktop() {
    printf '%s\n' "# From the dotfiles stream-deck step: the agenda in its own window, for the Stream Deck's Agenda key" \
        "[Desktop Entry]" "Type=Application" "Name=Agenda" "Comment=The agenda in a Google Chrome app window" \
        "Exec=google-chrome --app=$AGENDA_URL" "Icon=$DECK_DIR/images/agenda.svg" \
        "StartupWMClass=$AGENDA_CLASS" "Categories=Network;Office;" "Terminal=false"
}

app_window_file() {
    printf '%s\n' "$APPS_DIR/dotfiles-$1.desktop"
}

status_app_windows() {
    local id file content
    for id in $APP_WINDOWS; do
        file="$(app_window_file "$id")"
        content="$("${id}_desktop")"
        status_check "$(sed -n 's/^Name=//p' <<< "$content") app window ($file)" file_is "$file" "$content"
    done
}

write_app_windows() {
    local id file status=0
    for id in $APP_WINDOWS; do
        file="$(app_window_file "$id")"
        file_is "$file" "$("${id}_desktop")" && continue
        if mkdir -p "$APPS_DIR" && write_content "$file" "$("${id}_desktop")"; then
            echo "  Wrote $file"
        else
            status=1
        fi
    done
    return "$status"
}

deck_unit() {
    printf '%s\n' "# From the dotfiles stream-deck step: draw the Stream Deck's keys and run them" \
        "[Unit]" "Description=Drive the Stream Deck with the dotfiles keys" \
        "PartOf=graphical-session.target" "After=graphical-session.target" "" \
        "[Service]" "ExecStart=$(systemd_quote "$DECK_NODE") $(systemd_quote "$DECK_DIR/daemon.js")" \
        "Restart=on-failure" "RestartSec=5" "" \
        "[Install]" "WantedBy=graphical-session.target"
}

deck_deps_current() {
    cmp -s "$LINUX_SRC/pnpm-lock.yaml" "$DECK_DEPS_STAMP"
}

# --prod leaves out nothing today, but keeps a later devDependency off the machine
install_deck_deps() {
    (cd "$DECK_DIR" && pnpm install --frozen-lockfile --prod --config.confirmModulesPurge=false) || return 1
    cp "$LINUX_SRC/pnpm-lock.yaml" "$DECK_DEPS_STAMP"
}

# The Stream Deck's hidraw nodes, while it's attached here rather than to the Mac
deck_hidraw_nodes() {
    local dir
    for dir in "$HIDRAW_DIR"/hidraw*; do
        grep -qi '^HID_ID=0003:00000FD9:' "$dir/device/uevent" 2> /dev/null && echo "$DEV_DIR/${dir##*/}"
    done
    return 0
}

rapl_present() {
    [ -e "$RAPL_DIR/intel-rapl:0/energy_uj" ]
}

power_script_installed() {
    root_copy_current "$LINUX_SRC/dotfiles-power" "$POWER_SCRIPT" 0755
}

# A running helper keeps the old script and unit until restarted
install_power_script() {
    install_root_file "$LINUX_SRC/dotfiles-power" "$POWER_SCRIPT" 0755 &&
        sudo systemctl try-restart dotfiles-power.service
}

power_unit_installed() {
    root_copy_current "$LINUX_SRC/dotfiles-power.service" "$POWER_UNIT" 0644
}

install_power_unit() {
    install_root_unit "$LINUX_SRC/dotfiles-power.service" "$POWER_UNIT" &&
        sudo systemctl try-restart dotfiles-power.service
}

stream_deck_ubuntu_items() {
    items_reset
    item --sudo "Resources, which the stat keys open" "Install Resources, the system monitor the stat keys open" \
        "apt_installed resources" "apt_install_fresh resources"
    rapl_present || return 0
    item --sudo "Power helper's service ($POWER_UNIT)" "Install $POWER_UNIT" \
        power_unit_installed install_power_unit
    item --sudo "Power helper ($POWER_SCRIPT)" "Install $POWER_SCRIPT, which shares the CPU's power for the Power key" \
        power_script_installed install_power_script
    item --sudo "Power helper running" "Start the power helper, and at each boot" \
        "unit_on dotfiles-power.service" "enable_units_now dotfiles-power.service"
}

status_daemon() {
    status_check "Stream Deck daemon's dependencies in $DECK_DIR" deck_deps_current
    status_check "Stream Deck daemon's service ($DECK_UNIT)" file_is "$DECK_UNIT" "$(deck_unit)"
    [ -x "$DECK_NODE" ] || status_item missing "Node LTS at $DECK_NODE, which the daemon runs: bash setup.sh runtimes"
    [ ! -e "$DECK_RESTART_PENDING" ] ||
        status_item missing "Stream Deck daemon restarted on its new files: re-run the stream-deck step"
    [ -f "$DECK_UNIT" ] || return 0
    status_user_service "$DECK_UNIT_NAME" "Stream Deck daemon"
}

# uaccess gives the desktop session's user the deck; an SSH session alone doesn't count
status_deck_access() {
    local node nodes
    nodes="$(deck_hidraw_nodes)"
    if [ -z "$nodes" ]; then
        status_item info "Stream Deck not attached here; the USB switch may have it on the Mac"
        return 0
    fi
    while IFS= read -r node; do
        if [ -r "$node" ] && [ -w "$node" ]; then
            status_item ok "Stream Deck readable at $node"
        else
            status_item missing "Stream Deck readable at $node: no access; it's granted to the user logged in at the desktop"
        fi
    done <<< "$nodes"
}

status_ubuntu() {
    stream_deck_ubuntu_files status_file
    status_stale "$DECK_DIR" "the repo no longer has it" deck_file_list
    status_app_windows
    status_daemon
    if status_require_cmd gsettings "GNOME extension"; then
        status_gnome_extension "$EXTENSION_UUID" "$EXTENSION_DIR" "GNOME extension"
    fi
    stream_deck_ubuntu_items
    items_status
    rapl_present || status_item skipped "Power key: this CPU has no RAPL power counter"
    status_deck_access
}

# A running GNOME Shell keeps the extension it loaded at login
setup_extension() {
    if ! gnome_extension_enabled "$EXTENSION_UUID"; then
        gnome_enable_extension "$EXTENSION_UUID" || return 1
        echo "  Turned on the GNOME extension $EXTENSION_UUID. It loads at your next login."
    elif "$EXTENSION_COPIED" && gnome_extension_state "$EXTENSION_UUID" > /dev/null; then
        echo "  The GNOME extension changed; log out and back in to load it."
    fi
}

# The daemon's files in DECK_DIR, relative to it
deck_file_list() {
    stream_deck_ubuntu_files _deck_dest
}

_deck_dest() {
    case "$2" in
        "$DECK_DIR"/*) printf '%s\n' "${2#"$DECK_DIR"/}" ;;
    esac
}

mark_restart_pending() {
    mkdir -p "$(dirname "$DECK_RESTART_PENDING")" && touch "$DECK_RESTART_PENDING"
}

# Restarts the daemon when it or its files changed, so it runs the new ones. The pending mark
# outlasts a failed run, so the next one still restarts it.
setup_deck_service() {
    local changed=false
    [ ! -e "$DECK_RESTART_PENDING" ] || changed=true
    user_manager_reachable "the daemon isn't on" || return 0
    if ! file_is "$DECK_UNIT" "$(deck_unit)"; then
        mkdir -p "$(dirname "$DECK_UNIT")" && mark_restart_pending && write_content "$DECK_UNIT" "$(deck_unit)" || return 1
        changed=true
    fi
    start_user_service "$DECK_UNIT_NAME" "the Stream Deck daemon" "$changed" || return 1
    rm -f "$DECK_RESTART_PENDING"
}

# Copies a file, noting in EXTENSION_COPIED or DECK_COPIED whose it was when it changed
copy_deck_file() {
    COPIED=false
    copy_file "$@" || return 1
    "$COPIED" || return 0
    case "$2" in
        "$EXTENSION_DIR"/*) EXTENSION_COPIED=true ;;
        *) DECK_COPIED=true ;;
    esac
}

apply_ubuntu() {
    echo "Setting up the Stream Deck daemon..."
    local status=0
    require_cmd pnpm || return 1
    require_cmd jq || return 1
    require_cmd gsettings || return 1
    if [ ! -x "$DECK_NODE" ]; then
        echo "  Node LTS isn't at $DECK_NODE. Run bash setup.sh runtimes first." >&2
        return 1
    fi
    DECK_COPIED=false
    EXTENSION_COPIED=false
    stream_deck_ubuntu_files copy_deck_file || status=1
    COPIED=false
    remove_stale "$DECK_DIR" "the repo" deck_file_list || status=1
    ! "$COPIED" || DECK_COPIED=true
    ! "$DECK_COPIED" || mark_restart_pending || status=1
    if ! deck_deps_current; then
        if install_deck_deps; then
            mark_restart_pending || status=1
        else
            echo "  Couldn't install the daemon's packages in $DECK_DIR." >&2
            status=1
        fi
    fi
    write_app_windows || status=1
    setup_extension || status=1
    setup_deck_service || status=1

    stream_deck_ubuntu_items
    items_apply_confirmed || status=1
    rapl_present || echo "  This CPU has no RAPL power counter, so the Power key stays empty."
    return "$status"
}
