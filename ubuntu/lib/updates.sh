# shellcheck shell=bash
# Updates for the ubuntu step: unattended-upgrades, apt's daily timers, the dpkg options that keep
# edited conffiles, and the packages apt holds back.
# ubuntu/install.sh sources this file and sets the constants it uses. It only defines functions.

# Succeeds for an APT::Periodic interval that makes apt.systemd.daily run a job at least daily:
# always, or a number of s, m, h, or d, which a bare number means, from 1 s to a day
periodic_daily() {
    local number="${1%[smhd]}" unit=d
    [ "$1" != always ] || return 0
    [ "$number" == "$1" ] || unit="${1#"$number"}"
    # Up to nine digits, so the seconds can't overflow
    [[ "$number" =~ ^[0-9]{1,9}$ ]] || return 1
    number=$((10#$number))
    case "$unit" in
        m) number=$((number * 60)) ;;
        h) number=$((number * 3600)) ;;
        d) number=$((number * 86400)) ;;
    esac
    [ "$number" -gt 0 ] && [ "$number" -le 86400 ]
}

# Succeeds when $AUTO_UPGRADES_CONF exists but only root can read it. apt-config, run as you, then
# skips it with a warning.
auto_upgrades_unreadable() {
    [ -e "$AUTO_UPGRADES_CONF" ] && [ ! -r "$AUTO_UPGRADES_CONF" ]
}

# Read the values the way apt.systemd.daily does, with apt-config shell and its defaults: Enable is
# 1, so only 0 turns it off, and the two intervals are 0. apt-config runs as root when only root can
# read $AUTO_UPGRADES_CONF, so pass sudo's flags, e.g. -n.
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

# Print the status item for unattended-upgrades. Never asks for sudo.
status_unattended_upgrades() {
    local item="unattended-upgrades runs daily"
    if auto_upgrades_unreadable && ! sudo_cached; then
        status_item unverified "$item (only root can read $AUTO_UPGRADES_CONF; run sudo -v, then status, to check it)"
    else
        status_check "$item" unattended_upgrades_running
    fi
}

# Enabled starts a timer at boot, and active means it's scheduled now: a stopped timer never fires
# until the next boot
apt_timers_enabled() {
    local timer
    for timer in "${APT_TIMERS[@]}"; do
        [ "$(systemctl is-enabled "$timer" 2>/dev/null)" == enabled ] || return 1
        systemctl is-active -q "$timer" 2>/dev/null || return 1
    done
}

enable_apt_timers() {
    sudo systemctl enable --now "${APT_TIMERS[@]}"
}

# Print $AUTO_UPGRADES_CONF, reading it with sudo when only root can, or nothing when it's missing.
# Fails when it can't be read, so the merge never starts from nothing.
current_auto_upgrades() {
    if auto_upgrades_unreadable; then
        sudo cat "$AUTO_UPGRADES_CONF"
    elif [ -e "$AUTO_UPGRADES_CONF" ]; then
        cat "$AUTO_UPGRADES_CONF"
    fi
}

# Print the content of $AUTO_UPGRADES_CONF, given as $1, with each line of $AUTO_UPGRADES_CONTENT in
# place of the lines that set its key, or appended when none does. Software & Updates keeps other
# APT::Periodic keys there, such as AutocleanInterval, so every other line stays, as
# software-properties leaves them.
merged_auto_upgrades() {
    # Through the environment, since BSD awk's -v rejects a newline
    printf '%s' "$1" | AUTO_UPGRADES_LINES="$AUTO_UPGRADES_CONTENT" awk '
        function key_of(line) {
            sub(/^[ \t]+/, "", line)
            sub(/[ \t"].*/, "", line)
            return tolower(line)
        }
        BEGIN {
            n = split(ENVIRON["AUTO_UPGRADES_LINES"], want, "\n")
            for (i = 1; i <= n; i++) key[i] = key_of(want[i])
        }
        {
            k = key_of($0)
            for (i = 1; i <= n; i++) {
                if (k == key[i]) {
                    print want[i]
                    done[i] = 1
                    next
                }
            }
            print
        }
        END { for (i = 1; i <= n; i++) if (!done[i]) print want[i] }'
}

# Installing the package turns it on. dpkg-reconfigure can't turn it on without a terminal: it
# reads the setting back from $AUTO_UPGRADES_CONF, so the step merges its keys into that file.
turn_on_unattended_upgrades() {
    local current merged
    if ! apt_installed unattended-upgrades; then
        apt_get install -y unattended-upgrades || return 1
    fi
    if ! unattended_upgrades_on; then
        if ! current="$(current_auto_upgrades)"; then
            echo "  Couldn't read $AUTO_UPGRADES_CONF, so it was left as it is." >&2
            return 1
        fi
        merged="$(merged_auto_upgrades "$current")"
        # Unchanged, the keys are already set here, and another file overrides them
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

write_keep_conffiles() {
    write_root_file "$KEEP_CONFFILES_CONF" "$KEEP_CONFFILES_CONTENT"
}

# Print the packages apt-get upgrade would hold back, one per line. A simulation needs no root.
# New dependencies are allowed, as unattended-upgrades allows them, so a kernel update that pulls
# in a new package doesn't count; what's left needs a removal or a decision, or is on hold. Phased
# updates count as upgradable too, so the daily alert only flags packages that need action.
held_back_packages() {
    local out
    out="$(LC_ALL=C run_bounded 60 apt-get -s -o APT::Get::Upgrade-Allow-New=true \
        -o APT::Get::Always-Include-Phased-Updates=true upgrade 2>/dev/null)" || return 1
    awk '
        /^The following packages have been kept back:/ { on = 1; next }
        on && /^  / { for (i = 1; i <= NF; i++) print $i; next }
        { on = 0 }' <<< "$out"
}

# unattended-upgrades never installs a held-back package, so its updates wait for you. A package
# on hold with apt-mark hold stays back until it's unheld, which full-upgrade doesn't do.
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
