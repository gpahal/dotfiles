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

# Caches sudo ufw status and sshd -T for a status_ufw run, in variables the caller declares local.
cache_ufw_status() {
    local out status=0
    out="$(sudo "$@" ufw status 2>/dev/null)" || status=$?
    UFW_STATUS_CACHE="$out" UFW_STATUS_STATUS="$status"
}

# ufw_status <sudo flags>
ufw_status() {
    if [ -n "${UFW_STATUS_STATUS:-}" ]; then
        printf '%s\n' "$UFW_STATUS_CACHE"
        return "$UFW_STATUS_STATUS"
    fi
    sudo "$@" ufw status 2>/dev/null
}

cache_sshd_dump() {
    local out status=0
    out="$(sudo "$@" "$SSHD_BIN" -T 2>/dev/null)" || status=$?
    SSHD_DUMP_CACHE="$out" SSHD_DUMP_STATUS="$status"
}

# sshd_dump <sudo flags>: sshd's effective config
sshd_dump() {
    if [ -n "${SSHD_DUMP_STATUS:-}" ]; then
        printf '%s\n' "$SSHD_DUMP_CACHE"
        return "$SSHD_DUMP_STATUS"
    fi
    sudo "$@" "$SSHD_BIN" -T 2>/dev/null
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

# Listen is e.g. "[::]:22 (Stream)"
ssh_socket_ports() {
    systemctl is-active -q ssh.socket 2>/dev/null || return 0
    systemctl show ssh.socket -p Listen --value 2>/dev/null | sed -nE 's/^.*:([0-9]+) \(Stream\)$/\1/p'
}

# sshd_ports <sudo flags>. ssh.socket can listen on a port sshd's config doesn't name.
sshd_ports() {
    local config
    [ -d "$SSHD_RUN_DIR" ] || return 1
    config="$(sshd_dump "$@")" || return 1
    {
        awk '
            $1 == "port" { print $2 }
            $1 == "listenaddress" { n = split($2, a, ":"); print a[n] }' <<< "$config"
        ssh_socket_ports
    } | sort -un
}

# As `ufw status` lists them, spaces squeezed. Takes sudo's flags.
ufw_wanted_rules() {
    local ports port range bridge
    ports="$(sshd_ports "$@")" && [ -n "$ports" ] || return 1
    for port in $ports; do
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
    local rules wanted rule
    rules="$(ufw_rules "$@")" && wanted="$(ufw_wanted_rules "$@")" || return 1
    while IFS= read -r rule; do
        [ -z "$rule" ] || ufw_rule_in_place "$rule" "$rules" || echo "$rule"
    done <<< "$wanted"
}

# ufw_rule_in_place <rule> <rules>: a deny rule must also precede every allow it shadows, since
# ufw takes the first match
ufw_rule_in_place() {
    local deny="$1" line v6=false bridge
    grep -qxF -- "$deny" <<< "$2" || return 1
    case "$deny" in *" DENY "*) ;; *) return 0 ;; esac
    case "$deny" in *"(v6)"*) v6=true ;; esac
    bridge="${deny#* on }"
    bridge="${bridge%% *}"
    while IFS= read -r line; do
        [ "$line" != "$deny" ] || return 0
        ufw_allow_rule "$line" && [ "$UFW_RULE_V6" == "$v6" ] || continue
        # A rule on another interface, such as tailscale0, never sees the bridge's traffic
        case "$UFW_RULE_IFACE" in
            "" | "$bridge") ;;
            br-*) [ "$bridge" == br-+ ] || continue ;;
            *) continue ;;
        esac
        ! ufw_to_includes_port "$UFW_RULE_TO" "${deny%%/*}" || return 1
    done <<< "$2"
    return 1
}

# ufw_allow_rule <rule>: on an allow or limit rule, sets UFW_RULE_TO, UFW_RULE_SOURCE,
# UFW_RULE_IFACE, and UFW_RULE_V6
ufw_allow_rule() {
    local rule="${1%% # *}" to v6
    [[ "$rule" =~ ^(.+)\ (ALLOW|LIMIT)(\ IN)?\ ([^ ]+)( \(v6\))?$ ]] || return 1
    to="${BASH_REMATCH[1]}" UFW_RULE_SOURCE="${BASH_REMATCH[4]}" v6="${BASH_REMATCH[5]}"
    UFW_RULE_V6=false
    case "$to $v6 $UFW_RULE_SOURCE" in *"(v6)"* | *:*) UFW_RULE_V6=true ;; esac
    to="${to/ (v6)/}"
    UFW_RULE_IFACE=""
    case "$to" in *" on "*) UFW_RULE_IFACE="${to##* on }" ;; esac
    UFW_RULE_TO="${to%% on *}"
}

# ufw_to_includes_port <to> <port>...: of the app profiles, only OpenSSH's port is known
ufw_to_includes_port() {
    local to="$1" spec port
    shift
    spec="${to##* }"
    case "$spec" in
        OpenSSH) spec=22/tcp ;;
        Anywhere) return 0 ;;
    esac
    if ! [[ "$spec" =~ ^[0-9]+([:,][0-9]+)*(/(tcp|udp))?$ ]]; then
        # An address alone covers every port; another app profile doesn't
        [ "$spec" == "$to" ] && [[ "$spec" =~ [.:] ]]
        return
    fi
    [ "${spec#*/}" != udp ] || return 1
    for port in "$@"; do
        ufw_ports_include "${spec%/*}" "$port" && return 0
    done
    return 1
}

