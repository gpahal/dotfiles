# shellcheck shell=bash
# ufw for the ubuntu step. ubuntu/install.sh sets the constants.

# Checks the unit too: stopping it, or a failed boot, unloads the rules but leaves the files
ufw_enabled() {
    sbin_cmd ufw &>/dev/null &&
        grep -qx 'ENABLED=yes' "$UFW_CONF" 2>/dev/null &&
        grep -qxE 'DEFAULT_INPUT_POLICY="(DROP|REJECT)"' "$UFW_DEFAULTS" 2>/dev/null &&
        systemctl is-enabled -q ufw.service 2>/dev/null &&
        systemctl is-active -q ufw.service 2>/dev/null
}

# ufw_status <sudo flags>. Cached through a status_ufw run, which declares UFW_STATUS_CACHE_STATUS.
ufw_status() {
    memo UFW_STATUS_CACHE sudo "$@" ufw status 2>/dev/null
}

# ufw_stopped <sudo flags>: catches ufw-init stop, which ufw_enabled can't see
ufw_stopped() {
    local out
    out="$(ufw_status "$@")" || return 1
    [ "$(head -n 1 <<< "$out")" == "Status: inactive" ]
}

# IPV6=no leaves sshd open on the global IPv6 address
ufw_ipv6_on() {
    grep -qx 'IPV6=yes' "$UFW_DEFAULTS" 2>/dev/null
}

# ssh.socket's ports, from Listen lines such as "[::]:22 (Stream)", or 22 when it lists none
sshd_ports() {
    local ports
    ports="$(systemctl show ssh.socket -p Listen --value 2>/dev/null |
        sed -nE 's/^.*:([0-9]+) \(Stream\)$/\1/p' | sort -un)"
    echo "${ports:-22}"
}

# As `ufw status` lists them, spaces squeezed
ufw_wanted_rules() {
    local port range bridge
    for port in $(sshd_ports); do
        for bridge in "${DOCKER_BRIDGES[@]}"; do
            echo "$port/tcp on $bridge DENY Anywhere"
            echo "$port/tcp (v6) on $bridge DENY Anywhere (v6)"
        done
        for range in "${SSH_RANGES[@]}"; do
            echo "$port/tcp ALLOW $range"
        done
    done
    echo "Anywhere on tailscale0 ALLOW Anywhere"
    echo "$TAILSCALE_PORT/udp ALLOW Anywhere"
}

# Takes sudo's flags
ufw_rules() {
    local out
    out="$(ufw_status "$@")" || return 1
    sed -E 's/ +/ /g; s/ $//' <<< "$out"
}

# Takes sudo's flags. Returns 2 when ufw is on but its rules can't be read, 1 when anything's missing.
# shellcheck disable=SC2120 # apply in install.sh passes sudo's flags
ufw_configured() {
    local missing
    ufw_enabled || return 1
    missing="$(ufw_missing_rules "$@")" || return 2
    [ -z "$missing" ]
}

# Takes sudo's flags
ufw_missing_rules() {
    local rules rule
    rules="$(ufw_rules "$@")" || return 1
    while IFS= read -r rule; do
        grep -qxF -- "$rule" <<< "$rules" || echo "$rule"
    done < <(ufw_wanted_rules)
}

# Prints the prefix length of the $SSH_RANGES range holding the address
private_prefix() {
    local a b hextet
    case "$1" in
        *:*)
            # fe80::/10 is fe8 to feb
            hextet="0000${1%%:*}"
            hextet="${hextet:${#hextet}-4}"
            case "$hextet" in
                fd??) echo 8 ;;
                fe[89ab]?) echo 10 ;;
                *) return 1 ;;
            esac
            return 0
            ;;
    esac
    IFS=. read -r a b _ <<< "$1"
    [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] || return 1
    if [ "$a" -eq 10 ]; then
        echo 8
    elif [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; then
        echo 16
    else
        return 1
    fi
}

private_address() {
    private_prefix "$1" > /dev/null
}

# An unroutable address counts as outside, so ufw stays off and its session keeps working
outside_address() {
    local route dev
    ! private_address "${1%%\%*}" || return 1
    route="$(ip route get "${1%%\%*}" 2>/dev/null)" || return 0
    dev="$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<< "$route")"
    case "$dev" in tailscale0 | lo) return 1 ;; esac
}

# Fails when a RemoteHost isn't an address (UseDNS yes), since it can't match ss's
login_addresses() {
    local list id _ host
    list="$(loginctl list-sessions --no-legend 2>/dev/null)" || return 1
    while read -r id _; do
        [ -n "$id" ] || continue
        # A session that ended since the list doesn't count
        host="$(loginctl show-session "$id" -p RemoteHost --value 2>/dev/null)" || continue
        host="$(tr 'A-F' 'a-f' <<< "${host%%\%*}")"
        [ -n "$host" ] || continue
        [[ "$host" =~ ^[0-9a-f.:]+$ ]] || return 1
        echo "$host"
    done <<< "$list"
}

