# Helpers for Homebrew casks. Source after lib/common.sh; don't run it.
# shellcheck shell=bash

# install_cask <cask> [app] [state]: [state] is cask_state's first field, if the caller has it.
# Exits on interrupt: brew catches Ctrl-C and exits 130, which a caller's || would swallow.
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
# brew install would fail on an existing app, or rerun a pkg cask's installer, and upgrade skips
# casks brew doesn't list
        other) echo "  $cask already installed, but not by Homebrew, so upgrade won't update it." ;;
        *)
            echo "  Installing $cask..."
            brew install --cask "$cask" || status=$?
            ;;
    esac
    ! interrupted_status "$status" || exit "$status"
    return "$status"
}

# "" for a cask with no app, such as a font or a pkg installer
CASK_APP_JQ='[.artifacts[] | objects | select(has("app")) | .target // ("/Applications/" + .app[0])][0] // ""'

# Prints nothing without jq, so a caller falls back to where the app usually is
cask_app_path() {
    command -v jq &>/dev/null || return 0
    brew info --json=v2 --cask "$1" 2>/dev/null | jq -r ".casks[0] | $CASK_APP_JQ"
}

# Pkg casks, whose metadata names no app
CASK_PKG_APPS=("tailscale-app=/Applications/Tailscale.app" "logi-options+=/Applications/logioptionsplus.app"
    "elgato-stream-deck=/Applications/Elgato Stream Deck.app")

cask_receipt() {
    echo "$(brew --caskroom 2>/dev/null)/$1/.metadata/INSTALL_RECEIPT.json"
}

# recorded_cask_app <cask> <app>: the app path in brew's install receipt, relative to <app>'s dir
recorded_cask_app() {
    local name
    name="$(jq -er '[.uninstall_artifacts[] | objects | select(has("app"))
        | .target // (.app[1].target? // .app[0])][0] | strings' "$(cask_receipt "$1")" 2>/dev/null)" || return 1
    case "$name" in
        /*) echo "$name" ;;
        *) echo "${2%/*}/$name" ;;
    esac
}

# cask_state <cask> [app] [listing]: prints "<state>\t<app path>", state being brew, gone (listed
# but app deleted, macOS only), other (app present, not listed), or missing. [app] is the
# fallback path; [listing] is installed_cask_apps's output, saving a brew call per cask.
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
# The current cask can name the app differently from the installed one (T3 Code Alpha to Beta),
# so it's gone only when the receipt's app is gone too
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
