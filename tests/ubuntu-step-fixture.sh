# A stubbed Ubuntu machine for tests of the ubuntu step. Source after tests/lib.sh and
# tests/ubuntu-sandbox.sh, then call setup_sandbox and ubuntu_step_setup.
# shellcheck shell=bash
# shellcheck disable=SC2329 # the step calls the replaced functions

# Run it again to bring back a function a test replaced
ubuntu_step_load() {
    load_script ubuntu/install.sh
    ubuntu_sandbox_paths
    as_os ubuntu
    replace_fn ufw_enabled '[ -e "$SANDBOX/ufw-on" ]'
    replace_fn lingering true
    replace_fn status_smart :
    replace_fn status_firmware :
    replace_fn ups_todo :
    replace_fn status_ups :
    replace_fn warn_no_ups :
    # This checkout may be a worktree
    declare -F real_in_git_worktree > /dev/null || eval "real_$(declare -f in_git_worktree)"
    replace_fn in_git_worktree false
}

# Defaults match 26.04; files under $SANDBOX change unit state. $1 runs first.
stub_systemctl() {
    stub systemctl "${1:-}"'
case "$1" in
    --user) case "$2" in
        enable) for unit in "${@:3}"; do
                [ "$unit" != --now ] || continue
                touch "'"$SANDBOX"'/user-units/$unit.enabled"
                [[ " $* " != *" --now "* ]] || touch "'"$SANDBOX"'/user-units/$unit.active"
            done ;;
        is-enabled) [ -e "'"$SANDBOX"'/user-units/${!#}.enabled" ] ;;
        is-active) [ -e "'"$SANDBOX"'/user-units/${!#}.active" ] ;;
        show) [ "$4" == NeedDaemonReload ] || exit 0
            [ -e "'"$SANDBOX"'/reload-needed" ] && echo yes || echo no ;;
        daemon-reload) [ ! -e "'"$SANDBOX"'/reload-fails" ] || exit 1
            rm -f "'"$SANDBOX"'/reload-needed" ;;
    esac ;;
    is-enabled) case "$2" in
        smartmontools.service) cat "'"$SANDBOX"'/smartd" 2> /dev/null || echo disabled ;;
        apt-daily.timer | apt-daily-upgrade.timer | ssh.socket) cat "'"$SANDBOX"'/units/$2" 2> /dev/null || echo enabled ;;
        ssh.service) cat "'"$SANDBOX"'/units/$2" 2> /dev/null || echo disabled ;;
        *) echo masked ;;
    esac ;;
    enable)
        case "$3" in ssh.socket) echo enabled > "'"$SANDBOX"'/units/$3"; exit 0 ;; esac
        if [ "$3" == apt-daily.timer ]; then
            [ ! -e "'"$SANDBOX"'/timers-fail" ] || exit 1
            for unit in "${@:3}"; do rm -f "'"$SANDBOX"'/units/$unit" "'"$SANDBOX"'/units/$unit.inactive"; done
            exit 0
        fi
        [ "$3" == smartmontools.service ] || exit 0
        echo enabled > "'"$SANDBOX"'/smartd"
        [ -e "'"$SANDBOX"'/smartd-failed" ] || touch "'"$SANDBOX"'/smartd-active" ;;
    restart) [ "$2" != smartmontools.service ] || { rm -f "'"$SANDBOX"'/smartd-failed"; touch "'"$SANDBOX"'/smartd-active"; } ;;
    is-active) case "$3" in
        smartmontools.service) [ -e "'"$SANDBOX"'/smartd-active" ] ;;
        *) [ ! -e "'"$SANDBOX"'/units/$3.inactive" ] ;;
    esac ;;
esac'
}

