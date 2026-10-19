# shellcheck shell=bash
# Settings merged into JSON files a desktop app also writes, shared by the claude-desktop and
# t3-code steps, which source this file after lib/common.sh. It only defines functions.

# merge_app_json <app> <already message> <set message> <file> <jq filter> [<file> <jq filter>...]
# Merge each filter into its file, as json_merge does, while the app is quit, since it would write
# over the files as it ran or quit. Prints the already message, changing nothing, when every file
# has its settings. Otherwise asks to quit the app (ensure_app_quit), leaves the files alone when it
# keeps running, and prints the set message once every merge is done. Fails when a merge does. A
# message may run to several lines, each of which is indented.
# e.g. merge_app_json Claude "Its settings are already set" "Set its settings" "$config" "$filter"
merge_app_json() {
    local app="$1" already="$2" done="$3" i
    shift 3
    for ((i = 1; i < $#; i += 2)); do
        json_applied "${@:i:1}" "${@:i+1:1}" || break
    done
    if [ "$i" -ge $# ]; then
        echo "  ${already//$'\n'/$'\n'  }"
        return 0
    fi
    ensure_app_quit "$app" || return 0
    for ((i = 1; i < $#; i += 2)); do
        json_merge "${@:i:1}" "${@:i+1:1}" || return 1
    done
    echo "  ${done//$'\n'/$'\n'  }"
}
