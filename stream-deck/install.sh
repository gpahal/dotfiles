#!/bin/bash
set -euo pipefail

# Install the Stream Deck plugin and profiles, or on Ubuntu the daemon that drives the deck.
# On macOS a temp HOME doesn't isolate it: it quits and reopens the running Stream Deck when the
# plugin or its profiles change. On Ubuntu it installs a root service with sudo and turns on a GNOME
# extension and a user service in your session whatever HOME is: test it in an Ubuntu VM with a
# GNOME desktop.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=../lib/gnome.sh
source "$DOTFILES_DIR/lib/gnome.sh"

# pnpm, from Homebrew, and Node, from mise, run the Ubuntu daemon
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew runtimes"

PLUGIN=com.gpahal.dotfiles.sdPlugin
PLUGIN_DIR="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/$PLUGIN"

# Leaves out .DS_Store and node_modules, which Finder and pnpm write, so neither counts as stale
file_list() {
    (cd "$1" && find . -name node_modules -prune -o -type f ! -name .DS_Store -print | sed 's|^\./||')
}

plugin_file_list() {
    file_list "${1:-$DOTFILES_DIR/stream-deck/$PLUGIN}"
}

# stale_list <dir> <list-cmd...>: files in <dir> that the list doesn't name
stale_list() {
    local dir="$1"
    shift
    [ -d "$dir" ] || return 0
    LC_ALL=C comm -13 <("$@" | LC_ALL=C sort) <(file_list "$dir" | LC_ALL=C sort)
}

# status_stale <dir> <why> <list-cmd...>
status_stale() {
    local dir="$1" why="$2" file shown="$1"
    shift 2
    # shellcheck disable=SC2088 # shown, not expanded
    [[ "$dir" != "$HOME/"* ]] || shown="~/${dir#"$HOME"/}"
    while IFS= read -r file; do
        status_item missing "$shown/$file: $why; re-run the stream-deck step to remove it"
    done < <(stale_list "$dir" "$@")
}

# remove_stale <dir> <whose> <list-cmd...> sets COPIED when it removes a file, and removes the
# folders that leaves empty
remove_stale() {
    local dir="$1" whose="$2" file status=0
    shift 2
    [ -d "$dir" ] || return 0
    while IFS= read -r file; do
        if rm -f "$dir/$file"; then
            echo "  Removed $file, which $whose no longer has"
            COPIED=true
        else
            status=1
        fi
    done < <(stale_list "$dir" "$@")
    find "$dir" -mindepth 1 -depth -type d -empty ! -path "$dir/node_modules" ! -path "$dir/node_modules/*" \
        -delete 2> /dev/null || true
    return "$status"
}

each_plugin_file() {
    local action="$1" file status=0
    while IFS= read -r file; do
        "$action" "$DOTFILES_DIR/stream-deck/$PLUGIN/$file" "$PLUGIN_DIR/$file" || status=1
    done < <(plugin_file_list)
    return "$status"
}

# Notes in PLUGIN_CHANGED that Stream Deck needs a restart, and in CHANGED_PAGES each profile
# archive that changed
copy_plugin_file() {
    local page
    COPIED=false
    copy_file "$@" || return 1
    "$COPIED" || return 0
    PLUGIN_CHANGED=true
    case "$2" in
        "$PLUGIN_DIR"/profiles/*.streamDeckProfile)
            page="${2##*/}"
            page="${page%.streamDeckProfile}"
            CHANGED_PAGES="$CHANGED_PAGES $(printf '%s' "$page" | tr '[:upper:]' '[:lower:]')"
            ;;
    esac
}

# The installed profiles to delete: stale copies of the plugin's, which Stream Deck reinstalls,
# and other profiles for the deck
profiles_to_delete() {
    local state dir text
    # shellcheck disable=SC2086 # a list of pages
    while IFS="$SEP" read -r state dir text; do
        case "$state" in
            reinstall | delete) printf '%s%s%s\n' "$dir" "$SEP" "$text" ;;
        esac
    done < <(profile_plan $CHANGED_PAGES)
}

delete_profiles() {
    local dir text status=0
    while IFS="$SEP" read -r dir text; do
        if delete_profile "$dir"; then
            echo "  Deleted ${dir##*/} from Stream Deck's profiles: ${text%: the next run *}"
        else
            status=1
        fi
    done < <(profiles_to_delete)
    return "$status"
}

status_profiles() {
    local state dir text
    status_require_cmd jq "Stream Deck's profiles" || return 0
    while IFS="$SEP" read -r state dir text; do
        case "$state" in
            ok) status_item ok "$text" ;;
            *) status_item missing "$text" ;;
        esac
    done < <(profile_plan)
}

# Stream Deck writes its profiles from memory when it quits, so they change only while it's quit.
# SIGTERM is safe: it saves as it goes. open fails with -600 while the old process quits and
# briefly after, hence the wait and retries.
update_stream_deck() {
    local running=true opened=false status=0 killed=0
    pkill -x "Stream Deck" || killed=$?
    # pkill exits 1 when nothing matched, and 2 or 3 when it failed, so Stream Deck may still run
    if [ "$killed" -eq 1 ]; then
        running=false
    elif [ "$killed" -ne 0 ]; then
        echo "  Couldn't quit Stream Deck (pkill exited $killed); quit it and re-run the step to load the plugin and its profiles." >&2
        return 1
    elif ! wait_until_quit -x "Stream Deck"; then
        echo "  Stream Deck didn't quit; quit it and re-run the step to load the plugin and its profiles." >&2
        return 1
    fi
    delete_profiles || status=1
    if ! "$running"; then
        echo "  Stream Deck isn't running; it loads the plugin and its profiles when it starts."
        return "$status"
    fi
    for _ in 1 2 3 4 5; do
        if open -g -b com.elgato.StreamDeck; then
            opened=true
            break
        fi
        sleep 1
    done
    if ! "$opened"; then
        echo "  Couldn't reopen Stream Deck. Open it to load the plugin and its profiles." >&2
        return 1
    fi
    echo "  Restarted Stream Deck to load the plugin and its profiles."
    return "$status"
}

# shellcheck source=lib/profiles.sh
source "$DOTFILES_DIR/stream-deck/lib/profiles.sh"
# shellcheck source=lib/ubuntu.sh
source "$DOTFILES_DIR/stream-deck/lib/ubuntu.sh"

status() {
    if is_ubuntu; then
        status_ubuntu
        return
    fi
    each_plugin_file status_file
    status_stale "$PLUGIN_DIR" "the repo's plugin no longer has it" plugin_file_list
    status_profiles
}

apply() {
    if is_ubuntu; then
        apply_ubuntu
        return
    fi
    echo "Installing the Stream Deck plugin and its profiles..."
    require_cmd jq || return 1
    local status=0
    PLUGIN_CHANGED=false
    CHANGED_PAGES=""
    each_plugin_file copy_plugin_file || status=1
    COPIED=false
    remove_stale "$PLUGIN_DIR" "the repo's plugin" plugin_file_list || status=1
    ! "$COPIED" || PLUGIN_CHANGED=true
    if "$PLUGIN_CHANGED" || [ -n "$(profiles_to_delete)" ]; then
        update_stream_deck || status=1
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
