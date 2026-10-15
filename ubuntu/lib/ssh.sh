# shellcheck shell=bash
# OpenSSH for the ubuntu step: the sshd drop-in, the proof that a key logs in, the check that sshd
# takes the drop-in's settings, and the unit that starts sshd.
# ubuntu/install.sh sources this file and sets the constants it uses. It only defines functions.

# Print the SHA256 fingerprint of the public key line on stdin, or nothing when it isn't one
key_fingerprint() {
    ssh-keygen -lf - 2>/dev/null | awk '{ print $2 }'
}

# Print the unit that starts sshd at boot: the one enabled, ssh.socket first, or else
# ssh.socket, the default on every supported release
ssh_unit() {
    local unit
    for unit in ssh.socket ssh.service; do
        [ "$(systemctl is-enabled "$unit" 2>/dev/null)" != enabled ] || { echo "$unit"; return 0; }
    done
    echo ssh.socket
}

sshd_enabled() {
    [ "$(systemctl is-enabled "$(ssh_unit)" 2>/dev/null)" == enabled ]
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
# (AuthenticationMethods), with a key ~/.ssh/authorized_keys lists. Otherwise prints why not, and
# fails.
key_login() {
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
            found="${found:-missing}"
        else
            found="$fp"
        fi
    done < "$auth"
    case "$found" in
        "") echo "sshd recorded no key login for this SSH session" ;;
        missing) echo "the key this SSH session logged in with isn't in ~/.ssh/authorized_keys" ;;
        *) echo "$found" && return 0 ;;
    esac
    return 1
}

# Print the drop-in as it is, reading it with sudo -n when only root can read it, which works
# only while sudo credentials are cached. Prints nothing when there's none, and fails when it
# can't be read.
current_sshd_drop_in() {
    if [ -e "$SSHD_DROP_IN" ] && [ ! -r "$SSHD_DROP_IN" ]; then
        sudo -n cat "$SSHD_DROP_IN" 2>/dev/null
    else
        cat "$SSHD_DROP_IN" 2>/dev/null || true
    fi
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

# What turns password logins off, for status and main: an empty string once they're off or the
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

# sshd -T's -C argument for a login by you from this machine
sshd_login_spec() {
    echo "user=$(id -un),host=localhost,addr=127.0.0.1"
}

# Print each setting of the drop-in $1 that sshd doesn't take, as sshd -T shows it for a login by
# you from this machine, so a Match block for you applies, one "<Keyword> is <value>" line each:
# PermitRootLogin, AllowUsers, PasswordAuthentication, and KbdInteractiveAuthentication. sshd
# keeps the first value it reads for most of them, and adds every AllowUsers line's users, so
# another file can undo the drop-in. Prints nothing when sshd takes them all. sshd -T needs root
# and $SSHD_RUN_DIR, so pass sudo's flags, e.g. -n. Fails when sshd -T does, as it does for a
# Match on a criterion -C doesn't give, such as LocalPort.
sshd_settings_problems() {
    local drop_in="$1" config key want have
    shift
    [ -d "$SSHD_RUN_DIR" ] || return 1
    config="$(sudo "$@" sshd -T -C "$(sshd_login_spec)" 2>/dev/null)" || return 1
    while read -r key want; do
        case "$key" in
            AllowUsers) have="$(awk '$1 == "allowusers" { print $2 }' <<< "$config" | join_lines ' ')" ;;
            PermitRootLogin | PasswordAuthentication | KbdInteractiveAuthentication)
                have="$(awk -v key="$(tr '[:upper:]' '[:lower:]' <<< "$key")" '$1 == key { print $2; exit }' <<< "$config")"
                ;;
            *) continue ;;
        esac
        [ "$have" == "$want" ] || echo "$key is ${have:-unset}"
    done <<< "$drop_in"
}

ensure_sshd_run_dir() {
    [ -d "$SSHD_RUN_DIR" ] || sudo install -d -m 0755 "$SSHD_RUN_DIR"
}

# Print the first file sshd -t's errors name, given its output. It writes "<file>: line <n>:" or
# "<file> line <n>:".
sshd_error_file() {
    sed -nE 's#^(/[^: ]+):? line [0-9]+.*#\1#p' <<< "$1" | head -n 1
}

# Swap the new drop-in in and check the whole config with sshd -t, putting the old one back when
# it fails. The config is checked first as it is, so a broken file elsewhere fails the step without
# touching a working drop-in. main runs this as `configure_sshd || ...`, where set -e is off, so
# each command checks its own failure.
configure_sshd() {
    local output bad existed=false old="" new problems="" line checked=true
    # sshd -t also fails without sshd, and that's no config error
    if [ ! -x "$SSHD_BIN" ]; then
        echo "  sshd isn't installed ($SSHD_BIN is missing), so $SSHD_DROP_IN was left as it is. Install openssh-server and re-run." >&2
        return 1
    fi
    ensure_sshd_run_dir || return 1
    if ! output="$(sudo sshd -t 2>&1)"; then
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
    if ! output="$(sudo sshd -t 2>&1)"; then
        printf '%s\n' "$output" >&2
        bad="$(sshd_error_file "$output")"
        if "$existed"; then
            write_root_file "$SSHD_DROP_IN" "$old"
            echo "  sshd -t failed with the new $SSHD_DROP_IN${bad:+ (the error is in $bad)}, so the old one is back." >&2
        else
            sudo rm -f "$SSHD_DROP_IN"
            echo "  sshd -t failed with the new $SSHD_DROP_IN${bad:+ (the error is in $bad)}, so it was removed." >&2
        fi
        echo "  Fix the error above and re-run." >&2
        return 1
    fi
    # Ubuntu starts sshd on the first connection (ssh.socket), so it may not be running yet
    if ! sudo systemctl try-reload-or-restart ssh.service; then
        if "$existed"; then
            write_root_file "$SSHD_DROP_IN" "$old" || return 1
        else
            sudo rm -f "$SSHD_DROP_IN" || return 1
        fi
        echo "  Couldn't activate the SSH settings; restored the previous drop-in. Fix the error and re-run." >&2
        return 1
    fi
    # Checked only now, since the step leaves other files to you
    problems="$(sshd_settings_problems "$new")" || checked=false
    # sshd has reloaded, so the warning holds unless another file keeps password logins on
    if key_only_in "$new" && ! key_only_in "$old" &&
        ! grep -qE '^(PasswordAuthentication|KbdInteractiveAuthentication) ' <<< "$problems"; then
        # -S none skips the shared connection, which logged in before password logins went off.
        # ssh -O exit would close this session too, since it may run through that connection.
        echo "  Password logins are off now. Keep this session open, and on the Mac check a fresh login with: ssh -S none <alias> true"
    fi
    if ! "$checked"; then
        echo "  sudo sshd -T -C $(sshd_login_spec) failed, so whether sshd takes $SSHD_DROP_IN is" >&2
        echo "  unchecked. Run it to see why." >&2
        return 1
    fi
    if [ -n "$problems" ]; then
        echo "  sshd doesn't take these settings from $SSHD_DROP_IN, since another file sets them first:" >&2
        while IFS= read -r line; do echo "    $line"; done <<< "$problems" >&2
        echo "  Find them with sudo grep -ri <setting> /etc/ssh, fix them, then re-run the step." >&2
        return 1
    fi
}
