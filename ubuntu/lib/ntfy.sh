# shellcheck shell=bash
# The root hooks source an installed copy, so this file mustn't depend on the repo.

# Escapes a value for a curl config line's double quotes
_ntfy_config_value() {
    printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

# The ntfy step's server, paths.sh's NTFY_LOCAL_URL, which the root hooks don't source
NTFY_PUSH_SERVER=http://127.0.0.1:2586

# ntfy_push <url> <title> <message> [header...]
# Pushes only to this machine's ntfy server, with the token in NTFY_TOKEN_FILE, so the token never
# leaves the machine. Any other URL, such as an older ntfy.sh topic, fails without a request, and
# names only its host, since such a topic was its secret. The URL and token go through stdin config
# to keep them out of ps. --data-raw, since --data-binary reads a message starting with @ as a file.
# -q (must be first) skips root's ~/.curlrc.
ntfy_push() {
    local url="$1" title="$2" message="$3" header headers=() token="" host
    shift 3
    case "$url" in
        "$NTFY_PUSH_SERVER"/*) ;;
        *)
            host="${url#*://}"
            echo "won't push to ${host%%/*}: the alerts only go to this machine's ntfy server; run just alerts" >&2
            return 1
            ;;
    esac
    if [ -n "${NTFY_TOKEN_FILE:-}" ] && [ -r "$NTFY_TOKEN_FILE" ]; then
        token="$(head -n 1 "$NTFY_TOKEN_FILE")"
    fi
    if [ -z "$token" ]; then
        echo "no token in ${NTFY_TOKEN_FILE:-the token file}, or it can't be read; run just alerts" >&2
        return 1
    fi
    for header in "$@"; do
        headers+=(-H "$header")
    done
    printf 'url = "%s"\nheader = "Authorization: Bearer %s"\n' "$(_ntfy_config_value "$url")" \
        "$(_ntfy_config_value "$token")" |
        curl -q -fsS --proto '=http' --max-time 10 -H "Title: $title" ${headers[@]+"${headers[@]}"} \
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
