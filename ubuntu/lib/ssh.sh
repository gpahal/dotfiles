# shellcheck shell=bash
# OpenSSH for the ubuntu step. ubuntu/install.sh sets the constants.

key_fingerprint() {
    ssh-keygen -lf - 2>/dev/null | awk '{ print $2 }'
}

openssh_installed() {
    apt_installed openssh-server
}

install_openssh() {
    apt_get install -y openssh-server
}

# Either unit counts: with ssh.service enabled, ssh.socket couldn't bind sshd's port
sshd_enabled() {
    [ "$(systemctl is-enabled "$SSH_UNIT" 2>/dev/null)" == enabled ] ||
        [ "$(systemctl is-enabled ssh.service 2>/dev/null)" == enabled ]
}

enable_sshd() {
    sudo systemctl enable --now "$SSH_UNIT"
}

authorized_key_fingerprints() {
    local line
    [ -r "$HOME/.ssh/authorized_keys" ] || return 0
    # Line by line: -lf on a whole file also accepts private keys
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" | key_fingerprint
    done < "$HOME/.ssh/authorized_keys"
}

# Prints the fingerprint of the key this SSH session logged in with, or why not and fails. Reads
# ExposeAuthInfo's $SSH_USER_AUTH; every method must be an authorized publickey, since
# AuthenticationMethods can require several.
key_login() {
    if [ -n "${KEY_LOGIN_STATUS:-}" ]; then
        printf '%s\n' "$KEY_LOGIN_CACHE"
        return "$KEY_LOGIN_STATUS"
    fi
    read_key_login
}

read_key_login() {
    local auth="${SSH_USER_AUTH:-}" method type key fp authorized found=""
    if [ -z "$auth" ]; then
        echo "this run isn't in an SSH session that sshd recorded the login of"
        return 1
    fi
    if [ ! -r "$auth" ]; then
        echo "the SSH session this shell started in has ended"
        return 1
    fi
    authorized="$(authorized_key_fingerprints)"
    while read -r method type key _; do
        [ -n "$method" ] || continue
        if [ "${method%%/*}" != publickey ]; then
            echo "this SSH session logged in with a password"
            return 1
        fi
        fp="$(printf '%s %s\n' "$type" "$key" | key_fingerprint)"
        if [ -z "$fp" ] || ! grep -qxF "$fp" <<< "$authorized"; then
            echo "the key this SSH session logged in with isn't in ~/.ssh/authorized_keys"
            return 1
        fi
        found="${found:-$fp}"
    done < "$auth"
    if [ -z "$found" ]; then
        echo "sshd recorded no key login for this SSH session"
        return 1
    fi
    echo "$found"
}

# SSHD_DROP_IN_STATUS, which status_sshd sets, keeps one read through a status run
current_sshd_drop_in() {
    if [ -n "${SSHD_DROP_IN_STATUS:-}" ]; then
        printf '%s\n' "$SSHD_DROP_IN_CACHE"
        return "$SSHD_DROP_IN_STATUS"
    fi
    read_root_file "$SSHD_DROP_IN" -n
}

key_only_in() {
    grep -qx 'PasswordAuthentication no' <<< "$1"
}

key_only_reason() {
    local fp
    if [ "${DOTFILES_SSH_KEY_ONLY:-}" == 1 ]; then
        echo "DOTFILES_SSH_KEY_ONLY=1 is set"
    elif fp="$(key_login)"; then
        echo "this SSH session logged in with your key $fp"
    else
        return 1
    fi
}

