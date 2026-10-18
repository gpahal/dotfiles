# shellcheck shell=bash
# ufw for the ubuntu step: SSH only from the private address ranges, on the ports sshd and
# ssh.socket listen on, and any port from the tailnet (tailscale0), which Tailscale's ACLs limit.
# ufw goes on only while no SSH session comes from elsewhere.
# ubuntu/install.sh sources this file and sets the constants it uses. It only defines functions.

# Succeeds when ufw is on and denies incoming connections, which its config files show to anyone
ufw_enabled() {
    sbin_cmd ufw &>/dev/null &&
        grep -qx 'ENABLED=yes' "$UFW_CONF" 2>/dev/null &&
        grep -qx 'DEFAULT_INPUT_POLICY="DROP"' "$UFW_DEFAULTS" 2>/dev/null
}

# Succeeds when ufw filters IPv6 too. With IPV6=no, it leaves sshd open on the global IPv6
# address while ufw_enabled still succeeds. The step leaves the file to you, and status reports it.
ufw_ipv6_on() {
    grep -qx 'IPV6=yes' "$UFW_DEFAULTS" 2>/dev/null
}

# The ports ssh.socket listens on while it's active, one per line. systemctl show lists each
# address as "<address>:<port> (Stream)", e.g. "[::]:22 (Stream)".
ssh_socket_ports() {
    systemctl is-active -q ssh.socket 2>/dev/null || return 0
    systemctl show ssh.socket -p Listen --value 2>/dev/null | sed -nE 's/^.*:([0-9]+) \(Stream\)$/\1/p'
}

# The ports SSH comes in on, one per line: sshd -T's, and ssh.socket's, which starts sshd on
# Ubuntu and can listen on a port sshd's config doesn't name. sshd -T needs root, so pass sudo's
# flags, e.g. -n. Fails when sshd -T does, or $SSHD_RUN_DIR is missing, which only the install
# path creates, so status writes nothing.
sshd_ports() {
    local config
    [ -d "$SSHD_RUN_DIR" ] || return 1
    config="$(sudo "$@" sshd -T 2>/dev/null)" || return 1
    {
        awk '
            $1 == "port" { print $2 }
            $1 == "listenaddress" { n = split($2, a, ":"); print a[n] }' <<< "$config"
        ssh_socket_ports
    } | sort -un
}

# The allow rules the firewall needs, as `ufw status` lists them with runs of spaces squeezed: the
# SSH ports from each private range, anything on tailscale0, and Tailscale's UDP port from
# anywhere. Takes sudo's flags.
ufw_wanted_rules() {
    local ports port range
    ports="$(sshd_ports "$@")" && [ -n "$ports" ] || return 1
    for port in $ports; do
        for range in "${SSH_RANGES[@]}"; do
            echo "$port/tcp ALLOW $range"
        done
    done
    echo "Anywhere on tailscale0 ALLOW Anywhere"
    echo "$TAILSCALE_PORT/udp ALLOW Anywhere"
}

# The allow rules ufw has, with runs of spaces squeezed. Takes sudo's flags.
ufw_rules() {
    sudo "$@" ufw status 2>/dev/null | sed -E 's/ +/ /g; s/ $//'
}

# Allow SSH only from the private ranges and the tailnet, so a port forward on the router can't
# expose sshd. Takes sudo's flags: with -n it never asks for a password. Returns 2 when ufw is on
# and denies incoming connections, but its rules (`ufw status` needs root) couldn't be read, so
# they're unverified, and 1 for anything else missing. Rules you added by hand are left to you.
# shellcheck disable=SC2120 # apply in install.sh passes sudo's flags
ufw_configured() {
    local missing
    ufw_enabled || return 1
    missing="$(ufw_missing_rules "$@")" || return 2
    [ -z "$missing" ]
}

# Print the rules ufw_wanted_rules lists that ufw lacks, one per line. Takes sudo's flags. Fails
# when the rules or the SSH ports can't be read.
ufw_missing_rules() {
    local rules wanted rule
    rules="$(ufw_rules "$@")" && wanted="$(ufw_wanted_rules "$@")" || return 1
    while IFS= read -r rule; do
        [ -z "$rule" ] || grep -qxF "$rule" <<< "$rules" || echo "$rule"
    done <<< "$wanted"
}