# Prints "<source>\t<rule>" per line. Takes sudo's flags.
ufw_broad_ssh_rules() {
    local rules ports rule
    rules="$(ufw_rules "$@")" && ports="$(sshd_ports "$@")" && [ -n "$ports" ] || return 1
    while IFS= read -r rule; do
        # shellcheck disable=SC2086 # one port per word
        ! ufw_rule_broad_ssh "$rule" $ports || printf '%s\t%s\n' "$UFW_RULE_SOURCE" "$rule"
    done <<< "$rules"
}

ufw_rule_broad_ssh() {
    local rule="$1"
    shift
    ufw_allow_rule "$rule" || return 1
    [ "$UFW_RULE_IFACE" != tailscale0 ] || return 1
    ! private_source "$UFW_RULE_SOURCE" || return 1
    ufw_to_includes_port "$UFW_RULE_TO" "$@"
}

# <list> is e.g. 22, 80,443, or 8000:8100
ufw_ports_include() {
    local item IFS=,
    for item in $1; do
        case "$item" in
            *:*) [ "$2" -ge "${item%:*}" ] && [ "$2" -le "${item#*:}" ] && return 0 ;;
            *) [ "$2" -eq "$item" ] && return 0 ;;
        esac
    done
    return 1
}

private_source() {
    local bits floor
    case "$1" in
        Anywhere) return 1 ;;
        */*) bits="${1##*/}" ;;
        *) bits=128 ;;
    esac
    [[ "$bits" =~ ^[0-9]+$ ]] && floor="$(private_prefix "${1%/*}")" && [ "$bits" -ge "$floor" ]
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
    local ports port range bridge deny4 deny6 rules outside="" on=false
    # ufw rejects IPv6 rules under IPV6=no, leaving it half set up
    if [ -e "$UFW_DEFAULTS" ] && ! ufw_ipv6_on; then
        echo "  ufw doesn't filter IPv6, so the firewall is left unchanged: set IPV6=yes in $UFW_DEFAULTS," >&2
        echo "  run sudo ufw reload if ufw is on, then re-run the ubuntu step." >&2
        return 1
    fi
    ports="$(sshd_ports)" && [ -n "$ports" ] || {
        echo "  Couldn't read the SSH ports with sudo sshd -T, so the firewall is left unchanged." >&2
        return 1
    }
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
        apt_get install -y ufw || return 1
    fi
    "$on" || sudo ufw default deny incoming > /dev/null || return 1
    rules=""
    ! "$on" || rules="$(ufw_rules)" || return 1
    for port in $ports; do
        # ufw prepend skips a rule it has anywhere, so one out of place is deleted first
        for bridge in "${DOCKER_BRIDGES[@]}"; do
            deny4="$port/tcp on $bridge DENY Anywhere"
            deny6="$port/tcp (v6) on $bridge DENY Anywhere (v6)"
            ! ufw_rule_in_place "$deny4" "$rules" || ! ufw_rule_in_place "$deny6" "$rules" || continue
            if ! "$on" || grep -qxF -e "$deny4" -e "$deny6" <<< "$rules"; then
                sudo ufw delete deny in on "$bridge" to any port "$port" proto tcp > /dev/null || return 1
            fi
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
    local ufw=0 from rule where UFW_STATUS_CACHE="" UFW_STATUS_STATUS="" SSHD_DUMP_CACHE="" SSHD_DUMP_STATUS=""
    local rules="ufw rules allowing SSH from the private ranges, tailscale0, and Tailscale's $TAILSCALE_PORT/udp, and denying it on Docker's bridges"
    if [ -e "$UFW_DEFAULTS" ] && ! ufw_ipv6_on; then
        status_item missing "ufw filters IPv6: $UFW_DEFAULTS lacks IPV6=yes, so sshd answers on the global IPv6 address; set it, run sudo ufw reload if ufw is on, then re-run the ubuntu step"
    fi
    if ! ufw_enabled; then
        status_item missing "ufw on, denying incoming connections except SSH from the private ranges, tailscale0, and Tailscale's $TAILSCALE_PORT/udp"
        return 0
    fi
    ! sudo_ready || cache_ufw_status -n
    if sudo_ready && ufw_stopped -n; then
        status_item missing "ufw on, denying incoming connections: ufw status says it's inactive, so its rules aren't loaded (re-run the ubuntu step)"
        return 0
    fi
    status_item ok "ufw on, denying incoming connections"
    ! ufw_ipv6_on || status_item ok "ufw filters IPv6"
    if ! apt_installed openssh-server; then
        status_item missing "$rules: openssh-server isn't installed"
        return 0
    elif [ ! -d "$SSHD_RUN_DIR" ]; then
        status_item unverified "$rules (sshd -T, which lists sshd's ports, needs $SSHD_RUN_DIR, which the first SSH connection creates)"
        return 0
    fi
    if ! sudo_ready; then
        status_item unverified "$rules (only root can read them; run sudo -v, then status, to check them)"
        return 0
    fi
    cache_sshd_dump -n
    ufw_configured -n || ufw=$?
    case "$ufw" in
        0) status_item ok "$rules" ;;
        1) status_item missing "$rules (re-run the ubuntu step)" ;;
        *)
            status_item unknown "$rules: sudo ufw status or sudo sshd -T fails, so they can't be checked"
            return 0
            ;;
    esac
    while IFS=$'\t' read -r from rule; do
        [ -n "$rule" ] || continue
        where=anywhere
        [ "$from" == Anywhere ] || where="$from, outside the private ranges"
        status_item missing "ufw rule lets SSH in from $where: $rule; remove it with sudo ufw delete <number> (sudo ufw status numbered lists the numbers)"
    done < <(ufw_broad_ssh_rules -n || true)
}
