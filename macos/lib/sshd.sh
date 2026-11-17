# shellcheck shell=bash
# Remote Login, macOS's OpenSSH server, for the macos step: a drop-in that lets in only your key,
# only from the tailnet, and the launchd job that turns Remote Login on once the drop-in is in
# place, so it never takes a password. macos/install.sh sets the constants.
#
# launchd owns the listening socket, on every interface, and starts sshd -i for each connection.
# So a new drop-in applies from the next login with no reload, and ListenAddress would do nothing,
# which is why AllowUsers limits the source addresses instead.

mac_sshd_drop_in() {
    local range allow=""
    for range in "${TAILNET_RANGES[@]}"; do
        allow="$allow $CURRENT_USER@$range"
    done
    echo "# From the dotfiles macos step: only your key, only from the tailnet"
    echo "PermitRootLogin no"
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
    echo "AuthenticationMethods publickey"
    echo "AllowUsers$allow"
    echo "MaxAuthTries 3"
    echo "X11Forwarding no"
    echo "ClientAliveInterval 60"
    echo "AcceptEnv TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM"
}

# Cached through a memo scope, once called outside a $( )
current_mac_sshd_drop_in() {
    memo MAC_SSHD_DROP_IN_CURRENT read_root_file "$MAC_SSHD_DROP_IN" -n
}

mac_sshd_configured() {
    local current
    current="$(current_mac_sshd_drop_in)" || return 1
    [ "$current" == "$(mac_sshd_drop_in)" ]
}

# mac_sshd_test <-t|-T> [-n]: sshd's config check, or its effective settings, through sudo, or
# sudo -n. macOS makes the host keys only when Remote Login first starts, and sshd -t and -T fail
# without one, so both get a throwaway key.
mac_sshd_test() {
    local mode="$1" sudo=(sudo) dir status=0
    [ "${2:-}" != -n ] || sudo=(sudo -n)
    dir="$(mktemp -d)" || return 1
    if ssh-keygen -q -t ed25519 -N '' -f "$dir/key" < /dev/null > /dev/null 2>&1; then
        "${sudo[@]}" "$MAC_SSHD_BIN" "$mode" -h "$dir/key" < /dev/null 2>&1 || status=$?
    else
        echo "ssh-keygen couldn't make a throwaway host key for sshd $mode"
        status=1
    fi
    rm -rf "$dir"
    return "$status"
}

# mac_sshd_problems <sshd -T output>: prints "<setting> is <value>" for each drop-in setting sshd
# takes from elsewhere. sshd -T prints keywords in lower case, and each AllowUsers entry on its own
# line. AcceptEnv adds to the other files' values, so it isn't compared.
mac_sshd_problems() {
    local config="$1" key want have
    while read -r key want; do
        case "$key" in '' | '#'* | AcceptEnv) continue ;; esac
        if [ "$key" == AllowUsers ]; then
            have="$(awk '$1 == "allowusers" { print $2 }' <<< "$config" | join_lines ' ')"
        else
            have="$(awk -v key="$(tr '[:upper:]' '[:lower:]' <<< "$key")" \
                '$1 == key { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$config")"
        fi
        [ "$have" == "$want" ] || echo "$key is ${have:-unset}"
    done < <(mac_sshd_drop_in)
}

restore_mac_sshd_drop_in() {
    if "$1"; then
        write_root_file "$MAC_SSHD_DROP_IN" "$2" 644
    else
        sudo rm -f "$MAC_SSHD_DROP_IN"
    fi
}

