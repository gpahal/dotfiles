#!/bin/bash
set -euo pipefail

# Print this OS's setup steps that scripts can't do and that aren't done yet.
# steps.sh lists them, with the checks below for those a script can tell are done, which --status
# reports. Network checks ask GitHub and Tailscale; root-only ones run only while sudo -v is cached.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/manual.sh
source "$DOTFILES_DIR/lib/manual.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=../lib/gnome.sh
source "$DOTFILES_DIR/lib/gnome.sh"
# shellcheck source=../lib/systemd.sh
source "$DOTFILES_DIR/lib/systemd.sh"
# shellcheck source=../macos/lib/privacy.sh
source "$DOTFILES_DIR/macos/lib/privacy.sh"
# shellcheck source=../monitor-input/lib/paths.sh
source "$DOTFILES_DIR/monitor-input/lib/paths.sh"
# shellcheck source=../ubuntu/lib/paths.sh
source "$DOTFILES_DIR/ubuntu/lib/paths.sh"
# shellcheck source=steps.sh
source "$DOTFILES_DIR/manual-steps/steps.sh"

GHOSTTY_ID=com.mitchellh.ghostty
# What the Stream Deck's and Hammerspoon's open-in tells with Apple events: Ghostty's folder, Zed's
# window through System Events, Finder's selection, and Chrome's tabs
OPEN_IN_TARGETS=("$GHOSTTY_ID" com.apple.finder com.apple.systemevents com.google.Chrome)
LAUNCH_SERVICES_PREFS="$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"
CHROME_LOCAL_STATE="$HOME/Library/Application Support/Google/Chrome/Local State"
ACCOUNTS_DB="$HOME/Library/Accounts/Accounts4.sqlite"
SPOTLIGHT_CONFIG=/System/Volumes/Data/.Spotlight-V100/VolumeConfiguration.plist
SPOTLIGHT_EXCLUDED=("$HOME/Dev" "$HOME/go" "$HOME/Library/pnpm")
MAC_TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
# "<name>|<app>|optional", the apps the README turns Launch at login on for
LOGIN_APPS=("Rectangle|/Applications/Rectangle.app|" "Amphetamine|/Applications/Amphetamine.app|"
    "Tailscale|/Applications/Tailscale.app|" "Dato|/Applications/Dato.app|optional")
WISPR_FLOW_APP="/Applications/Wispr Flow.app"
STREAM_DECK_APP="/Applications/Elgato Stream Deck.app"
GDM_CONF=/etc/gdm3/custom.conf
# GNOME's Remote Login, a system RDP server
REMOTE_LOGIN_UNIT=gnome-remote-desktop.service
REMOTE_LOGIN_PORT=3389
SOLAAR_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/solaar/config.yaml"
GNOME_EXTENSIONS=(dotfiles@gpahal.com vicinae@dagimg-dot)
REBOOT_REQUIRED=/var/run/reboot-required

ghostty_full_disk_access() {
    in_ghostty || manual_unknown "run this from Ghostty, not over SSH, to check it" || return
    terminal_has_full_disk_access
}

ghostty_notifications() {
    local pending
    pending="$(notifications_pending "$GHOSTTY_ID")" || manual_unknown "$NOTIFICATIONS_UNREADABLE" || return
    [ -z "$pending" ]
}

ghostty_accessibility() {
    tcc_allowed kTCCServiceAccessibility "$GHOSTTY_ID"
}

# Prints "<scheme> <handler>" per URL scheme LaunchServices has a default app for
url_handlers() {
    local xml
    xml="$(plutil -extract LSHandlers xml1 -o - "$LAUNCH_SERVICES_PREFS" 2>/dev/null)" || return 1
    printf '%s\n' "$xml" | awk '
        /<dict>/ { if (++depth == 1) { scheme = ""; role = "" } next }
        /<\/dict>/ { if (depth-- == 1 && scheme != "") print scheme, role; next }
        depth != 1 { next }
        /<key>LSHandlerURLScheme<\/key>/ { want = "scheme"; next }
        /<key>LSHandlerRoleAll<\/key>/ { want = "role"; next }
        want != "" {
            if (match($0, /<string>[^<]*<\/string>/)) {
                value = tolower(substr($0, RSTART + 8, RLENGTH - 17))
                if (want == "scheme") scheme = value; else role = value
            }
            want = ""
        }'
}