# Print each allow or limit rule ufw has that lets SSH in from beyond the private ranges, other
# than on tailscale0, as "<source>\t<rule>", with the rule as ufw_rules prints it: one to an SSH
# port, or every port, from Anywhere, a public address, or a range wider than $SSH_RANGES', such
# as the rule `ufw allow ssh` adds. The step never adds or deletes such a rule, so status reports
# it. Takes sudo's flags. Fails when the rules or the SSH ports can't be read.
ufw_broad_ssh_rules() {
    local rules ports rule
    rules="$(ufw_rules "$@")" && ports="$(sshd_ports "$@")" && [ -n "$ports" ] || return 1
    while IFS= read -r rule; do
        # shellcheck disable=SC2086 # one port per word
        ! ufw_rule_broad_ssh "$rule" $ports || printf '%s\t%s\n' "$UFW_RULE_SOURCE" "$rule"
    done <<< "$rules"
}

# ufw_rule_broad_ssh <rule> <port>...: succeeds when the rule, as `ufw status` lists it with runs
# of spaces squeezed, lets any of the ports in over TCP from beyond the private ranges, other than
# on tailscale0, and sets UFW_RULE_SOURCE to where it lets them in from. "To" is [address]
# [ports[/proto] | app] [(v6)] [on <interface>], and an address alone, or Anywhere, means every
# port. Of the app profiles, only OpenSSH's port is known.
ufw_rule_broad_ssh() {
    local rule="${1%% # *}" to from spec port
    shift
    [[ "$rule" =~ ^(.+)\ (ALLOW|LIMIT)(\ IN)?\ ([^ ]+)( \(v6\))?$ ]] || return 1
    to="${BASH_REMATCH[1]}" from="${BASH_REMATCH[4]}"
    UFW_RULE_SOURCE="$from"
    to="${to/ (v6)/}"
    case "$to" in *" on tailscale0") return 1 ;; esac
    to="${to%% on *}"
    ! private_source "$from" || return 1
    spec="${to##* }"
    case "$spec" in
        OpenSSH) spec=22/tcp ;;
        Anywhere) return 0 ;;
    esac
    if ! [[ "$spec" =~ ^[0-9]+([:,][0-9]+)*(/(tcp|udp))?$ ]]; then
        # An address alone covers every port; another app profile, ufw can't say here
        [ "$spec" == "$to" ] && [[ "$spec" =~ [.:] ]]
        return
    fi
    [ "${spec#*/}" != udp ] || return 1
    for port in "$@"; do
        ufw_ports_include "${spec%/*}" "$port" && return 0
    done
    return 1
}

# ufw_ports_include <list> <port>: succeeds when ufw's port list, such as 22, 80,443, or 8000:8100,
# includes the port
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