# Established connections that also match a logind session, so a scanner can't keep ufw off and a
# lingering tmux session alone doesn't count. Not SSH_CONNECTION, which goes stale in tmux; not
# ss -p, which needs root. When loginctl can't say, every connection counts.
outside_ssh_peers() {
    local port out peers="" peer outside="" logins
    for port in "$@"; do
        out="$(ss -Htn state established "( sport = :$port )" 2>/dev/null)" || return 1
        peers+="$(awk 'NF >= 2 {
            peer = $NF
            sub(/:[0-9]+$/, "", peer); gsub(/[][]/, "", peer); sub(/^::ffff:/, "", peer)
            print tolower(peer)
        }' <<< "$out")"$'\n'
    done
    while IFS= read -r peer; do
        [ -z "$peer" ] || ! outside_address "$peer" || outside+="$peer"$'\n'
    done < <(sort -u <<< "$peers")
    [ -n "$outside" ] || return 0
    if ! logins="$(login_addresses)"; then
        printf '%s' "$outside"
        return 0
    fi
    while IFS= read -r peer; do
        [ -z "$peer" ] || ! grep -qxF "${peer%%\%*}" <<< "$logins" || echo "$peer"
    done <<< "$outside"
}

# Runs where set -e is off, so each command checks its own failure
configure_ufw() {
    local ports port range bridge outside="" on=false
    # ufw rejects IPv6 rules under IPV6=no, leaving it half set up
    if [ -e "$UFW_DEFAULTS" ] && ! ufw_ipv6_on; then
        echo "  ufw doesn't filter IPv6, so the firewall is left unchanged: set IPV6=yes in $UFW_DEFAULTS," >&2
        echo "  run sudo ufw reload if ufw is on, then re-run the ubuntu step." >&2
        return 1
    fi
    ports="$(sshd_ports)"
    if ufw_enabled && ! ufw_stopped; then
        on=true
    fi
    # shellcheck disable=SC2086 # one port per word
    if ! "$on" && ! outside="$(outside_ssh_peers $ports)"; then
        echo "  Couldn't list the established SSH connections with ss, so the firewall is left unchanged." >&2
        return 1
    fi
    if [ -n "$outside" ]; then
        echo "  SSH connections come from $(join_lines ', ' <<< "$outside"), outside the private ranges and" >&2
        echo "  the tailnet, and the firewall would cut them off, so it's left unchanged. Re-run the step at" >&2
        echo "  the machine, over SSH from ${SSH_RANGES[*]}, or over Tailscale." >&2
        echo "  If the Mac connects over IPv6 (e.g. to $(hostname).local), connect to the machine's IPv4" >&2
        echo "  address (ip -4 addr) or, once Tailscale is up, its tailnet name, and re-run." >&2
        return 1
    fi
    if ! apt_installed ufw; then
        apt_install_fresh ufw || return 1
    fi
    "$on" || sudo ufw default deny incoming > /dev/null || return 1
    for port in $ports; do
        # Denies go first, since ufw takes the first match. prepend skips a rule ufw already has.
        for bridge in "${DOCKER_BRIDGES[@]}"; do
            sudo ufw prepend deny in on "$bridge" to any port "$port" proto tcp > /dev/null || return 1
        done
        for range in "${SSH_RANGES[@]}"; do
            sudo ufw allow from "$range" to any port "$port" proto tcp > /dev/null || return 1
        done
    done
    sudo ufw allow in on tailscale0 > /dev/null || return 1
    sudo ufw allow "$TAILSCALE_PORT/udp" > /dev/null || return 1
    "$on" && return 0
    sudo ufw --force enable > /dev/null || return 1
    # ufw enable leaves a stopped ufw.service stopped
    sudo systemctl enable --now -q ufw.service
}

status_ufw() {
    # shellcheck disable=SC2034 # memo reads the caches
    local ufw=0 UFW_STATUS_CACHE="" UFW_STATUS_CACHE_STATUS=""
    local rules="ufw rules allowing SSH from the private ranges, tailscale0, and Tailscale's $TAILSCALE_PORT/udp, and denying it on Docker's bridges"
    if [ -e "$UFW_DEFAULTS" ] && ! ufw_ipv6_on; then
        status_item missing "ufw filters IPv6: $UFW_DEFAULTS lacks IPV6=yes, so sshd answers on the global IPv6 address; set it, run sudo ufw reload if ufw is on, then re-run the ubuntu step"
    fi
    if ! ufw_enabled; then
        status_item missing "ufw on, denying incoming connections except SSH from the private ranges, tailscale0, and Tailscale's $TAILSCALE_PORT/udp"
        return 0
    fi
    ! sudo_ready || ufw_status -n > /dev/null || true
    if sudo_ready && ufw_stopped -n; then
        status_item missing "ufw on, denying incoming connections: ufw status says it's inactive, so its rules aren't loaded (re-run the ubuntu step)"
        return 0
    fi
    status_item ok "ufw on, denying incoming connections"
    ! ufw_ipv6_on || status_item ok "ufw filters IPv6"
    if ! openssh_installed; then
        status_item missing "$rules: openssh-server isn't installed"
        return 0
    fi
    if ! sudo_ready; then
        status_item unverified "$rules (only root can read them; run sudo -v, then status, to check them)"
        return 0
    fi
    ufw_configured -n || ufw=$?
    case "$ufw" in
        0) status_item ok "$rules" ;;
        1) status_item missing "$rules (re-run the ubuntu step)" ;;
        *) status_item unknown "$rules: sudo ufw status fails, so they can't be checked" ;;
    esac
}