# Without a handler for http, Safari is the default
chrome_default_browser() {
    local handlers handler
    [ -e "$LAUNCH_SERVICES_PREFS" ] || { MANUAL_DETAIL="Safari is"; return 1; }
    handlers="$(url_handlers)" || manual_unknown "couldn't read $(shown_path "$LAUNCH_SERVICES_PREFS")" || return
    handler="$(awk '$1 == "http" { print $2 }' <<< "$handlers")"
    [ "$handler" == com.google.chrome ] && return 0
    MANUAL_DETAIL="${handler:-com.apple.safari} is"
    return 1
}

# OrbStack makes ~/.orbstack when it first starts
orbstack_set_up() {
    [ -d "$HOME/.orbstack" ] || { MANUAL_DETAIL="OrbStack hasn't been opened"; return 1; }
}

app_installed() {
    [ -d "$1" ] || { MANUAL_DETAIL="it isn't installed; the homebrew step installs it"; return 1; }
}

vicinae_set_up() {
    manual_parts_start
    if app_installed /Applications/Vicinae.app; then
        manual_part "Accessibility off" app_has_accessibility /Applications/Vicinae.app
        manual_part "Launch at login off" app_launches_at_login /Applications/Vicinae.app
    else
        manual_part "Vicinae" false
    fi
    manual_parts_result
}

rectangle_set_up() {
    app_installed /Applications/Rectangle.app || return
    app_has_accessibility /Applications/Rectangle.app
}

# Flow asks for both after its sign-in, so they also show the sign-in is done
wispr_flow_set_up() {
    local id
    app_installed "$WISPR_FLOW_APP" || return
    id="$(mac_app_id "$WISPR_FLOW_APP")" || return 1
    manual_parts_start
    manual_part "Microphone off" tcc_user_allowed kTCCServiceMicrophone "$id"
    manual_part "Accessibility off" app_has_accessibility "$WISPR_FLOW_APP"
    manual_parts_result
}

login_items_on() {
    local entry name app optional
    manual_parts_start
    for entry in "${LOGIN_APPS[@]}"; do
        IFS='|' read -r name app optional <<< "$entry"
        if [ ! -d "$app" ]; then
            [ -n "$optional" ] || manual_part "$name isn't installed" false
            continue
        fi
        manual_part "$name" app_launches_at_login "$app"
    done
    manual_parts_result
}

# The plugin's profiles, which Stream Deck installs once you accept its prompt
stream_deck_profiles_installed() {
    local missing
    command -v jq &>/dev/null || manual_unknown "$(missing_cmd_hint jq)" || return
    missing="$(
        # shellcheck source=../stream-deck/lib/profiles.sh
        source "$DOTFILES_DIR/stream-deck/lib/profiles.sh"
        # shellcheck disable=SC2119 # no pages changed
        profile_plan | awk -F "$SEP" '$1 == "missing" { print $3 }'
    )" || manual_unknown "couldn't read Stream Deck's profiles" || return
    [ -z "$missing" ] && return 0
    MANUAL_DETAIL="$(join_lines '; ' <<< "$missing")"
    return 1
}

stream_deck_set_up() {
    local id
    manual_parts_start
    if id="$(mac_app_id "$STREAM_DECK_APP")"; then
        manual_part "Profiles" stream_deck_profiles_installed
        manual_part "Accessibility off" app_has_accessibility "$STREAM_DECK_APP"
        manual_part "Apple events not allowed for" tcc_automation_allowed "$id" "${OPEN_IN_TARGETS[@]}"
    else
        manual_part "Stream Deck isn't installed; the homebrew step installs it" false
    fi
    manual_parts_result
}

