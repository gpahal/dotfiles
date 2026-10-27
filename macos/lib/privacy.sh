# What macOS keeps in its privacy settings (TCC) and login items, read-only, for the manual-steps
# checks. Each function returns 2 and sets MANUAL_DETAIL (lib/manual.sh) when it can't tell. Source
# after lib/common.sh; don't run it.
# shellcheck shell=bash
# shellcheck disable=SC2034 # lib/manual.sh reads MANUAL_DETAIL, and callers the states

# Accessibility, Screen Recording, and Full Disk Access are system-wide, so only root reads them;
# Automation is per user. Both databases also need Full Disk Access for the terminal.
TCC_SYSTEM_DB="/Library/Application Support/com.apple.TCC/TCC.db"
TCC_USER_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
TCC_NEEDS_ACCESS="reading macOS's privacy settings needs Full Disk Access for this terminal"
# auth_value 2 is allowed
TCC_ALLOWED=2

# mac_app_id <app>: the bundle id in the app's Info.plist
mac_app_id() {
    plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null
}

# In the terminal that runs this, rather than one it was started from, as over SSH
in_ghostty() {
    [ -z "${SSH_CONNECTION:-}" ] && { [ "${TERM_PROGRAM:-}" == ghostty ] || [ -n "${GHOSTTY_RESOURCES_DIR:-}" ]; }
}

# Anyone may read the system TCC database's file, but macOS lets only an app with Full Disk Access,
# or what it runs, open it
terminal_has_full_disk_access() {
    head -c 1 "$TCC_SYSTEM_DB" &>/dev/null
}

# tcc_query <system|user> <sql>: sets TCC_ROWS, or returns 2 when the database can't be read
tcc_query() {
    local db="$TCC_USER_DB" as=()
    TCC_ROWS=""
    if [ "$1" == system ]; then
        db="$TCC_SYSTEM_DB"
        if ! sudo_ready; then
            MANUAL_DETAIL="only root reads macOS's privacy settings; $ROOT_ONLY_TEXT, to check it"
            return 2
        fi
        as=(sudo -n)
    fi
    TCC_ROWS="$(${as[@]+"${as[@]}"} sqlite3 -readonly "$db" "$2" 2>/dev/null)" && return 0
    MANUAL_DETAIL="$TCC_NEEDS_ACCESS"
    return 2
}

# Ids go into SQL, so only a bundle id's characters pass
tcc_id_ok() {
    [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]
}

# tcc_allowed <service> <bundle id>: the app has the system-wide permission, such as
# kTCCServiceAccessibility
tcc_allowed() {
    tcc_id_ok "$2" || return 1
    tcc_query system "SELECT auth_value FROM access WHERE service = '$1' AND client = '$2';" || return 2
    grep -qx "$TCC_ALLOWED" <<< "$TCC_ROWS"
}

# tcc_user_allowed <service> <bundle id>: the app has the per-user permission, such as
# kTCCServiceMicrophone
tcc_user_allowed() {
    tcc_id_ok "$2" || return 1
    tcc_query user "SELECT auth_value FROM access WHERE service = '$1' AND client = '$2';" || return 2
    grep -qx "$TCC_ALLOWED" <<< "$TCC_ROWS"
}

# tcc_automation_allowed <bundle id> <target bundle id>...: the app may control each target with
# Apple events, which macOS asks about the first time it tries. Sets MANUAL_DETAIL to the others.
tcc_automation_allowed() {
    local client="$1" target missing=()
    shift
    tcc_id_ok "$client" || return 1
    tcc_query user "SELECT indirect_object_identifier, auth_value FROM access WHERE service = 'kTCCServiceAppleEvents' AND client = '$client';" ||
        return 2
    for target; do
        grep -qxF "$target|$TCC_ALLOWED" <<< "$TCC_ROWS" || missing+=("$target")
    done
    [ ${#missing[@]} -gt 0 ] || return 0
    MANUAL_DETAIL="$(printf '%s\n' "${missing[@]}" | join_lines ', ')"
    return 1
}

# login_item_state <bundle id> <app>: sets LOGIN_ITEM_STATE to enabled, disabled, or none, from the
# login items and background items macOS lists for you. A record is the app's when a field names its
# bundle id or path, which also finds a helper the app registers.
login_item_state() {
    LOGIN_ITEM_STATE=""
    if ! sudo_ready; then
        MANUAL_DETAIL="only root lists the login items; $ROOT_ONLY_TEXT, to check it"
        return 2
    fi
    if ! memo BTM_DUMP run_bounded 30 sudo -n sfltool dumpbtm > /dev/null 2>&1; then
        MANUAL_DETAIL="sudo sfltool dumpbtm failed"
        return 2
    fi
    LOGIN_ITEM_STATE="$(awk -v uid="$(id -u)" -v id="$1" -v app="$2" '
        function finish() {
            if (!match_me) return
            if (disposition ~ /(\[|, )enabled(,|\])/) state = "enabled"
            else if (state == "") state = "disabled"
        }
        /Records for UID/ { finish(); match_me = 0; mine = $NF == uid || $(NF - 2) == uid; next }
        /^ *#[0-9]+:/ { finish(); match_me = 0; disposition = ""; if (mine) records++; next }
        mine && /^ *(Identifier|Bundle Identifier|Parent Identifier|URL|Executable Path):/ {
            if (index($0, id) || index($0, app)) match_me = 1
        }
        mine && /^ *Disposition:/ { disposition = $0 }
        END {
            finish()
            if (!records) exit 2
            print (state == "" ? "none" : state)
        }' <<< "$BTM_DUMP")" && return 0
    MANUAL_DETAIL="couldn't read sfltool dumpbtm's list"
    return 2
}

# app_launches_at_login <app>
app_launches_at_login() {
    local id
    id="$(mac_app_id "$1")" || return 1
    login_item_state "$id" "$1" || return 2
    [ "$LOGIN_ITEM_STATE" == enabled ]
}

# app_has_accessibility <app>
app_has_accessibility() {
    local id
    id="$(mac_app_id "$1")" || return 1
    tcc_allowed kTCCServiceAccessibility "$id"
}
