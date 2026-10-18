# The machine the test-ubuntu-*.sh tests of the ubuntu step's main and status share, set up through
# sandbox paths (tests/ubuntu-sandbox.sh), with sudo, systemctl, sysctl, sshd, ss, ufw, nmcli,
# tailscale, apt-config, apt-get, locale, locale-gen, and git's worktree check as stubs. Source it
# after tests/lib.sh and tests/ubuntu-sandbox.sh, then call setup_sandbox and ubuntu_step_setup.
# ubuntu_step_set_up then runs the step with every change approved, for a test that starts from a
# machine already set up. Bash 3.2.
# shellcheck shell=bash
# The step's functions call the ones this file replaces
# shellcheck disable=SC2329

# Load the step, point it into the sandbox, and replace the checks the tests leave to others. Run
# it again to bring back a function a test replaced.
ubuntu_step_load() {
    load_script ubuntu/install.sh
    ubuntu_sandbox_paths
    is_ubuntu() { true; }
    ufw_enabled() { [ -e "$SANDBOX/ufw-on" ]; }
    lingering() { true; }
    # test-diagnostics-ubuntu.sh covers SMART health and firmware updates
    status_smart() { :; }
    status_firmware() { :; }
    # test-ubuntu-ups.sh covers the UPS
    ups_todo() { :; }
    status_ups() { :; }
    warn_no_ups() { :; }
    # This checkout may be a worktree, so the check is replaced, and test-ubuntu-step.sh tests the
    # real one
    declare -F real_in_git_worktree > /dev/null || eval "real_$(declare -f in_git_worktree)"
    in_git_worktree() { false; }
}

# systemctl: the sleep targets are masked, apt's timers and ssh.socket are enabled, as on 26.04,
# unless $SANDBOX/units/<unit> holds another state, which enable of ssh.socket sets to enabled.
# A unit is active unless $SANDBOX/units/<unit>.inactive exists. enable --now of apt's timers
# enables and starts them, unless $SANDBOX/timers-fail exists. smartd is enabled and running once systemctl enable --now
# ran, unless $SANDBOX/smartd-failed exists, which only restart clears. A user unit is enabled
# once systemctl --user enable ran, and active once enable --now did. A user unit needs a
# daemon-reload while $SANDBOX/reload-needed exists, which daemon-reload removes, unless
# $SANDBOX/reload-fails exists. A test's own lines go first.
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