hammerspoon_set_up() {
    local id
    manual_parts_start
    if id="$(mac_app_id /Applications/Hammerspoon.app)"; then
        manual_part "Accessibility off" app_has_accessibility /Applications/Hammerspoon.app
        manual_part "Apple events not allowed for" tcc_automation_allowed "$id" "${OPEN_IN_TARGETS[@]}"
    else
        manual_part "Hammerspoon isn't installed; the homebrew step installs it" false
    fi
    manual_parts_result
}

monitor_input_on() {
    if is_macos; then
        [ -e "$MONITOR_INPUT_MAC_CONF" ]
    else
        [ -e "$MONITOR_INPUT_CONF" ]
    fi
}

# Stopped is signed in but turned off
mac_tailscale_signed_in() {
    local tailscale=tailscale state
    [ ! -x "$MAC_TAILSCALE" ] || tailscale="$MAC_TAILSCALE"
    command -v "$tailscale" &>/dev/null || manual_unknown "Tailscale isn't installed" || return
    tailscale_status_json "$tailscale" > /dev/null || manual_unknown "tailscale status failed; open Tailscale" || return
    state="$(jq -r '.BackendState // empty' <<< "$TAILSCALE_STATUS_JSON" 2>/dev/null)"
    case "$state" in
        Running | Starting | Stopped) return 0 ;;
        NeedsLogin | NeedsMachineAuth | NoState) MANUAL_DETAIL="$state"; return 1 ;;
    esac
    manual_unknown "tailscale status said ${state:-nothing}"
}

google_account_added() {
    local count
    count="$(sqlite3 -readonly "$ACCOUNTS_DB" "SELECT COUNT(*) FROM ZACCOUNT a JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK WHERE t.ZIDENTIFIER = 'com.apple.account.Google';" 2>/dev/null)" ||
        manual_unknown "reading Internet Accounts needs Full Disk Access for this terminal" || return
    [ "${count:-0}" -gt 0 ] 2>/dev/null
}

touch_id_on() {
    (
        # shellcheck source=../macos/lib/pam.sh
        source "$DOTFILES_DIR/macos/lib/pam.sh" && has_tid
    )
}

filevault_on() {
    local out
    command -v fdesetup &>/dev/null || manual_unknown "fdesetup isn't on PATH" || return
    out="$(run_bounded 10 fdesetup status 2>&1)" || true
    case "$out" in
        *"FileVault is On"*) return 0 ;;
        *"FileVault is Off"*) return 1 ;;
    esac
    manual_unknown "fdesetup status didn't say"
}

# Another backup tool can't be checked
time_machine_backed_up() {
    local latest
    latest="$(run_bounded 20 tmutil latestbackup 2>/dev/null)" && [ -n "$latest" ] ||
        manual_unknown "no Time Machine backup found, and other backups can't be checked" || return
    MANUAL_DETAIL="latest Time Machine backup ${latest##*/}"
}

# The paths Spotlight's privacy list holds, which only root can read
spotlight_excluded() {
    local xml path missing=()
    sudo_ready || manual_unknown "only root reads Spotlight's privacy list; $ROOT_ONLY_TEXT, to check it" || return
    xml="$(sudo -n plutil -extract Exclusions xml1 -o - "$SPOTLIGHT_CONFIG" 2>/dev/null)" ||
        manual_unknown "couldn't read Spotlight's privacy list in $SPOTLIGHT_CONFIG" || return
    for path in "${SPOTLIGHT_EXCLUDED[@]}"; do
        [ -d "$path" ] || continue
        grep -qE "<string>(/System/Volumes/Data)?$(regex_escape "$path")/?</string>" <<< "$xml" ||
            missing+=("$(shown_path "$path")")
    done
    [ ${#missing[@]} -gt 0 ] || return 0
    MANUAL_DETAIL="$(printf '%s\n' "${missing[@]}" | join_lines ', ') not excluded"
    return 1
}

# Chrome writes the setting only once it's changed
chrome_memory_saver_on() {
    local state
    command -v jq &>/dev/null || manual_unknown "$(missing_cmd_hint jq)" || return
    state="$(jq -r '.performance_tuning.high_efficiency_mode.state // empty' "$CHROME_LOCAL_STATE" 2>/dev/null)" || true
    case "$state" in
        '') manual_unknown "Chrome records it only once it's changed" ;;
        0) return 1 ;;
        *[!0-9]*) manual_unknown "Chrome's setting is $state" ;;
    esac
}

