# shellcheck shell=bash
# OpenSSH for the ubuntu step: the sshd drop-in, the proof that a key logs in, the check that sshd
# takes the drop-in's settings, and the unit that starts sshd.
# ubuntu/install.sh sources this file and sets the constants it uses. It only defines functions.

# Print the SHA256 fingerprint of the public key line on stdin, or nothing when it isn't one
key_fingerprint() {
    ssh-keygen -lf - 2>/dev/null | awk '{ print $2 }'
}

openssh_installed() {
    apt_installed openssh-server
}

install_openssh() {
    apt_get install -y openssh-server
}

# Either unit starts sshd at boot: a machine switched back to ssh.service, as Ubuntu's docs
# describe, has ssh.socket off, and enabling it then couldn't bind sshd's port
sshd_enabled() {
    [ "$(systemctl is-enabled "$SSH_UNIT" 2>/dev/null)" == enabled ] ||
        [ "$(systemctl is-enabled ssh.service 2>/dev/null)" == enabled ]
}

enable_sshd() {
    sudo systemctl enable --now "$SSH_UNIT"
}

# Print the SHA256 fingerprint of each public key in ~/.ssh/authorized_keys, one per line
authorized_key_fingerprints() {
    local line
    [ -r "$HOME/.ssh/authorized_keys" ] || return 0
    # Check public-key lines individually: -lf on a whole file also accepts private keys.
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" | key_fingerprint
    done < "$HOME/.ssh/authorized_keys"
}

# Print the fingerprint of the key this run's SSH session logged in with, when it proves that key
# logs in: sshd's ExposeAuthInfo writes a "<method>[/<submethod>] [<key type> <key> ...]" line for
# each method the session logged in with to the file $SSH_USER_AUTH names, and removes the file
# when the session ends. Every method must be publickey, since sshd can require a password too
# (AuthenticationMethods), and every key one ~/.ssh/authorized_keys lists, since sshd can require
# several (publickey,publickey), and a fresh login then needs each of them. With several, it prints
# the first. Otherwise prints why not, and fails. status and apply work it out once
# (cache_checks), since it runs ssh-keygen per key.
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

# Print the drop-in as it is, with sudo -n when only root can read it (read_root_file)
current_sshd_drop_in() {
    read_root_file "$SSHD_DROP_IN" -n
}

# Succeeds when the drop-in already turns password logins off, given its content
key_only_in() {
    grep -qx 'PasswordAuthentication no' <<< "$1"
}

# Print why the drop-in should newly turn password logins off, or fail: this run's SSH session
# logged in with a key sshd takes, or DOTFILES_SSH_KEY_ONLY=1 opts a disposable VM in
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

# AcceptEnv takes the terminal's name and color support that Ghostty's ssh-env sends. zsh/hooks.zsh
# passes the name into tmux panes. ClientAliveInterval drops a dead client's session after 3
# minutes. ExposeAuthInfo records how each session logged in, for key_login. AllowUsers stops
# every other user's OpenSSH login, though not Tailscale SSH, which doesn't read this file.
# Password logins go off only once a session proves a key logs in (key_only_reason), and once
# off, they stay off. Run as root, the step leaves out AllowUsers, since with PermitRootLogin no,
# AllowUsers root refuses everyone, and turns password logins off only when they already are,
# since root's key logs no one in. Takes the current drop-in, which it otherwise reads.
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
    [ "$(id -u)" != 0 ] || root=true
    "$root" || echo "AllowUsers $(id -un)"
    if key_only_in "$current" || { ! "$root" && key_only_reason > /dev/null; }; then
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
    fi
}

# What turns password logins off, for status and apply: an empty string once they're off or the
# step runs as root, which leaves them alone. Fails when the drop-in can't be read.
key_only_todo() {
    local current problem hint=""
    current="$(current_sshd_drop_in)" || return 1
    if [ "$(id -u)" == 0 ] || key_only_in "$current"; then
        return 0
    elif key_only_reason > /dev/null; then
        echo "re-run the ubuntu step to turn them off"
    else
        problem="$(key_login)" || true
        # ssh -O exit closes the connection ssh/add-host.sh's ControlMaster keeps open, which
        # a new ssh would reuse, along with the password login it made
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

# Print an address in a range given as an address, a CIDR range, or a pattern with * or ?: the
# first host for IPv4 (10.0.0.0/8 gives 10.0.0.1), ::1 after an IPv6 prefix (fd00::/8 gives
# fd00::1), and 1 for each wildcard. 10.* gives 10.1, which sshd reads as 10.0.0.1, as inet_aton
# does, and matches against the pattern as a string. An IPv6 address needs all 8 groups or a ::, so
# the first * in a pattern short of both gives 1::1 (fd00:* gives fd00:1::1).
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

# Print each entry of the Address criteria in the Match lines of sshd's config and drop-ins, one
# per line, such as 192.168.5.0/24 or !10.1.2.3. Takes sudo's flags, e.g. -n, for files only root
# can read; one it can't read is left out.
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

# The addresses sshd_settings_problems checks a login by you from, one per line: this machine, one
# in each of $SSH_RANGES and the tailnet's range, this SSH session's client, and one in each
# address or range a Match Address line names, so a Match block for any of them shows. Takes
# sudo's flags, as sshd_match_addresses does.
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

# sshd -T's -C argument for a login by you from an address. sshd's UseDNS defaults to no, which
# makes the host the address.
sshd_login_spec() {
    echo "user=$(id -un),host=$1,addr=$1"
}

# Set SSHD_PROBLEMS to each setting of the drop-in $1 that sshd doesn't take, as sshd -T shows it
# for a login by you from each address sshd_login_addresses lists, so a Match block for you or one
# of them applies, one "<Keyword> is <value>" line each, ending in " for <addresses>" unless every
# address gets it: PermitRootLogin, AllowUsers, PasswordAuthentication, and
# KbdInteractiveAuthentication. sshd keeps the first value it reads for most of them, and adds
# every AllowUsers line's users, so another file can undo the drop-in. It's empty when sshd takes
# them all. sshd -T needs root and $SSHD_RUN_DIR, so pass sudo's flags, e.g. -n. Fails when sshd
# -T does, as it does for a Match on a criterion -C doesn't give, such as LocalPort, and then sets
# SSHD_FAILED_SPEC to the -C argument it failed with.
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
                PermitRootLogin | PasswordAuthentication | KbdInteractiveAuthentication)
                    have="$(awk -v key="$(tr '[:upper:]' '[:lower:]' <<< "$key")" '$1 == key { print $2; exit }' <<< "$config")"
                    ;;
                *) continue ;;
            esac
            [ "$have" == "$want" ] || problems+="$key is ${have:-unset}"$'\t'"$addr"$'\n'
        done <<< "$drop_in"
    done < <(sshd_login_addresses "$@")
    # One line per problem, in the order found
    SSHD_PROBLEMS="$(printf '%s' "$problems" | awk -F '\t' -v n="$n" '
        !($1 in count) { order[++k] = $1 }
        { count[$1]++; where[$1] = where[$1] (where[$1] == "" ? "" : ", ") $2 }
        END { for (i = 1; i <= k; i++) print order[i] (count[order[i]] == n ? "" : " for " where[order[i]]) }')"
}