# Load the step, and write the stubs and files of a machine where nothing is set up yet
ubuntu_step_setup() {
    ubuntu_step_load
    echo IPV6=yes > "$UFW_DEFAULTS"
    # sudo runs the command, and refuses a path outside the sandbox. sudo -n fails, as without cached
    # credentials.
    not_cached_sudo() { stub_sudo_exec '[ "${1:-}" != -n ] || exit 1'; }
    not_cached_sudo
    stub dpkg-query 'echo "install ok installed"'
    stub_systemctl
    stub systemd-detect-virt 'exit 1'
    # sysctl --system puts the settings of the files in $SANDBOX/sysctl.d in effect. It fails when
    # $SANDBOX/sysctl-fails exists. sysctl -n prints one setting.
    stub sysctl 'live="'"$SANDBOX"'/sysctl-live"
    case "$1" in
        --system) [ ! -e "'"$SANDBOX"'/sysctl-fails" ] || exit 1
            cat "'"$SANDBOX"'/sysctl.d/"*.conf | grep "=" | tr -d " " >> "$live" ;;
        -n) grep "^$2=" "$live" 2> /dev/null | tail -n 1 | cut -d= -f2 ;;
    esac'
    # The en_US.UTF-8 locale is there once locale-gen ran
    stub locale 'echo C.utf8; [ ! -e "'"$SANDBOX"'/locale" ] || echo en_US.utf8'
    stub locale-gen 'touch "'"$SANDBOX"'/locale"'
    # apt-get -s upgrade prints $SANDBOX/apt-upgrade
    stub apt-get 'cat "'"$SANDBOX"'/apt-upgrade" 2> /dev/null || true'
    # No package is on hold with apt-mark
    stub apt-mark
    # unattended-upgrades runs daily once a file in $SANDBOX/apt.conf.d says so. As in apt, the last file
    # that sets it wins.
    stub_apt_config 'cat "'"$SANDBOX"'/apt.conf.d/"* 2> /dev/null | awk '"'"'{ values[$1] = $0 } END { for (key in values) print values[key] }'"'"''
    stub loginctl
    stub lsblk
    # Tailscale auto-updates, with you as its operator, until $SANDBOX/tailscale-reset exists, as after
    # its first login, and its state is in $SANDBOX/tailscale-state
    stub tailscale 'case "$1" in
        debug) if [ -e "'"$SANDBOX"'/tailscale-reset" ]; then echo "{}"
            else echo "{\"AutoUpdate\": {\"Apply\": true}, \"OperatorUser\": \"$(id -un)\"}"; fi ;;
        status) echo "{\"BackendState\": \"$(cat "'"$SANDBOX"'/tailscale-state")\"}" ;;
    esac'
    echo Running > "$SANDBOX/tailscale-state"
    # sshd -t fails on any drop-in with a "Bogus" line, naming the file the way sshd does. sshd -T
    # prints the port, and the settings the drop-in sets as sshd reads them: the first value in the
    # drop-ins in name order, or sshd's default, and every AllowUsers line's users. With -C
    # user=<user>,..., a "Match User <user>" block's first value wins over those. sshd -T fails while
    # $SANDBOX/sshd-T-fails exists.
    mkdir -p "$SANDBOX/sshd_config.d" "$SSHD_RUN_DIR"
    # No SSH sessions, as at the console. test-ufw-recheck.sh covers them.
    stub ss
    stub sshd 'case "$1" in
        -T) [ ! -e "'"$SANDBOX"'/sshd-T-fails" ] || exit 255
            user=""
            [ "${2:-}" != -C ] || user="$(sed -n "s/^user=\([^,]*\).*/\1/p" <<< "$3")"
            echo "port 22"
            cat "'"$SANDBOX"'"/sshd_config.d/*.conf 2> /dev/null | awk -v user="$user" '"'"'
                { k = tolower($1) }
                k == "match" { matched = tolower($2) == "user" && $3 == user; inmatch = 1; next }
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
    # ufw status lists every rule the step adds, once it has run ufw --force enable
    stub ufw 'case "$1" in
        --force) touch "'"$SANDBOX"'/ufw-on" ;;
        status) [ -e "'"$SANDBOX"'/ufw-on" ] && printf "%s\n" "Status: active" "" \
            "22/tcp                     ALLOW       10.0.0.0/8" \
            "22/tcp                     ALLOW       192.168.0.0/16" \
            "22/tcp                     ALLOW       fd00::/8" \
            "22/tcp                     ALLOW       fe80::/10" \
            "Anywhere on tailscale0     ALLOW       Anywhere" \
            "41641/udp                  ALLOW       Anywhere" ;;
    esac'
    # One wired connection, "Wired connection 1", whose Wake-on-LAN setting is in $SANDBOX/wol, and
    # a Wi-Fi one. The step names connections by UUID, since two can share a name.
    stub nmcli 'case "$*" in
        "-t -e no -f UUID,TYPE,NAME connection show") printf "%s\n" "1111-aaaa:802-3-ethernet:Wired connection 1" "2222-bbbb:802-11-wireless:Home:5G" ;;
        *"-g 802-3-ethernet.wake-on-lan connection show uuid 1111-aaaa") cat "'"$SANDBOX"'/wol" ;;
        "connection modify uuid 1111-aaaa 802-3-ethernet.wake-on-lan magic") echo magic > "'"$SANDBOX"'/wol" ;;
    esac'
    echo default > "$SANDBOX/wol"
    mkdir "$SANDBOX/units" "$SANDBOX/user-units"
    # shellcheck disable=SC2034 # test-ubuntu-step.sh reads it
    KEEP_CONFFILES="Updates keep conffiles you edited, so unattended-upgrades doesn't skip them ($KEEP_CONFFILES_CONF)"
    # Tailscale's apt source, as its install script writes it
    TAILSCALE_ENTRY="deb [signed-by=$TAILSCALE_KEYRING] https://pkgs.tailscale.com/stable/ubuntu resolute main"
    echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"
}

# Run the step with every change approved, as test-ubuntu-step.sh's first approved run does, so a
# test starts from a machine that's set up. With no SSH key login to go by, the VM opt-in turns
# password logins off.
ubuntu_step_set_up() {
    export DOTFILES_ASSUME_YES=1 DOTFILES_SSH_KEY_ONLY=1
    assert_exit 0 main
    assert_exit 0 status
}
