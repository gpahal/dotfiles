# shellcheck shell=bash
# shellcheck disable=SC2034 # the scripts that source this file read them
# The ntfy server's paths and helpers, for the ntfy step and just ntfy-user. Source after
# lib/common.sh and ubuntu/lib/paths.sh, which sets NTFY_LOCAL_URL and NTFY_FUNNEL_PORT.

NTFY_CONFIG=/etc/ntfy/server.yml
NTFY_UNIT=ntfy.service
# The users just ntfy-user creates, and the labels of machine's tokens
NTFY_MACHINE_USER=machine
NTFY_TOKEN_LABELS=(desktop macbook web-service)
NTFY_TOKEN_RE='tk_[-_A-Za-z0-9]{29}'

# Cached through a memo scope, once called outside a $( )
ntfy_tailscale_status() {
    memo NTFY_TAILSCALE_STATUS tailscale status --json 2>/dev/null
}

# This machine's MagicDNS name, without the trailing dot
ntfy_host() {
    local status
    status="$(ntfy_tailscale_status)" || return 1
    jq -er '.Self.DNSName // "" | rtrimstr(".") | select(. != "")' <<< "$status" 2>/dev/null
}

ntfy_public_url() {
    local host
    host="$(ntfy_host)" || return 1
    echo "https://$host:$NTFY_FUNNEL_PORT"
}

# tailscale_cap <name>: the tailnet grants this machine the capability, such as https or funnel
tailscale_cap() {
    local status
    status="$(ntfy_tailscale_status)" || return 1
    jq -e --arg cap "$1" '(.Self.CapMap // {} | has($cap)) or ((.Self.Capabilities // []) | index($cap))' \
        <<< "$status" &>/dev/null
}

ntfy_healthy() {
    curl -fsS --max-time 5 "$NTFY_LOCAL_URL/v1/health" 2>/dev/null | jq -e '.healthy == true' &>/dev/null
}

# Waits up to 10 s for a server that just started or restarted
ntfy_wait_healthy() {
    local i=0
    until ntfy_healthy; do
        [ "$i" -lt 20 ] || return 1
        sleep 0.5
        i=$((i + 1))
    done
}