# Password logins go off only once a key login is proven, and then stay off. As root: no
# AllowUsers (with PermitRootLogin no it'd refuse everyone), and root's key proves nothing.
sshd_drop_in() {
    local current root=false
    if [ $# -gt 0 ]; then
        current="$1"
    else
        current="$(current_sshd_drop_in)" || current=""
    fi
    echo "# From the dotfiles ubuntu step"
    echo "AcceptEnv TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM"
    echo "PermitRootLogin no"
    echo "ClientAliveInterval 60"
    echo "ExposeAuthInfo yes"
    echo "X11Forwarding no"
    echo "MaxAuthTries 3"
    [ "$(id -u)" != 0 ] || root=true
    "$root" || echo "AllowUsers $(id -un)"
    if key_only_in "$current" || { ! "$root" && key_only_reason > /dev/null; }; then
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
    fi
}

# Prints what's needed to turn password logins off; empty once off or as root
key_only_todo() {
    local current problem hint=""
    current="$(current_sshd_drop_in)" || return 1
    if [ "$(id -u)" == 0 ] || key_only_in "$current"; then
        return 0
    elif key_only_reason > /dev/null; then
        echo "re-run the ubuntu step to turn them off"
    else
        problem="$(key_login)" || true
        # ssh/add-host.sh's ControlMaster reuses the earlier password login
        [ "$problem" != "this SSH session logged in with a password" ] ||
            hint="If you logged in with your key, ssh reused an earlier connection: on the Mac, run ssh -O exit <alias>, then SSH in again."
        echo "$problem.${hint:+ $hint} Copy your key over (ssh-copy-id <alias> from the Mac, with the alias just ssh-host added, or this machine's LAN IP before Tailscale is up), SSH in with it, and re-run the ubuntu step"
    fi
}

sshd_configured() {
    local current
    current="$(current_sshd_drop_in)" || return 1
    [ "$(sshd_drop_in "$current")" == "$current" ]
}

# Prints one address inside a CIDR range or * ? pattern: 10.0.0.0/8 -> 10.0.0.1, fd00::/8 ->
# fd00::1, 10.* -> 10.1 (inet_aton reads it as 10.0.0.1), fd00:* -> fd00:1::1.
range_sample() {
    local addr="${1%/*}" first=1
    case "$addr" in
        *::*) ;;
        *:*) [ "${addr//[!:]/}" == ::::::: ] || first=1::1 ;;
    esac
    addr="${addr/\*/$first}"
    addr="${addr//\*/1}"
    addr="${addr//\?/1}"
    case "$addr" in
        *::) echo "${addr}1" ;;
        *.0) if [ "$addr" == "$1" ]; then echo "$addr"; else echo "${addr%.0}.1"; fi ;;
        *) echo "$addr" ;;
    esac
}

# Prints Match Address entries, e.g. 192.168.5.0/24 or !10.1.2.3. Takes sudo's flags.
sshd_match_addresses() {
    local file
    for file in "$SSHD_CONFIG" "$(dirname "$SSHD_DROP_IN")"/*.conf; do
        [ ! -e "$file" ] || read_root_file "$file" "$@" || true
    done 2>/dev/null | awk '
        { sub(/#.*/, "") }
        tolower($1) == "match" {
            for (i = 2; i < NF; i++) {
                if (tolower($i) != "address") continue
                n = split($(i + 1), entries, ",")
                for (j = 1; j <= n; j++) print entries[j]
                i++
            }
        }'
}

# One address per range a login may come from, so any Match block shows. Takes sudo's flags.
sshd_login_addresses() {
    local range
    {
        echo 127.0.0.1
        for range in "${SSH_RANGES[@]}" "$TAILNET_RANGE"; do
            range_sample "$range"
        done
        [ -z "${SSH_CONNECTION:-}" ] || echo "${SSH_CONNECTION%% *}"
        sshd_match_addresses "$@" | while IFS= read -r range; do
            case "$range" in '!'* | '') ;; *) range_sample "$range" ;; esac
        done
    } | awk '!seen[$0]++'
}

# UseDNS defaults to no, so host is the address
sshd_login_spec() {
    echo "user=$(id -un),host=$1,addr=$1"
}