# Succeeds for a rule's source inside the private ranges: an address in one of $SSH_RANGES, or a
# range of them no wider than the one it's in, such as 10.0.0.0/12 inside 10.0.0.0/8
private_source() {
    local bits floor
    case "$1" in
        Anywhere) return 1 ;;
        */*) bits="${1##*/}" ;;
        *) bits=128 ;;
    esac
    [[ "$bits" =~ ^[0-9]+$ ]] && floor="$(private_prefix "${1%/*}")" && [ "$bits" -ge "$floor" ]
}

# Print the prefix length of the range in $SSH_RANGES that an IPv4 or IPv6 address is in, or fail
# when it's in none
private_prefix() {
    local a b hextet
    case "$1" in
        *:*)
            # The first 16 bits, padded to four hex digits: fd00::/8 starts fd, and fe80::/10
            # fe8 to feb
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

# Succeeds for an IPv4 or IPv6 address in one of the private ranges in $SSH_RANGES
private_address() {
    private_prefix "$1" > /dev/null
}

# Succeeds for an address the firewall would cut off: outside the private ranges, and not reached
# over tailscale0 or lo, which ufw lets in whatever the address, as `ip route get` shows. An address
# it can't route counts as outside, so its session keeps working. Takes the address in lowercase,
# with any IPv6 zone.
outside_address() {
    local route dev
    ! private_address "${1%%\%*}" || return 1
    route="$(ip route get "${1%%\%*}" 2>/dev/null)" || return 0
    dev="$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<< "$route")"
    case "$dev" in tailscale0 | lo) return 1 ;; esac
}

# Print the address each logind session came from, its RemoteHost, one per line, in lowercase and
# without an IPv6 zone. pam_systemd registers a session once an SSH login succeeds, and anyone may
# read them. Fails when loginctl does, or a RemoteHost isn't an address, as with sshd's UseDNS yes,
# so it can't be matched with ss's addresses.
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

# Print the address of each SSH session the firewall would cut off (outside_address), one per
# line: an established connection to the ports given, the SSH ports, from an address a logind
# session came from. A connection with no login, such as a scanner's on a port open to the
# internet, or one still logging in, doesn't count, so it can't keep ufw off. A session stays in
# logind while a process it started, such as tmux, runs, so its connection has to be up too.
# Checks every session, from any terminal or tmux pane, since SSH_CONNECTION goes stale in a pane
# that outlives its session. Needs no root, which ss -p would: once sshd-session drops to your
# user, the kernel hides its sockets from you. When loginctl can't say, every connection counts.
# Fails when ss does. With one state, ss leaves out the state column, and prints the peer last, as
# <address>:<port>, in brackets for IPv6, with %<interface> for a link-local one, and an IPv4
# client of an IPv6 socket as ::ffff:<address>, which sshd gives logind as the IPv4 address.
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

# --force skips the question about dropping SSH connections, which the rules keep. Changes nothing
# and fails while the SSH ports can't be read, or, to turn ufw on, while an SSH session comes from
# outside the private ranges and the tailnet, which the firewall would cut off. With ufw already
# on, it only adds the allow rules that are missing, which can't cut anyone off.
# setup_ufw runs this as `ufw_configured || configure_ufw`, where set -e is off, so each command
# checks its own failure.
configure_ufw() {
    local ports port range outside="" on=false
    ports="$(sshd_ports)" && [ -n "$ports" ] || {
        echo "  Couldn't read the SSH ports with sudo sshd -T, so the firewall is left unchanged." >&2
        return 1
    }
    ! ufw_enabled || on=true
    # shellcheck disable=SC2086 # one port per word
    if ! "$on" && ! outside="$(outside_ssh_peers $ports)"; then
        echo "  Couldn't list the established SSH connections with ss, so the firewall is left unchanged." >&2
        return 1
    fi
    if [ -n "$outside" ]; then
        echo "  SSH connections come from $(join_lines ', ' <<< "$outside"), outside the private ranges and" >&2
        echo "  the tailnet, and the firewall would cut them off, so it's left unchanged. Re-run the step at" >&2
        echo "  the machine, from the local network, or over Tailscale." >&2
        echo "  If the Mac connects over IPv6 (e.g. to $(hostname).local), connect to the machine's IPv4" >&2
        echo "  address (ip -4 addr) or, once Tailscale is up, its tailnet name, and re-run." >&2
        return 1
    fi
    if ! apt_installed ufw; then
        apt_get install -y ufw || return 1
    fi
    "$on" || sudo ufw default deny incoming > /dev/null || return 1
    for port in $ports; do
        for range in "${SSH_RANGES[@]}"; do
            sudo ufw allow from "$range" to any port "$port" proto tcp > /dev/null || return 1
        done
    done
    sudo ufw allow in on tailscale0 > /dev/null || return 1
    sudo ufw allow "$TAILSCALE_PORT/udp" > /dev/null || return 1
    "$on" || sudo ufw --force enable > /dev/null
}

# Set up the firewall once sudo is in use
setup_ufw() {
    ensure_sshd_run_dir || return 1
    ufw_configured || configure_ufw
}

# Print the status items for ufw: on, filtering IPv6, its rules, and any other rule that lets SSH
# in from elsewhere. Reads the rules, which only root can, with sudo -n.
status_ufw() {
    local ufw=0 from rule where
    local rules="ufw rules allowing SSH from the private ranges, tailscale0, and Tailscale's $TAILSCALE_PORT/udp"
    if ! ufw_enabled; then
        status_item missing "ufw on, denying incoming connections except SSH from the private ranges, tailscale0, and Tailscale's $TAILSCALE_PORT/udp"
        return 0
    fi
    status_item ok "ufw on, denying incoming connections"
    if ufw_ipv6_on; then
        status_item ok "ufw filters IPv6"
    else
        status_item missing "ufw filters IPv6: $UFW_DEFAULTS lacks IPV6=yes, so sshd answers on the global IPv6 address; set it, then run sudo ufw reload"
    fi
    if ! apt_installed openssh-server; then
        status_item missing "$rules: openssh-server isn't installed"
        return 0
    elif [ ! -d "$SSHD_RUN_DIR" ]; then
        status_item unverified "$rules (sshd -T, which lists sshd's ports, needs $SSHD_RUN_DIR, which the first SSH connection creates)"
        return 0
    fi
    if sudo_cached; then
        ufw_configured -n || ufw=$?
    else
        ufw=2
    fi
    case "$ufw" in
        0) status_item ok "$rules" ;;
        1) status_item missing "$rules (re-run the ubuntu step)" ;;
        *)
            status_item unverified "$rules (only root can read them; run sudo -v, then status, to check them)"
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
