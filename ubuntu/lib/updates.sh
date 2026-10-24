# shellcheck shell=bash
# ubuntu/install.sh sets the constants.

# An APT::Periodic interval of at most a day: always, or <n>[smhd], where a bare number means days
periodic_daily() {
    local number="${1%[smhd]}" unit=d
    [ "$1" != always ] || return 0
    [ "$number" == "$1" ] || unit="${1#"$number"}"
    # At most nine digits, so the seconds can't overflow
    [[ "$number" =~ ^[0-9]{1,9}$ ]] || return 1
    number=$((10#$number))
    case "$unit" in
        m) number=$((number * 60)) ;;
        h) number=$((number * 3600)) ;;
        d) number=$((number * 86400)) ;;
    esac
    [ "$number" -gt 0 ] && [ "$number" -le 86400 ]
}

auto_upgrades_unreadable() {
    [ -e "$AUTO_UPGRADES_CONF" ] && [ ! -r "$AUTO_UPGRADES_CONF" ]
}

# Same defaults as apt.systemd.daily. Args are sudo flags (e.g. -n), used when only root can read
# $AUTO_UPGRADES_CONF, since apt-config as you skips it.
unattended_upgrades_on() {
    local values enable=1 update=0 upgrade=0 run=()
    ! auto_upgrades_unreadable || run=(sudo "$@")
    values="$(${run[@]+"${run[@]}"} apt-config shell enable APT::Periodic::Enable \
        update APT::Periodic::Update-Package-Lists upgrade APT::Periodic::Unattended-Upgrade 2>/dev/null)" ||
        return 1
    # apt-config quotes each value for the shell
    eval "$values"
    ! [[ "$enable" =~ ^0+$ ]] && periodic_daily "$update" && periodic_daily "$upgrade"
}

unattended_upgrades_running() {
    apt_installed unattended-upgrades && unattended_upgrades_on -n
}

status_unattended_upgrades() {
    local item="unattended-upgrades runs daily"
    if auto_upgrades_unreadable && ! sudo_ready; then
        status_needs_root "$item" "only root can read $AUTO_UPGRADES_CONF"
    else
        status_check "$item" unattended_upgrades_running
    fi
}

# A stopped timer never fires until the next boot, so check active too
apt_timers_enabled() {
    unit_on "${APT_TIMERS[@]}"
}