# A machine where nothing is set up yet
ubuntu_step_setup() {
    ubuntu_step_load
    echo IPV6=yes > "$UFW_DEFAULTS"
    not_cached_sudo() { stub_sudo_exec '[ "${1:-}" != -n ] || exit 1'; }
    not_cached_sudo
    stub dpkg-query 'echo "install ok installed"'
    stub_systemctl
    stub systemd-detect-virt 'exit 1'
    # Ubuntu's default smartd.conf
    echo "DEVICESCAN -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner" > "$SMARTD_CONF"
    # sysctl-key-fails: fails after applying, as for a key the kernel lacks
    stub sysctl 'live="'"$SANDBOX"'/sysctl-live"
    case "$1" in
        --system) [ ! -e "'"$SANDBOX"'/sysctl-fails" ] || exit 1
            cat "'"$SANDBOX"'/sysctl.d/"*.conf | grep "=" | tr -d " " >> "$live"
            [ ! -e "'"$SANDBOX"'/sysctl-key-fails" ] ;;
        -n) grep "^$2=" "$live" 2> /dev/null | tail -n 1 | cut -d= -f2 ;;
    esac'
    stub locale 'echo C.utf8; [ ! -e "'"$SANDBOX"'/locale" ] || echo en_US.utf8'
    stub locale-gen 'touch "'"$SANDBOX"'/locale"'
    stub apt-get 'cat "'"$SANDBOX"'/apt-upgrade" 2> /dev/null || true'
    stub apt-mark
    # As in apt, the last file that sets a key wins
    stub_apt_config 'cat "'"$SANDBOX"'/apt.conf.d/"* 2> /dev/null | awk '"'"'{ values[$1] = $0 } END { for (key in values) print values[key] }'"'"''
    stub loginctl
    stub lsblk
    # tailscale-reset: as after Tailscale's first login
    stub tailscale 'case "$1" in
        debug) if [ -e "'"$SANDBOX"'/tailscale-reset" ]; then echo "{}"
            else echo "{\"AutoUpdate\": {\"Apply\": true}, \"OperatorUser\": \"$(id -un)\"}"; fi ;;
        status) echo "{\"BackendState\": \"$(cat "'"$SANDBOX"'/tailscale-state")\"}" ;;
    esac'
    echo Running > "$SANDBOX/tailscale-state"
    # sshd -T takes the first value per key, Match blocks winning; test-ubuntu-sshd-real.sh checks
    # the step against the real sshd
    mkdir -p "$SANDBOX/sshd_config.d" "$SSHD_RUN_DIR"
    # No SSH sessions, as at the console
    stub ss
    stub sshd 'case "$1" in
        -T) [ ! -e "'"$SANDBOX"'/sshd-T-fails" ] || exit 255
            user="" addr=""
            [ "${2:-}" != -C ] || user="$(sed -n "s/^user=\([^,]*\).*/\1/p" <<< "$3")"
            [ "${2:-}" != -C ] || addr="$(sed -n "s/.*addr=\([^,]*\).*/\1/p" <<< "$3")"
            echo "port 22"
            cat "'"$SANDBOX"'"/sshd_config.d/*.conf 2> /dev/null | awk -v user="$user" -v addr="$addr" '"'"'
                { k = tolower($1) }
                k == "match" {
                    matched = tolower($2) == "user" && $3 == user
                    n = tolower($2) == "address" ? split($3, entries, ",") : 0
                    for (i = 1; i <= n; i++) {
                        entry = entries[i]
                        if (entry ~ /^!/) continue
                        if (entry ~ /\.0\/24$/) {
                            matched = matched || index(addr, substr(entry, 1, length(entry) - 4)) == 1
                            continue
                        }
                        gsub(/\./, "\\.", entry)
                        gsub(/\*/, ".*", entry)
                        gsub(/\?/, ".", entry)
                        matched = matched || addr ~ ("^" entry "$")
                    }
                    inmatch = 1
                    next
                }
                inmatch && !matched { next }
                k == "allowusers" { for (i = 2; i <= NF; i++) users = users " " $i; next }
                k ~ /^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)$/ {
                    if (inmatch) { if (!(k in m)) m[k] = $2 } else if (!(k in v)) v[k] = $2
                }
                END {
                    for (k in m) v[k] = m[k]
                    print "passwordauthentication", ("passwordauthentication" in v) ? v["passwordauthentication"] : "yes"
                    print "kbdinteractiveauthentication", ("kbdinteractiveauthentication" in v) ? v["kbdinteractiveauthentication"] : "yes"
                    print "permitrootlogin", ("permitrootlogin" in v) ? v["permitrootlogin"] : "without-password"
                    n = split(users, u, " ")
                    for (i = 1; i <= n; i++) print "allowusers", u[i]
                }'"'"' ;;
        -t) for f in "'"$SANDBOX"'"/sshd_config.d/*.conf; do
                if grep -q "^Bogus" "$f"; then echo "$f: line 1: Bad configuration option: Bogus" >&2; exit 255; fi
            done ;;
    esac'
    ufw_status_listing > "$SANDBOX/ufw-status"
    stub ufw 'case "$1" in
        --force) touch "'"$SANDBOX"'/ufw-on" ;;
        status) [ -e "'"$SANDBOX"'/ufw-on" ] && cat "'"$SANDBOX"'/ufw-status" ;;
    esac'
    stub nmcli 'case "$*" in
        "-t -e no -f UUID,TYPE,NAME connection show") printf "%s\n" "1111-aaaa:802-3-ethernet:Wired connection 1" "2222-bbbb:802-11-wireless:Home:5G" ;;
        *"-g 802-3-ethernet.wake-on-lan connection show uuid 1111-aaaa") cat "'"$SANDBOX"'/wol" ;;
        "connection modify uuid 1111-aaaa 802-3-ethernet.wake-on-lan magic") echo magic > "'"$SANDBOX"'/wol" ;;
        "-t -f DEVICE,TYPE device") printf "%s\n" "enp6s0:ethernet" "wlp5s0:wifi" ;;
    esac'
    # Ubuntu's drop-in turns Wi-Fi power save on (3). NetworkManager reads a directory's drop-ins in
    # name order, and the last value wins.
    mkdir -p "$(dirname "$WIFI_POWERSAVE_CONF")"
    printf '%s\n' "[connection]" "wifi.powersave = 3" > "$(dirname "$WIFI_POWERSAVE_CONF")/default-wifi-powersave-on.conf"
    stub NetworkManager 'LC_ALL=C
        [ "$1" == --print-config ] || exit 1
        echo "[connection]"
        cat "'"$(dirname "$WIFI_POWERSAVE_CONF")"'"/*.conf | sed -n "s/^wifi.powersave *= */wifi.powersave=/p" | tail -n 1'
    stub iw
    echo default > "$SANDBOX/wol"
    mkdir "$SANDBOX/units" "$SANDBOX/user-units"
    # shellcheck disable=SC2034 # test-ubuntu-step.sh reads it
    KEEP_CONFFILES="Updates keep conffiles you edited, so unattended-upgrades doesn't skip them ($KEEP_CONFFILES_CONF)"
    # As Tailscale's install script writes it
    TAILSCALE_ENTRY="deb [signed-by=$TAILSCALE_KEYRING] https://pkgs.tailscale.com/stable/ubuntu resolute main"
    echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"
}

# Set the machine up with every change approved
ubuntu_step_set_up() {
    export DOTFILES_ASSUME_YES=1 DOTFILES_SSH_KEY_ONLY=1
    assert_exit 0 main
    assert_exit 0 status
}