# Checks the config before and after the swap, so a broken file elsewhere fails without touching
# a working drop-in. Runs where set -e is off, so each command checks its own failure.
configure_mac_sshd() {
    local output bad existed=false old="" new
    if [ ! -x "$MAC_SSHD_BIN" ]; then
        echo "  $MAC_SSHD_BIN is missing, so $MAC_SSHD_DROP_IN was left as it is." >&2
        return 1
    fi
    if ! output="$(mac_sshd_test -t)"; then
        bad="$(sshd_error_file "$output")"
        if [ "$bad" != "$MAC_SSHD_DROP_IN" ]; then
            printf '%s\n' "$output" >&2
            echo "  sshd's config already fails sshd -t${bad:+, in $bad}, so $MAC_SSHD_DROP_IN was left as it is." >&2
            echo "  Fix that file and re-run." >&2
            return 1
        fi
    fi
    if sudo test -e "$MAC_SSHD_DROP_IN"; then
        existed=true
        old="$(sudo cat "$MAC_SSHD_DROP_IN")" || return 1
    fi
    new="$(mac_sshd_drop_in)"
    write_root_file "$MAC_SSHD_DROP_IN" "$new" 644 || return 1
    memo_forget MAC_SSHD_DROP_IN_CURRENT
    if ! output="$(mac_sshd_test -t)"; then
        printf '%s\n' "$output" >&2
        if ! restore_mac_sshd_drop_in "$existed" "$old"; then
            echo "  sshd -t failed with the new $MAC_SSHD_DROP_IN, and it couldn't be put back, so the" >&2
            echo "  broken drop-in is still in place. Fix the error above and re-run." >&2
        else
            echo "  sshd -t failed with the new $MAC_SSHD_DROP_IN, so the old state is back. Fix the error above and re-run." >&2
        fi
        return 1
    fi
    echo "  Wrote $MAC_SSHD_DROP_IN, so sshd lets in only your key, only from the tailnet"
}

# print-disabled lists "<label>" => enabled or disabled, or false or true on older macOS
remote_login_enabled() {
    launchctl print-disabled system 2> /dev/null |
        grep -qE "\"$REMOTE_LOGIN_LABEL\" => (enabled|false)"
}

remote_login_loaded() {
    launchctl print "system/$REMOTE_LOGIN_LABEL" &> /dev/null
}

remote_login_on() {
    remote_login_enabled && remote_login_loaded
}

# What System Settings → General → Sharing → Remote Login does. Off until the drop-in is in place,
# which items_apply_confirmed writes first.
turn_on_remote_login() {
    local settings="Turn it on in System Settings → General → Sharing → Remote Login instead."
    if ! mac_sshd_configured; then
        echo "  Remote Login stays off until $MAC_SSHD_DROP_IN is in place, so it never takes a password." >&2
        return 1
    fi
    if ! remote_login_enabled && ! sudo launchctl enable "system/$REMOTE_LOGIN_LABEL"; then
        echo "  Couldn't enable Remote Login's launchd job. $settings" >&2
        return 1
    fi
    if ! remote_login_loaded && ! sudo launchctl bootstrap system "$REMOTE_LOGIN_PLIST"; then
        echo "  Couldn't load Remote Login's launchd job. $settings" >&2
        return 1
    fi
    if ! remote_login_on; then
        echo "  launchctl ran, but Remote Login still reads as off. $settings" >&2
        return 1
    fi
    echo "  Turned on Remote Login"
}

# status declares the items first (macos_items)
status_mac_sshd() {
    local item config problems
    local MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    current_mac_sshd_drop_in > /dev/null || true
    if [ -e "$MAC_SSHD_DROP_IN" ] && [ ! -r "$MAC_SSHD_DROP_IN" ] && ! sudo_ready; then
        status_needs_root "$MAC_SSHD_DROP_IN" "only root can read it"
    else
        items_status mac_sshd_configured
    fi
    if mac_sshd_configured 2> /dev/null; then
        item="sshd's effective settings match $MAC_SSHD_DROP_IN"
        if ! sudo_ready; then
            status_needs_root "$item" "the effective values need sudo -v" them
        elif ! config="$(mac_sshd_test -T -n)"; then
            status_item unverified "$item (sudo sshd -T failed; run it to see why)"
        else
            problems="$(mac_sshd_problems "$config")"
            if [ -z "$problems" ]; then
                status_item ok "$item"
            else
                status_item missing "$item ($(join_lines '; ' <<< "$problems"); another file sets them first, which sudo grep -ri <setting> /etc/ssh finds)"
            fi
        fi
    fi
    items_status remote_login_on
}
