# shellcheck shell=bash

# merge_app_json <app> <already msg> <set msg> <file> <jq filter> [<file> <jq filter>...]
# Merges only while the app is quit, since it rewrites the files as it runs or quits.
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
