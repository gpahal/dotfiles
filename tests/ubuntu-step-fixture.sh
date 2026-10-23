# A stubbed Ubuntu machine for tests of the ubuntu step. Source after tests/lib.sh and
# tests/ubuntu-sandbox.sh, then call ubuntu_step_setup.
# shellcheck shell=bash
# shellcheck disable=SC2329 # the step calls the replaced functions

# Run it again to bring back a function a test replaced. restore_fn ufw_enabled reads ufw's files
# and units instead of $SANDBOX/ufw-on.
ubuntu_step_load() {
    load_script ubuntu/install.sh
    ubuntu_sandbox_paths
    as_os ubuntu
    wrap_fn ufw_enabled '[ -e "$SANDBOX/ufw-on" ]'
    replace_fn lingering true
    replace_fn status_smart :
    replace_fn status_firmware :
    replace_fn ups_todo :
    replace_fn status_ups :
    replace_fn warn_no_ups :
    # No nut group in a test
    replace_fn ntfy_url_group 'id -gn'
    # The test opt-ins count here, though systemd-detect-virt says this isn't a VM
    replace_fn on_test_machine true
}

# Defaults match 26.04; files under $SANDBOX change unit state, such as units/ufw.service.disabled
# or .inactive. ssh.socket listens on the ports in $SANDBOX/socket-ports. $1 runs first.
stub_systemctl() {
    stub systemctl "${1:-}"'
case "$1" in
    --user) case "$2" in
        enable) for unit in "${@:3}"; do
                [ "$unit" != --now ] || continue
                touch "$SANDBOX/user-units/$unit.enabled"
                [[ " $* " != *" --now "* ]] || touch "$SANDBOX/user-units/$unit.active"
            done ;;
        is-enabled) [ -e "$SANDBOX/user-units/${!#}.enabled" ] ;;
        is-active) [ -e "$SANDBOX/user-units/${!#}.active" ] ;;
        show) [ "$4" == NeedDaemonReload ] || exit 0
            [ -e "$SANDBOX/reload-needed" ] && echo yes || echo no ;;
        daemon-reload) [ ! -e "$SANDBOX/reload-fails" ] || exit 1
            rm -f "$SANDBOX/reload-needed" ;;
    esac ;;
    is-enabled) case "$2" in
        -q) [ "$3" != ufw.service ] || [ ! -e "$SANDBOX/units/ufw.service.disabled" ] ;;
        smartmontools.service) cat "$SANDBOX/smartd" 2> /dev/null || echo disabled ;;
        apt-daily.timer | apt-daily-upgrade.timer | ssh.socket) cat "$SANDBOX/units/$2" 2> /dev/null || echo enabled ;;
        ssh.service) cat "$SANDBOX/units/$2" 2> /dev/null || echo disabled ;;
        *) printf "masked\n%.0s" "${@:2}" ;;
    esac ;;
    enable)
        case "$3" in ssh.socket) echo enabled > "$SANDBOX/units/$3"; exit 0 ;; esac
        [ "${!#}" != ufw.service ] || { rm -f "$SANDBOX/units/ufw.service."*; exit 0; }
        if [ "$3" == apt-daily.timer ]; then
            [ ! -e "$SANDBOX/timers-fail" ] || exit 1
            for unit in "${@:3}"; do rm -f "$SANDBOX/units/$unit" "$SANDBOX/units/$unit.inactive"; done
            exit 0
        fi
        [ "$3" == smartmontools.service ] || exit 0
        echo enabled > "$SANDBOX/smartd"
        [ -e "$SANDBOX/smartd-failed" ] || touch "$SANDBOX/smartd-active" ;;
    restart) [ "$2" != smartmontools.service ] || { rm -f "$SANDBOX/smartd-failed"; touch "$SANDBOX/smartd-active"; } ;;
    is-active) case "$3" in
        smartmontools.service) [ -e "$SANDBOX/smartd-active" ] ;;
        *) [ ! -e "$SANDBOX/units/$3.inactive" ] ;;
    esac ;;
    show) [ "$2" != ssh.socket ] || sed "s/.*/[::]:& (Stream)/" "$SANDBOX/socket-ports" 2> /dev/null || true ;;
esac'
}