# Runs inside the ubuntu step, for its nm_connections and wifi_connects_at_boot
wifi_all_connect_at_boot() {
    local uuid name
    while IFS=$'\t' read -r uuid name; do
        wifi_connects_at_boot "$uuid" || return 1
    done < <(nm_connections 802-11-wireless --active)
}

network_ready() {
    step_check ubuntu/install.sh wifi_all_connect_at_boot
}

# The recovery key matters only on an encrypted disk
disk_recovery_key_kept() {
    local types
    types="$(lsblk -rno TYPE 2>/dev/null)" || manual_unknown "lsblk failed" || return
    if ! grep -qx crypt <<< "$types"; then
        MANUAL_DETAIL="the disk isn't encrypted"
        return 0
    fi
    manual_unknown "where you keep the recovery key can't be checked"
}

login_shell_zsh() {
    step_check zsh/install.sh login_shell_is_zsh
}

ubuntu_tailscale_json() {
    command -v tailscale &>/dev/null || manual_unknown "Tailscale isn't installed" || return
    tailscale_status_json > /dev/null || manual_unknown "tailscale status failed" || return
    [ "$(jq -r '.BackendState // empty' <<< "$TAILSCALE_STATUS_JSON" 2>/dev/null)" == Running ] ||
        manual_unknown "Tailscale isn't connected" || return
}

tailscale_connected() {
    command -v tailscale &>/dev/null || return 1
    tailscale_status_json > /dev/null || manual_unknown "tailscale status failed" || return
    [ "$(jq -r '.BackendState // empty' <<< "$TAILSCALE_STATUS_JSON" 2>/dev/null)" == Running ]
}

# Self.KeyExpiry is set only while the key expires
tailscale_key_never_expires() {
    local expiry
    ubuntu_tailscale_json || return
    expiry="$(jq -r '.Self.KeyExpiry // empty' <<< "$TAILSCALE_STATUS_JSON")"
    [ -z "$expiry" ] && return 0
    MANUAL_DETAIL="the machine's key expires $expiry"
    return 1
}

# The funnel node attribute shows in the machine's capabilities. With a funnel up, you use it.
tailscale_funnel_attr_gone() {
    local funnels
    ubuntu_tailscale_json || return
    jq -e '(.Self.CapMap // {} | has("funnel")) or ((.Self.Capabilities // []) | index("funnel"))' \
        <<< "$TAILSCALE_STATUS_JSON" &>/dev/null || return 0
    # shellcheck source=../ubuntu/lib/tailscale.sh
    funnels="$(source "$DOTFILES_DIR/ubuntu/lib/tailscale.sh" && tailscale_funnels)" || true
    if [ -n "$funnels" ]; then
        MANUAL_DETAIL="a funnel is up, so you use it"
        return 0
    fi
    MANUAL_DETAIL="the tailnet policy grants it, and no funnel is up"
    return 1
}

# Runs inside the ubuntu step, for its sshd drop-in
password_logins_off() {
    local current
    current="$(current_sshd_drop_in)" || return 2
    key_only_in "$current"
}

ssh_key_only() {
    local result=0
    step_check ubuntu/install.sh password_logins_off || result=$?
    if [ "$result" -eq 2 ]; then
        manual_unknown "only root reads sshd's settings; $ROOT_ONLY_TEXT, to check it"
        return
    fi
    return "$result"
}

