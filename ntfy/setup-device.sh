#!/bin/bash
set -euo pipefail

# Save this Mac's ntfy token, so its notifier shows the desktop server's alerts and agenda.
# The token comes from just ntfy-user on the desktop. It's read from the terminal, never an
# argument, and checked against the server before it's saved. With the token as default-token,
# ntfy publish works on the Mac too, for alerts it may send later.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../ubuntu/lib/paths.sh
source "$DOTFILES_DIR/ubuntu/lib/paths.sh"
# shellcheck source=lib/server.sh
source "$DOTFILES_DIR/ntfy/lib/server.sh"
# shellcheck source=lib/client.sh
source "$DOTFILES_DIR/ntfy/lib/client.sh"

NTFY_AGENT_LABEL=dotfiles.ntfy-subscribe
# The desktop's Tailscale hostname, the machine running the ntfy step's server
NTFY_SERVER_HOSTNAME=desktop

usage() {
    echo "Usage: bash ntfy/setup-device.sh [<server name>] (or: just ntfy-device [<server name>])"
    echo "Asks for the macbook token that just ntfy-user printed on the desktop, checks it against"
    echo "the server, and saves it in $(ntfy_client_config) (mode 600), which the ntfy step's"
    echo "notifier reads. The server name is the desktop's full tailnet name, such as"
    echo "$NTFY_SERVER_HOSTNAME.<tailnet>.ts.net; by default, the tailnet machine named $NTFY_SERVER_HOSTNAME."
    echo "macOS only."
}

# The peer whose HostName is desktop, from this Mac's view of the tailnet
default_server_name() {
    local names
    names="$(tailscale status --json 2>/dev/null | jq -r --arg name "$NTFY_SERVER_HOSTNAME" \
        '[.Peer // {} | .[] | select((.HostName | ascii_downcase) == $name) | .DNSName | rtrimstr(".")] | unique[]' \
        2>/dev/null)" || return 1
    [ -n "$names" ] && [ "$(wc -l <<< "$names" | tr -d ' ')" -eq 1 ] || return 1
    echo "$names"
}

read_token() {
    local input=""
    if [ -t 0 ]; then
        read -rs -p "macbook token from just ntfy-user (hidden): " input || true
        echo >&2
    else
        read -r input || true
    fi
    printf '%s' "${input//[[:space:]]/}"
}

# The token goes through stdin config, out of ps
token_accepted() {
    local code
    code="$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\n' "$1/v1/account" "$2" |
        curl -q -s -o /dev/null -w '%{http_code}' --max-time 10 -K - 2>/dev/null)" || true
    [ "$code" == 200 ] && return 0
    echo "  The server at $1 answered ${code:-nothing} (HTTP), so the token wasn't saved." >&2
    return 1
}

main() {
    local name url token re="^$NTFY_TOKEN_RE\$" COPIED=false
    case "${1:-}" in
        -h | --help)
            usage
            return 0
            ;;
    esac
    [ $# -le 1 ] || {
        usage >&2
        return 2
    }
    if ! is_macos; then
        echo "just ntfy-device is for a Mac. On the machine running ntfy's server, run just ntfy-user." >&2
        return 1
    fi
    require_cmd curl || return 1
    require_cmd jq || return 1
    name="${1:-}"
    if [ -z "$name" ] && ! name="$(default_server_name)"; then
        echo "Couldn't find one tailnet machine named $NTFY_SERVER_HOSTNAME. Pass the server's full name:" >&2
        echo "  just ntfy-device $NTFY_SERVER_HOSTNAME.<tailnet>.ts.net" >&2
        return 1
    fi
    url="https://$name:$NTFY_FUNNEL_PORT"
    echo "ntfy server: $url"
    token="$(read_token)"
    if ! [[ "$token" =~ $re ]]; then
        echo "  That isn't an ntfy token (tk_ and 29 more characters)." >&2
        return 1
    fi
    token_accepted "$url" "$token" || return 1
    write_client_config "$(ntfy_client_config)" "$(ntfy_client_yaml "$url" "$token")" || return 1
    if "$COPIED"; then
        echo "  Saved it in $(shown_path "$(ntfy_client_config)")."
    else
        echo "  Already saved in $(shown_path "$(ntfy_client_config)")."
    fi
    if launchctl print "gui/$(id -u)/$NTFY_AGENT_LABEL" &> /dev/null; then
        if "$COPIED"; then
            launchctl kickstart -k "gui/$(id -u)/$NTFY_AGENT_LABEL" || return 1
            echo "  Restarted the notifier."
        fi
        echo "  Run ntfy publish alerts test on the desktop: a notification shows here. The first time,"
        echo "  allow notifications for terminal-notifier when macOS asks."
    else
        echo "  The notifier isn't loaded yet. Run bash setup.sh ntfy." >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
