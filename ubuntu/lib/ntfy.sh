# shellcheck shell=bash
# The root hooks source an installed copy, so this file mustn't depend on the repo.

# ntfy_push <url> <title> <message> [header...]
# The URL goes through stdin config to keep the topic out of ps. --data-raw, since --data-binary
# reads a message starting with @ as a file. -q (must be first) skips root's ~/.curlrc.
# --proto keeps the push on https, whatever URL the file holds.
ntfy_push() {
    local url="$1" title="$2" message="$3" header headers=()
    shift 3
    for header in "$@"; do
        headers+=(-H "$header")
    done
    printf 'url = "%s"\n' "$(printf '%s' "$url" | sed 's/[\\"]/\\&/g')" |
        curl -q -fsS --proto '=https' --max-time 10 -H "Title: $title" ${headers[@]+"${headers[@]}"} \
            --data-raw "$message" -K - > /dev/null
}

# ntfy_hook_push <log tag> <what> <title> <message> [header...]
# Logs a failure without the URL, and always succeeds.
ntfy_hook_push() {
    local tag="$1" what="$2" out
    shift 2
    out="$(ntfy_push "$(head -n 1 "$NTFY_URL_FILE")" "$@" 2>&1)" ||
        logger -t "$tag" -- "couldn't push $what to ntfy: ${out:-curl failed}" 2>/dev/null || true
}
