# shellcheck shell=bash
# Pushing to a ntfy topic, for ubuntu/setup-alerts.sh and ubuntu/health-alert.sh. smartd's hook
# (ubuntu/smartd-notify.sh), which runs as root, and upsmon's notifier (ubuntu/ups-notify.sh),
# which runs as the nut user, run away from the repo and source an installed copy at
# /usr/local/lib/dotfiles/ntfy.sh, so this file mustn't depend on the repo. It only defines
# functions.

# ntfy_push <url> <title> <message> [header...]
# The URL reaches curl as config on stdin, with its backslashes and double quotes escaped, since
# any user can read a process's arguments, and the topic is the URL's only secret
# e.g. ntfy_push "$url" "Alerts from box" "A test." "Tags: white_check_mark"
# --data-raw, since --data-binary would read a message starting with @, which smartd and upsmon
# pass on, as a file name, and push that file's contents.
ntfy_push() {
    local url="$1" title="$2" message="$3" header headers=()
    shift 3
    for header in "$@"; do
        headers+=(-H "$header")
    done
    printf 'url = "%s"\n' "$(printf '%s' "$url" | sed 's/[\\"]/\\&/g')" |
        curl -fsS --max-time 10 -H "Title: $title" ${headers[@]+"${headers[@]}"} \
            --data-raw "$message" -K - > /dev/null
}