# sshd_settings_problems <drop-in> <sudo flags>: sets SSHD_PROBLEMS to the drop-in settings
# another file or Match block overrides. On sshd -T failure (e.g. a Match on LocalPort, which -C
# can't give) sets SSHD_FAILED_SPEC and fails.
sshd_settings_problems() {
    local drop_in="$1" addr config key want have problems="" n=0
    shift
    SSHD_PROBLEMS="" SSHD_FAILED_SPEC=""
    [ -d "$SSHD_RUN_DIR" ] || return 1
    while IFS= read -r addr; do
        n=$((n + 1))
        if ! config="$(sudo "$@" "$SSHD_BIN" -T -C "$(sshd_login_spec "$addr")" 2>/dev/null < /dev/null)"; then
            SSHD_FAILED_SPEC="$(sshd_login_spec "$addr")"
            return 1
        fi
        while read -r key want; do
            case "$key" in
                AllowUsers) have="$(awk '$1 == "allowusers" { print $2 }' <<< "$config" | join_lines ' ')" ;;
                PermitRootLogin | PasswordAuthentication | KbdInteractiveAuthentication | X11Forwarding | MaxAuthTries)
                    have="$(awk -v key="$(tr '[:upper:]' '[:lower:]' <<< "$key")" '$1 == key { print $2; exit }' <<< "$config")"
                    ;;
                *) continue ;;
            esac
            [ "$have" == "$want" ] || problems+="$key is ${have:-unset}"$'\t'"$addr"$'\n'
        done <<< "$drop_in"
    done < <(sshd_login_addresses "$@")
    SSHD_PROBLEMS="$(printf '%s' "$problems" | awk -F '\t' -v n="$n" '
        !($1 in count) { order[++k] = $1 }
        { count[$1]++; where[$1] = where[$1] (where[$1] == "" ? "" : ", ") $2 }
        END { for (i = 1; i <= k; i++) print order[i] (count[order[i]] == n ? "" : " for " where[order[i]]) }')"
}

ensure_sshd_run_dir() {
    [ -d "$SSHD_RUN_DIR" ] || sudo install -d -m 0755 "$SSHD_RUN_DIR"
}

# sshd -t writes "<file>: line <n>:" or "<file> line <n>:"
sshd_error_file() {
    sed -nE 's#^(/[^: ]+):? line [0-9]+.*#\1#p' <<< "$1" | head -n 1
}

# restore_sshd_drop_in <existed> <old content>
restore_sshd_drop_in() {
    if "$1"; then
        write_root_file "$SSHD_DROP_IN" "$2"
    else
        sudo rm -f "$SSHD_DROP_IN"
    fi
}

# Checks the config before and after the swap, so a broken file elsewhere fails without touching
# a working drop-in. Runs where set -e is off, so each command checks its own failure.
configure_sshd() {
    local output bad existed=false old="" new problems="" line checked=true
    # sshd -t also fails without sshd, and that's no config error
    if [ ! -x "$SSHD_BIN" ]; then
        echo "  sshd isn't installed ($SSHD_BIN is missing), so $SSHD_DROP_IN was left as it is. Install openssh-server and re-run." >&2
        return 1
    fi
    ensure_sshd_run_dir || return 1
    if ! output="$(sudo "$SSHD_BIN" -t 2>&1)"; then
        bad="$(sshd_error_file "$output")"
        if [ "$bad" != "$SSHD_DROP_IN" ]; then
            printf '%s\n' "$output" >&2
            echo "  sshd's config already fails sshd -t${bad:+, in $bad}, so $SSHD_DROP_IN was left as it is." >&2
            echo "  Fix that file and re-run." >&2
            return 1
        fi
    fi
    if sudo test -e "$SSHD_DROP_IN"; then
        existed=true
        old="$(sudo cat "$SSHD_DROP_IN")" || return 1
    fi
    new="$(sshd_drop_in "$old")"
    write_root_file "$SSHD_DROP_IN" "$new" || return 1
    if ! output="$(sudo "$SSHD_BIN" -t 2>&1)"; then
        printf '%s\n' "$output" >&2
        bad="$(sshd_error_file "$output")"
        if ! restore_sshd_drop_in "$existed" "$old"; then
            echo "  sshd -t failed with the new $SSHD_DROP_IN${bad:+ (the error is in $bad)}, and it couldn't be" >&2
            echo "  put back, so the broken drop-in is still in place: $SSHD_DROP_IN" >&2
        elif "$existed"; then
            echo "  sshd -t failed with the new $SSHD_DROP_IN${bad:+ (the error is in $bad)}, so the old one is back." >&2
        else
            echo "  sshd -t failed with the new $SSHD_DROP_IN${bad:+ (the error is in $bad)}, so it was removed." >&2
        fi
        echo "  Fix the error above and re-run." >&2
        return 1
    fi
    # sshd may not be running yet: ssh.socket starts it on the first connection
    if ! sudo systemctl try-reload-or-restart ssh.service; then
        restore_sshd_drop_in "$existed" "$old" || return 1
        echo "  Couldn't activate the SSH settings; restored the previous drop-in. Fix the error and re-run." >&2
        return 1
    fi
    sshd_settings_problems "$new" || checked=false
    problems="$SSHD_PROBLEMS"
    if "$checked" && key_only_in "$new" && ! key_only_in "$old" && ! grep -qE "$PASSWORD_PROBLEMS" <<< "$problems"; then
        # Not ssh -O exit: this session may run through the shared connection
        echo "  Password logins are off now. Keep this session open, and on the Mac check a fresh login with: ssh -S none <alias> true"
    fi
    if ! "$checked"; then
        echo "  sudo sshd -T -C $SSHD_FAILED_SPEC failed, so whether sshd takes $SSHD_DROP_IN is" >&2
        echo "  unchecked. Run it to see why." >&2
        return 1
    fi
    if [ -n "$problems" ]; then
        echo "  sshd doesn't take these settings from $SSHD_DROP_IN, since another file, or a Match block, sets them first:" >&2
        while IFS= read -r line; do echo "    $line"; done <<< "$problems" >&2
        echo "  Find them with sudo grep -ri <setting> /etc/ssh, fix them, then re-run the step." >&2
        return 1
    fi
}

