# Helpers for Homebrew casks. Source after lib/common.sh; don't run it.
# cask_state, status_cask, and install_cask take these options before the cask:
#   --renamed <glob>: when brew's name for the cask's app is gone, an app matching the glob beside
#     it is the cask's, as when an app renames itself as it updates before the cask catches up
#   --except <glob>: an app matching this isn't, such as another channel's
# shellcheck shell=bash

# Moves the leading --renamed and --except options into the caller's opts
_cask_opts() {
    _cask_shift=0
    while [ "${1:-}" == --renamed ] || [ "${1:-}" == --except ]; do
        opts+=("$1" "$2")
        shift 2
        _cask_shift=$((_cask_shift + 2))
    done
}

# install_cask [options] <cask> [app] [state]: [state] and [app] are cask_state's fields, if the
# caller has them. Exits on interrupt: brew catches Ctrl-C and exits 130, which a caller's ||
# would swallow.
install_cask() {
    local opts=() _cask_shift
    _cask_opts "$@"
    shift "$_cask_shift"
    local cask="$1" app="${2:-}" from="${3:-}" status=0
    require_cmd brew || return 1
    [ -n "$from" ] || IFS=$'\t' read -r from app <<< "$(cask_state ${opts[@]+"${opts[@]}"} "$cask" "$app")"
    case "$from" in
        brew) echo "  $cask already installed." ;;
        renamed) echo "  $cask already installed, as ${app##*/}." ;;
        gone)
            echo "  brew lists $cask, but its app is gone; reinstalling it..."
            brew reinstall --cask "$cask" || status=$?
            ;;
        # brew install would fail on an existing app, or rerun a pkg cask's installer, and
        # upgrade skips casks brew doesn't list
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

# Prints nothing without jq, so a caller falls back to where the app usually is. Fails with brew's
# status when brew info fails, so a failure can't pass for a cask with no app.
cask_app_path() {
    local info
    command -v jq &>/dev/null || return 0
    info="$(brew info --json=v2 --cask "$1" 2>/dev/null)" || return
    jq -r ".casks[0] | $CASK_APP_JQ" <<< "$info"
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

# brew list --cask <cask> loads Ruby and posts analytics, and the plain list doesn't
_cask_listed() {
    local list
    list="$(brew list --cask -1 2>/dev/null)" || return 1
    case $'\n'"$list"$'\n' in
        *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    return 1
}

# cask_state [options] <cask> [app] [listing]: prints "<state>\t<app path>", state being brew,
# gone (listed but app deleted, macOS only), renamed (listed, with the app --renamed found), other
# (app present, not listed), or missing. [app] is the fallback path; [listing] is
# installed_cask_apps's output, saving a brew call per cask.
cask_state() {
    local renamed="" except=""
    while [ "${1:-}" == --renamed ] || [ "${1:-}" == --except ]; do
        if [ "$1" == --renamed ]; then renamed="$2"; else except="$2"; fi
        shift 2
    done
    local cask="$1" app="" listed=false entry state recorded found
    if [ $# -ge 3 ]; then
        if app="$(printf '%s\n' "$3" |
            awk -F '\t' -v cask="$cask" '$1 == cask { print $2; found = 1 } END { exit !found }')"; then
            listed=true
        fi
    elif _cask_listed "$cask"; then
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
        # An app can rename itself as it updates, so the current cask may name it differently from
        # the installed one. It's gone only when the receipt's app is gone too.
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
    if [ -n "$renamed" ] && { [ "$state" == gone ] || [ "$state" == missing ]; } &&
        found="$(cask_app_matching "$(dirname "${app:-/Applications/x}")" "$renamed" "$except")"; then
        app="$found"
        if [ "$state" == gone ]; then state=renamed; else state=other; fi
    fi
    printf '%s\t%s\n' "$state" "$app"
}

# cask_app_matching <dir> <glob> [except glob]: the first app in <dir> the glob matches. case, not
# [[ ]], which bash 4.1 and later match with extglob, so *(...) would mean something else.
cask_app_matching() {
    local app
    for app in "$1"/*.app; do
        [ -d "$app" ] || continue
        # shellcheck disable=SC2254 # globs
        case "${app##*/}" in
            # / is in no app's name
            ${3:-/}) ;;
            $2)
                echo "$app"
                return 0
                ;;
        esac
    done
    return 1
}

# status_cask [options] <cask> [app] [listing]
status_cask() {
    local opts=() _cask_shift state app
    _cask_opts "$@"
    shift "$_cask_shift"
    status_require_cmd brew "$1 (cask)" || return 0
    IFS=$'\t' read -r state app <<< "$(cask_state ${opts[@]+"${opts[@]}"} "$@")"
    case "$state" in
        brew) status_item ok "$1 (cask)" ;;
        renamed) status_item ok "$1 (cask), as ${app##*/}" ;;
        gone) status_item missing "$1 (cask): brew lists it, but its app is gone; run brew reinstall --cask $1" ;;
        other) status_item ok "$1 (cask), installed outside Homebrew" ;;
        *) status_item missing "$1 (cask)" ;;
    esac
}
