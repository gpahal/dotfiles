# shellcheck shell=bash
# Pushing to a ntfy topic, for ubuntu/setup-alerts.sh and ubuntu/health-alert.sh. smartd's hook
# (ubuntu/smartd-notify.sh), which runs as root, and upsmon's notifier (ubuntu/ups-notify.sh),
# which runs as the nut user, run away from the repo and source an installed copy at
# /usr/local/lib/dotfiles/ntfy.sh, so this file mustn't depend on the repo.

# ntfy_push <url> <title> <message> [header...]
# The URL reaches curl as config on stdin, with its backslashes and double quotes escaped, rather
# than as an argument. That only keeps the topic, the URL's only secret, out of ps listings and
# diagnostics: any local user can read the URL file itself (see save_url in setup-alerts.sh).
# e.g. ntfy_push "$url" "Alerts from box" "A test." "Tags: white_check_mark"
# --data-raw, since --data-binary would read a message starting with @, which smartd and upsmon
# pass on, as a file name, and push that file's contents. -q, which must come first, skips
# ~/.curlrc, root's for smartd's hook, which could log the URL or send it through a proxy.
ntfy_push() {
    local url="$1" title="$2" message="$3" header headers=()
    shift 3
    for header in "$@"; do
        headers+=(-H "$header")
    done
    printf 'url = "%s"\n' "$(printf '%s' "$url" | sed 's/[\\"]/\\&/g')" |
        curl -q -fsS --max-time 10 -H "Title: $title" ${headers[@]+"${headers[@]}"} \
            --data-raw "$message" -K - > /dev/null
}

# ntfy_hook_push <log tag> <what> <title> <message> [header...]: push for a hook, to the URL on
# the first line of $NTFY_URL_FILE, which the hook sets. A failure goes to the journal under <log
# tag>, as "couldn't push <what> to ntfy: <curl's error>", which leaves out the URL, whose topic is
# its only secret. Always succeeds, so a hook exits 0 and its caller reports no failure.
# e.g. ntfy_hook_push dotfiles-ups "the UPS event" "$title" "$message" "Priority: high"
ntfy_hook_push() {
    local tag="$1" what="$2" out
    shift 2
    out="$(ntfy_push "$(head -n 1 "$NTFY_URL_FILE")" "$@" 2>&1)" ||
        logger -t "$tag" -- "couldn't push $what to ntfy: ${out:-curl failed}" 2>/dev/null || true
}
