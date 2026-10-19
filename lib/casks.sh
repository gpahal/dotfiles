# Helpers for Homebrew casks. The homebrew, claude-desktop, codex, and t3-code steps and
# scripts/upgrade.sh source it right after lib/common.sh, whose helpers it uses; don't run it.
# - cask_state says how a cask is installed (brew, gone, other, or missing) and where its app is.
# - install_cask installs a cask unless cask_state finds it there, and status_cask reports it.
# - cask_app_path, recorded_cask_app, and cask_receipt read brew's metadata for a cask's app.
# shellcheck shell=bash

# Install a Homebrew cask unless it, or the path it installs, is already there. Fails, saying
# how to get brew, when it's missing. Exits with brew's status when interrupted_status says a
# signal stopped it: brew catches Ctrl-C and exits 130, so the step's bash never sees the signal,
# and a caller's `|| result=1` would carry on. A third argument, cask_state's first field when
# the caller already has it, saves the brew calls cask_state makes.
install_cask() {
    local cask="$1" from="${3:-}" status=0
    require_cmd brew || return 1
    [ -n "$from" ] || IFS=$'\t' read -r from _ <<< "$(cask_state "$cask" "${2:-}")"
    case "$from" in
        brew) echo "  $cask already installed." ;;
        gone)
            echo "  brew lists $cask, but its app is gone; reinstalling it..."
            brew reinstall --cask "$cask" || status=$?
            ;;
        # brew install would fail on an existing app, or rerun a pkg cask's installer over it, and
        # `upgrade` skips casks brew doesn't list
        other) echo "  $cask already installed, but not by Homebrew, so upgrade won't update it." ;;
        *)
            echo "  Installing $cask..."
            brew install --cask "$cask" || status=$?
            ;;
    esac
    ! interrupted_status "$status" || exit "$status"
    return "$status"
}

# jq for the path of the app each cask in brew info --json=v2's output installs, or "" for a cask
# with no app, such as a font or one that runs an installer
CASK_APP_JQ='[.artifacts[] | objects | select(has("app")) | .target // ("/Applications/" + .app[0])][0] // ""'

# Print the path of the app a Homebrew cask installs, e.g. /Applications/Claude.app, or nothing
# without jq, so a caller falls back to where the app usually is
cask_app_path() {
    command -v jq &>/dev/null || return 0
    brew info --json=v2 --cask "$1" 2>/dev/null | jq -r ".casks[0] | $CASK_APP_JQ"
}

# The app each cask that runs an installer puts in place, as <cask>=<path>. brew's metadata lists
# no app for them.
CASK_PKG_APPS=("tailscale-app=/Applications/Tailscale.app" "logi-options+=/Applications/logioptionsplus.app"
    "elgato-stream-deck=/Applications/Elgato Stream Deck.app")

# Print the path of brew's install receipt for cask $1, which records what brew installed for it
cask_receipt() {
    echo "$(brew --caskroom 2>/dev/null)/$1/.metadata/INSTALL_RECEIPT.json"
}

# recorded_cask_app <cask> <app>: print the app path brew recorded when it installed <cask>, in
# the dir of <app>, the path the cask now gives. Fails when the install receipt names no app.
recorded_cask_app() {
    local name
    name="$(jq -er '[.uninstall_artifacts[] | objects | select(has("app"))
        | .target // (.app[1].target? // .app[0])][0] | strings' "$(cask_receipt "$1")" 2>/dev/null)" || return 1
    case "$name" in
        /*) echo "$name" ;;
        *) echo "${2%/*}/$name" ;;
    esac
}

# cask_state <cask> [<app>] [<listing>]: print how a Homebrew cask is installed, a tab, and the
# path of the app it installs: "brew" when brew lists it, "gone" when brew lists it but its app was
# deleted (macOS only), "other" when brew doesn't list it but the app is there, as when an app
# that auto-updates was installed outside brew, or "missing". <app> is the path the caller expects
# the app at, used when brew names none. <listing> is installed_cask_apps's output, which saves a
# brew call per cask; without it, brew is asked about this cask. Off macOS brew names no path, so
# a listed cask is never gone.
# e.g. IFS=$'\t' read -r state app <<< "$(cask_state raycast "" "$apps")"
cask_state() {
    local cask="$1" app="" listed=false entry state recorded
    if [ $# -ge 3 ]; then
        if app="$(printf '%s\n' "$3" |
            awk -F '\t' -v cask="$cask" '$1 == cask { print $2; found = 1 } END { exit !found }')"; then
            listed=true
        fi
    elif brew list --cask "$cask" &>/dev/null; then
        listed=true
        if is_macos; then
            app="$(cask_app_path "$cask")"
        fi
    fi
    if [ -z "$app" ] && { is_macos || ! "$listed"; }; then
        app="${2:-}"
    fi
    if is_macos && [ -z "$app" ]; then
        for entry in ${CASK_PKG_APPS[@]+"${CASK_PKG_APPS[@]}"}; do
            [ "${entry%%=*}" != "$cask" ] || app="${entry#*=}"
        done
        if [ -z "$app" ] && ! "$listed"; then
            app="$(cask_app_path "$cask" || true)"
        fi
    fi
    if "$listed"; then
        state=brew
        # The cask's current definition can name the app differently from the one brew installed,
        # as when T3 Code (Alpha) became T3 Code (Beta), so the app is gone only when the one the
        # install receipt recorded is gone too
        if [ -n "$app" ] && [ ! -e "$app" ]; then
            if recorded="$(recorded_cask_app "$cask" "$app")" && [ -e "$recorded" ]; then
                app="$recorded"
            else
                state=gone
            fi
        fi
    elif [ -n "$app" ] && [ -e "$app" ]; then
        state=other
    else
        state=missing
    fi
    printf '%s\t%s\n' "$state" "$app"
}

# Print an item for whether a Homebrew cask, or the path it installs, is there, given cask_state's
# arguments. Without brew, say so rather than report the cask missing.
status_cask() {
    local state
    status_require_cmd brew "$1 (cask)" || return 0
    IFS=$'\t' read -r state _ <<< "$(cask_state "$@")"
    case "$state" in
        brew) status_item ok "$1 (cask)" ;;
        gone) status_item missing "$1 (cask): brew lists it, but its app is gone; run brew reinstall --cask $1" ;;
        other) status_item ok "$1 (cask), installed outside Homebrew" ;;
        *) status_item missing "$1 (cask)" ;;
    esac
}