# Replaces our keys statement by statement and keeps the rest, such as Software & Updates'
# AutocleanInterval. A line it can't split safely ({ }, a multi-line statement, a /* */ comment,
# #clear, #include) stays as is, and our keys are appended after the last such line, since apt's
# later value wins.
merged_auto_upgrades() {
    # BSD awk's -v rejects a newline
    printf '%s' "$1" | AUTO_UPGRADES_LINES="$AUTO_UPGRADES_CONTENT" awk '
        function key_of(statement) {
            sub(/^[ \t]+/, "", statement)
            sub(/[ \t";].*/, "", statement)
            return tolower(statement)
        }
        BEGIN {
            n = split(ENVIRON["AUTO_UPGRADES_LINES"], want, "\n")
            for (i = 1; i <= n; i++) key[i] = key_of(want[i])
        }
        {
            # Split at each ; outside quotes and comments; apt has no escapes inside quotes
            line = $0
            m = 0
            start = 1
            in_quote = 0
            code = 0
            block = in_block
            opaque = (depth != 0 || cont)
            len = length(line)
            for (p = 1; p <= len; p++) {
                c = substr(line, p, 1)
                if (in_block) {
                    if (substr(line, p, 2) == "*/") { in_block = 0; p++ }
                } else if (in_quote) {
                    if (c == "\"") in_quote = 0
                } else if (c == "\"") {
                    in_quote = 1
                    code = 1
                } else if (substr(line, p, 2) == "//") {
                    break
                } else if (substr(line, p, 2) == "/*") {
                    in_block = 1
                    block = 1
                    p++
                } else if (c == "#") {
                    # As in apt, # starts a comment unless it starts a directive
                    if (substr(line, p, 6) == "#clear" || substr(line, p, 8) == "#include") opaque = 1
                    break
                } else if (c == "{" || c == "}") {
                    opaque = 1
                    depth += (c == "{") ? 1 : -1
                } else if (c == ";") {
                    statement[++m] = substr(line, start, p - start + 1)
                    start = p + 1
                    code = 0
                } else if (c != " " && c != "\t") {
                    code = 1
                }
            }
            # An unterminated statement continues on the next line
            cont = (code || in_quote)
            if (cont || (block && m > 0)) opaque = 1
            if (opaque) {
                last_opaque = NR
                print
                next
            }
            out = ""
            for (j = 1; j <= m; j++) {
                s = statement[j]
                k = key_of(s)
                for (i = 1; i <= n; i++) {
                    if (k == key[i]) {
                        indent = s
                        sub(/[^ \t].*/, "", indent)
                        s = indent want[i]
                        replaced[i] = NR
                        break
                    }
                }
                out = out s
            }
            print out substr(line, start)
        }
        END {
            for (i = 1; i <= n; i++) if (!replaced[i] || replaced[i] < last_opaque) print want[i]
        }'
}

# dpkg-reconfigure needs a terminal and reads $AUTO_UPGRADES_CONF back, so merge into the file
turn_on_unattended_upgrades() {
    local current merged
    if ! apt_installed unattended-upgrades; then
        apt_install_fresh unattended-upgrades || return 1
    fi
    if ! unattended_upgrades_on; then
        if ! current="$(read_root_file "$AUTO_UPGRADES_CONF")"; then
            echo "  Couldn't read $AUTO_UPGRADES_CONF, so it was left as it is." >&2
            return 1
        fi
        merged="$(merged_auto_upgrades "$current")" || return 1
        # Unchanged means another file overrides the keys
        [ "$merged" == "$current" ] || write_root_file "$AUTO_UPGRADES_CONF" "$merged" || return 1
    fi
    unattended_upgrades_on && return 0
    echo "  APT's effective periodic settings still disable daily updates after writing $AUTO_UPGRADES_CONF." >&2
    echo "  Check Enable, Update-Package-Lists, and Unattended-Upgrade with apt-config dump." >&2
    echo "  Find overrides with grep -r 'APT::Periodic' /etc/apt/apt.conf.d." >&2
    return 1
}

keep_conffiles_written() {
    file_is "$KEEP_CONFFILES_CONF" "$KEEP_CONFFILES_CONTENT"
}

# New dependencies and phased updates count as upgradable, as for unattended-upgrades, so only
# packages that need action are listed.
held_back_packages() {
    local out
    out="$(LC_ALL=C run_bounded 60 apt-get -s -o APT::Get::Upgrade-Allow-New=true \
        -o APT::Get::Always-Include-Phased-Updates=true upgrade 2>/dev/null)" || return 1
    awk '
        /^The following packages have been kept back:/ { on = 1; next }
        on && /^  / { for (i = 1; i <= NF; i++) print $i; next }
        { on = 0 }' <<< "$out"
}

status_held_back() {
    local label="Packages apt holds back from updates" packages marked held rest
    if ! packages="$(held_back_packages)"; then
        status_item unverified "$label: apt-get -s upgrade failed; run it to see why"
    elif [ -z "$packages" ]; then
        status_item ok "No packages held back from updates"
    else
        marked="$(apt-mark showhold 2>/dev/null)" || marked=""
        held="$(grep -xF -- "$marked" <<< "$packages" || true)"
        rest="$(grep -vxF -- "$marked" <<< "$packages" || true)"
        [ -n "$marked" ] || { held=""; rest="$packages"; }
        [ -z "$rest" ] ||
            status_item missing "$label: $(join_lines ', ' <<< "$rest"); sudo apt full-upgrade shows what installing them takes"
        [ -z "$held" ] ||
            status_item missing "$label: $(join_lines ', ' <<< "$held"), on hold with apt-mark; sudo apt-mark unhold $(join_lines ' ' <<< "$held") lets them update"
    fi
}