PASSWORD_PROBLEMS='^(PasswordAuthentication|KbdInteractiveAuthentication) '

# status declares the items first (ubuntu_items)
status_sshd() {
    local installed=false item problems="" others todo SSHD_DROP_IN_CACHE="" SSHD_DROP_IN_STATUS=0
    SSHD_DROP_IN_CACHE="$(read_root_file "$SSHD_DROP_IN" -n)" || SSHD_DROP_IN_STATUS=$?
    openssh_installed && installed=true
    items_status openssh_installed
    ! "$installed" || items_status sshd_enabled
    if [ -e "$SSHD_DROP_IN" ] && [ ! -r "$SSHD_DROP_IN" ] && ! sudo_ready; then
        status_item unverified "$SSHD_DROP_IN (only root can read it; run sudo -v, then status, to check it)"
    else
        status_check "$SSHD_DROP_IN" sshd_configured
    fi
    if "$installed" && sshd_configured 2>/dev/null; then
        item="sshd's effective settings match $SSHD_DROP_IN"
        if [ ! -d "$SSHD_RUN_DIR" ]; then
            status_item unverified "$item (sshd -T needs $SSHD_RUN_DIR, which the first SSH connection creates)"
        elif ! sudo_ready; then
            status_item unverified "$item (the effective values need sudo -v; run sudo -v, then status, to check them)"
        elif ! sshd_settings_problems "$(current_sshd_drop_in)" -n; then
            status_item unverified "$item (sudo sshd -T -C $SSHD_FAILED_SPEC failed; run it to see why)"
        else
            problems="$SSHD_PROBLEMS"
            # Password logins get their own item below, except as root
            others="$problems"
            [ "$(id -u)" == 0 ] || others="$(grep -vE "$PASSWORD_PROBLEMS" <<< "$problems" || true)"
            if [ -z "$others" ]; then
                status_item ok "$item"
            else
                status_item missing "$item ($(join_lines '; ' <<< "$others"); another file, or a Match block, sets them first, which sudo grep -ri <setting> /etc/ssh finds)"
            fi
        fi
    fi
    item="Password and keyboard-interactive SSH logins off"
    if [ "$(id -u)" == 0 ]; then
        status_item skipped "$item: the step leaves them to root"
    elif ! todo="$(key_only_todo)"; then
        status_item unverified "$item (only root can read $SSHD_DROP_IN; run sudo -v, then status, to check it)"
    elif [ -z "$todo" ] && grep -qE "$PASSWORD_PROBLEMS" <<< "$problems"; then
        status_item missing "$item ($(grep -E "$PASSWORD_PROBLEMS" <<< "$problems" | join_lines '; '); another file, or a Match block, sets them first, which sudo grep -ri <setting> /etc/ssh finds)"
    elif [ -z "$todo" ]; then
        status_item ok "$item"
    else
        status_item missing "$item ($todo)"
    fi
}
