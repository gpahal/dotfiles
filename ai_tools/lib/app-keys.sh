# shellcheck shell=bash
# Checks the settings keys a step writes against the installed app, so a release that renames or
# drops one shows in --status without the repo naming a version. Electron apps keep their code
# uncompressed in app.asar, so a key the app reads appears in it as text.

# A key no app has; finding it means the search can't tell
APP_KEYS_MADE_UP=dotfilesNoSuchAppSetting

# jq_filter_keys <jq filter>: prints each .name the filter sets, one per line
jq_filter_keys() {
    printf '%s\n' "$1" | grep -oE '\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\.//' | sort -u
}

# deb_bundle <package>: prints the app.asar the package installed
deb_bundle() {
    dpkg-query -L "$1" 2> /dev/null | grep -m 1 '/app\.asar$'
}

# status_app_keys <what> <bundle> <key>...: reports whether the bundle has every key. An empty or
# missing bundle is unverified, as the app's own status item reports it missing.
status_app_keys() {
    local what="$1" bundle="$2" key missing=""
    shift 2
    if status_for_alerts; then
        return 0
    fi
    if [ -z "$bundle" ] || [ ! -f "$bundle" ]; then
        status_item unverified "$what: couldn't find the installed app's app.asar"
        return 0
    fi
    if LC_ALL=C grep -qaF -- "$APP_KEYS_MADE_UP" "$bundle"; then
        status_item unknown "$what: the search for keys in $bundle found a made-up one, so it can't tell"
        return 0
    fi
    # A grep per key: macOS's grep takes half a minute over an app.asar with -o and several -F
    # patterns, and -q stops at the first match
    for key in "$@"; do
        LC_ALL=C grep -qaF -- "$key" "$bundle" || missing="$missing $key"
    done
    if [ -n "$missing" ]; then
        status_item missing "$what: the installed app lacks$missing; it may have renamed them, so update the step"
    else
        status_item ok "$what"
    fi
}