# Solaar lists each device it has seen in its config
solaar_paired() {
    if ! has_gnome_desktop; then
        MANUAL_DETAIL="no desktop"
        return 0
    fi
    grep -q '^ *- _NAME:' "$SOLAAR_CONFIG" 2>/dev/null || {
        MANUAL_DETAIL="Solaar hasn't seen a device"
        return 1
    }
}

gnome_extensions_loaded() {
    local uuid state
    has_gnome_desktop || return 0
    for uuid in "${GNOME_EXTENSIONS[@]}"; do
        state="$(gnome_extension_state "$uuid")" || manual_unknown "GNOME Shell isn't running" || return
        [ "${state%%$'\t'*}" != "$GNOME_EXTENSION_ACTIVE" ] || continue
        # GNOME turns extensions off while the screen is locked
        ! gnome_screen_locked || manual_unknown "the screen is locked" || return
        return 1
    done
}

gdm_autologin_on() {
    awk -F '=' '
        /^[[:space:]]*\[/ { daemon = $0 ~ /^[[:space:]]*\[daemon\]/; next }
        daemon && $1 ~ /^[[:space:]]*AutomaticLoginEnable[[:space:]]*$/ && tolower($2) ~ /^[[:space:]]*true[[:space:]]*$/ { on = 1 }
        END { exit !on }' "$GDM_CONF" 2>/dev/null
}

remote_login_on() {
    unit_enabled "$REMOTE_LOGIN_UNIT" &&
        [ -n "$(ss -Hltn "sport = :$REMOTE_LOGIN_PORT" 2>/dev/null)" ]
}

desktop_session_after_reboot() {
    if ! has_gnome_desktop; then
        MANUAL_DETAIL="no desktop"
        return 0
    fi
    if gdm_autologin_on; then
        MANUAL_DETAIL="GDM logs you in"
    elif remote_login_on; then
        MANUAL_DETAIL="Remote Login is on"
    else
        return 1
    fi
}

phone_alerts_set() {
    [ -e "$NTFY_URL_FILE" ]
}

# Déjà Dup, Ubuntu's Backups app, records its last backup; other tools can't be checked
deja_dup_backed_up() {
    local last
    last="$(gsettings get org.gnome.DejaDup last-backup 2>/dev/null)" || true
    last="${last//\'/}"
    [ -n "$last" ] || manual_unknown "no Déjà Dup backup found, and other backups can't be checked" || return
    MANUAL_DETAIL="Déjà Dup's last backup was $last"
}

livepatch_on() {
    local state
    command -v pro &>/dev/null || manual_unknown "pro isn't installed" || return
    state="$(run_bounded 30 pro status --format json 2>/dev/null |
        jq -r '.services[]? | select(.name == "livepatch") | .status' 2>/dev/null)" ||
        manual_unknown "pro status failed" || return
    [ "$state" == enabled ]
}

# The scale of each logical monitor, from Mutter
display_scales() {
    gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
        --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null |
        grep -oE '\(-?[0-9]+, -?[0-9]+, [0-9.]+, uint32 [0-9]+, (true|false), \[' | awk -F ', ' '{ print $3 }'
}

# Mutter reports 5/3 as 1.6666666
display_scale_167() {
    local scales
    if ! has_gnome_desktop; then
        MANUAL_DETAIL="no desktop"
        return 0
    fi
    scales="$(display_scales)" || true
    [ -n "$scales" ] || manual_unknown "GNOME isn't running, or its displays can't be read" || return
    awk '$1 + 0 < 1.66 || $1 + 0 > 1.67 { off = 1 } END { exit off }' <<< "$scales" && return 0
    MANUAL_DETAIL="scale $(join_lines ', ' <<< "$scales")"
    return 1
}

no_reboot_pending() {
    [ ! -e "$REBOOT_REQUIRED" ]
}

status() {
    manual_steps
    status_manual "bash setup.sh manual-steps"
}

apply() {
    manual_steps
    manual_print
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