ensure_sshd_run_dir() {
    [ -d "$SSHD_RUN_DIR" ] || sudo install -d -m 0755 "$SSHD_RUN_DIR"
}

# Print the first file sshd -t's errors name, given its output. It writes "<file>: line <n>:" or
# "<file> line <n>:".
sshd_error_file() {
    sed -nE 's#^(/[^: ]+):? line [0-9]+.*#\1#p' <<< "$1" | head -n 1
}

# restore_sshd_drop_in <existed> <old content>: put back the drop-in configure_sshd replaced, or
# remove the new one when there was none before
restore_sshd_drop_in() {
    if "$1"; then
        write_root_file "$SSHD_DROP_IN" "$2"
    else
        sudo rm -f "$SSHD_DROP_IN"
    fi
}

# Swap the new drop-in in and check the whole config with sshd -t, putting the old one back when
# it fails. The config is checked first as it is, so a broken file elsewhere fails the step without
# touching a working drop-in. apply runs this as `configure_sshd || ...`, where set -e is off, so
# each command checks its own failure.
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
    # A failed write leaves the old drop-in whole, so there is nothing to put back
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
    # Ubuntu starts sshd on the first connection (ssh.socket), so it may not be running yet
    if ! sudo systemctl try-reload-or-restart ssh.service; then
        restore_sshd_drop_in "$existed" "$old" || return 1
        echo "  Couldn't activate the SSH settings; restored the previous drop-in. Fix the error and re-run." >&2
        return 1
    fi
    # Checked only now, since the step leaves other files to you
    sshd_settings_problems "$new" || checked=false
    problems="$SSHD_PROBLEMS"
    # sshd has reloaded, so the warning holds unless another file keeps password logins on
    if key_only_in "$new" && ! key_only_in "$old" && ! grep -qE "$PASSWORD_PROBLEMS" <<< "$problems"; then
        # -S none skips the shared connection, which logged in before password logins went off.
        # ssh -O exit would close this session too, since it may run through that connection.
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

# The lines of sshd_settings_problems' output about password logins, which status_sshd reports
# under its own item
PASSWORD_PROBLEMS='^(PasswordAuthentication|KbdInteractiveAuthentication) '

# Print the status items for OpenSSH: the package, the unit that starts sshd, the drop-in, whether
# sshd takes its settings, and password logins, each problem once. Reads what only root can with
# sudo -n. status declares the items first (ubuntu_items).
status_sshd() {
    local installed=false item problems="" others todo
    openssh_installed && installed=true
    items_status openssh_installed
    ! "$installed" || items_status sshd_enabled
    if [ -e "$SSHD_DROP_IN" ] && [ ! -r "$SSHD_DROP_IN" ] && ! sudo_cached; then
        status_item unverified "$SSHD_DROP_IN (only root can read it; run sudo -v, then status, to check it)"
    else
        status_check "$SSHD_DROP_IN" sshd_configured
    fi
    # Checked once the drop-in is in place, which a missing item above already reports
    if "$installed" && sshd_configured 2>/dev/null; then
        item="sshd's effective settings match $SSHD_DROP_IN"
        if [ ! -d "$SSHD_RUN_DIR" ]; then
            status_item unverified "$item (sshd -T needs $SSHD_RUN_DIR, which the first SSH connection creates)"
        elif ! sudo_cached; then
            status_item unverified "$item (the effective values need sudo -v; run sudo -v, then status, to check them)"
        elif ! sshd_settings_problems "$(current_sshd_drop_in)" -n; then
            status_item unverified "$item (sudo sshd -T -C $SSHD_FAILED_SPEC failed; run it to see why)"
        else
            problems="$SSHD_PROBLEMS"
            # Password logins get their own item below
            others="$(grep -vE "$PASSWORD_PROBLEMS" <<< "$problems" || true)"
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