# A machine where nothing is set up yet
ubuntu_step_setup() {
    ubuntu_step_load
    echo IPV6=yes > "$UFW_DEFAULTS"
    stub_sudo_cacheable
    stub dpkg-query 'echo "install ok installed"'
    stub_systemctl
    stub systemd-detect-virt 'exit 1'
    # Ubuntu's default smartd.conf
    echo "DEVICESCAN -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner" > "$SMARTD_CONF"
    # sysctl-key-fails: fails after applying, as for a key the kernel lacks
    stub sysctl 'live="$SANDBOX/sysctl-live"
    case "$1" in
        --system) [ ! -e "$SANDBOX/sysctl-fails" ] || exit 1
            cat "$SANDBOX/sysctl.d/"*.conf | grep "=" | tr -d " " >> "$live"
            [ ! -e "$SANDBOX/sysctl-key-fails" ] ;;
        -n) grep "^$2=" "$live" 2> /dev/null | tail -n 1 | cut -d= -f2 ;;
    esac'
    stub locale 'echo C.utf8; [ ! -e "$SANDBOX/locale" ] || echo en_US.utf8'
    stub locale-gen 'touch "$SANDBOX/locale"'
    stub apt-get 'cat "$SANDBOX/apt-upgrade" 2> /dev/null || true'
    stub apt-mark
    # As in apt, the last file that sets a key wins
    stub_apt_config 'cat "$SANDBOX/apt.conf.d/"* 2> /dev/null | awk '"'"'{ values[$1] = $0 } END { for (key in values) print values[key] }'"'"''
    stub loginctl
    stub lsblk
    # tailscale-reset: as after Tailscale's first login. tailscale-ssh turns Tailscale SSH on, and
    # tailscale-serve holds the serve and funnel config.
    stub tailscale 'case "$1" in
        debug) if [ -e "$SANDBOX/tailscale-reset" ]; then echo "{}"
            else echo "{\"AutoUpdate\": {\"Apply\": true}, \"OperatorUser\": \"$(id -un)\", \"RunSSH\": $([ -e "$SANDBOX/tailscale-ssh" ] && echo true || echo false)}"; fi ;;
        status) echo "{\"BackendState\": \"$(cat "$SANDBOX/tailscale-state")\"}" ;;
        funnel) cat "$SANDBOX/tailscale-serve" 2> /dev/null || echo "{}" ;;
    esac'
    echo Running > "$SANDBOX/tailscale-state"
    # sshd -T prints what sshd takes from the step's drop-in, after the lines a test writes to
    # $SANDBOX/sshd-T, as sshd keeps the first value per key; test-ubuntu-sshd-real.sh checks the
    # step against the real sshd.
    mkdir -p "$SANDBOX/sshd_config.d" "$SSHD_RUN_DIR"
    # No SSH sessions, as at the console
    stub ss
    stub sshd 'case "$1" in
        -T) [ ! -e "$SANDBOX/sshd-T-fails" ] || exit 255
            cat "$SANDBOX/sshd-T" 2> /dev/null
            printf "%s\n" "port 22" "passwordauthentication no" "kbdinteractiveauthentication no" \
                "permitrootlogin no" "x11forwarding no" "maxauthtries 3" "allowusers $(id -un)" ;;
        -t) for f in "$SANDBOX"/sshd_config.d/*.conf; do
                if grep -q "^Bogus" "$f"; then echo "$f: line 1: Bad configuration option: Bogus" >&2; exit 255; fi
            done ;;
    esac'
    # ufw over $SANDBOX/ufw-status, in `ufw status` format. It's inactive unless $UFW_CONF says
    # ENABLED=yes, or while $SANDBOX/ufw-stopped exists, as after ufw-init stop. As in ufw, IPv6 rules
    # fail with IPV6=no.
    mkdir -p "$(dirname "$UFW_CONF")"
    ufw_status_listing > "$SANDBOX/ufw-status"
    stub ufw 'rules="$SANDBOX/ufw-status"
    case "$1" in
        status) if ! grep -qx ENABLED=yes "'"$UFW_CONF"'" 2> /dev/null || [ -e "$SANDBOX/ufw-stopped" ]; then
                echo "Status: inactive"
            else
                cat "$rules"
            fi ;;
        allow) case "$*" in
                "allow from "*:*) if grep -qx IPV6=no "'"$UFW_DEFAULTS"'"; then
                        echo "ERROR: IPv6 support not enabled" >&2
                        exit 1
                    fi
                    rule="$(printf "%-26s ALLOW       %s" "$7/tcp" "$3")" ;;
                "allow from "*) rule="$(printf "%-26s ALLOW       %s" "$7/tcp" "$3")" ;;
                "allow in on tailscale0") rule="Anywhere on tailscale0     ALLOW       Anywhere" ;;
                *) rule="$(printf "%-26s ALLOW       Anywhere" "$2")" ;;
            esac
            grep -qxF "$rule" "$rules" || echo "$rule" >> "$rules" ;;
        prepend | delete)
            v4="$(printf "%-26s DENY        Anywhere" "$9/tcp on $5")"
            v6="$(printf "%-26s DENY        Anywhere (v6)" "$9/tcp (v6) on $5")"
            if [ "$1" == delete ]; then
                grep -vxF -e "$v4" -e "$v6" "$rules" > "$rules.new" || true
            elif grep -qxF "$v4" "$rules"; then
                exit 0
            else
                awk -v a="$v4" -v b="$v6" "{ print } /^--/ { print a; print b }" "$rules" > "$rules.new"
            fi
            mv "$rules.new" "$rules" ;;
        --force) echo ENABLED=yes > "'"$UFW_CONF"'"
            touch "$SANDBOX/ufw-on"
            rm -f "$SANDBOX/ufw-stopped" ;;
    esac'
    stub nmcli 'case "$*" in
        "-t -e no -f UUID,TYPE,NAME connection show") printf "%s\n" "1111-aaaa:802-3-ethernet:Wired connection 1" "2222-bbbb:802-11-wireless:Home:5G" ;;
        *"-g 802-3-ethernet.wake-on-lan connection show uuid 1111-aaaa") cat "$SANDBOX/wol" ;;
        "connection modify uuid 1111-aaaa 802-3-ethernet.wake-on-lan magic") echo magic > "$SANDBOX/wol" ;;
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
    # As Tailscale's install script writes it
    TAILSCALE_ENTRY="deb [signed-by=$TAILSCALE_KEYRING] https://pkgs.tailscale.com/stable/ubuntu resolute main"
    echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"
}

# Set the machine up with every change approved, leaving both runs' commands in $STUB_LOG
ubuntu_step_set_up() {
    export DOTFILES_ASSUME_YES=1 DOTFILES_SSH_KEY_ONLY=1
    assert_exit 0 main
    cp "$STUB_LOG" "$SANDBOX/set-up.log"
    assert_exit 0 main --status
    cat "$STUB_LOG" >> "$SANDBOX/set-up.log"
    mv "$SANDBOX/set-up.log" "$STUB_LOG"
}
