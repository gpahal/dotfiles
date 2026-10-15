#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail

# The Ubuntu side of the t3-code step. Another T3 Code server keeps setup from changing the
# server's settings or installing the service. An existing service is enabled and started without
# asking, and left alone when it's already both. The step warns when the service lacks the docker
# group you're in. A running service is restarted, after asking once, when its settings or its
# drop-in change, and they change only once it has stopped. A declined restart is offered again.
# The drop-in holds only the telemetry and port settings, and the step installs no desktop app.
# Settings it can't apply fail the step, after the service and browser setup still run.
# Stubs stand in for systemctl, pgrep, id, getent, sleep, and the t3 CLI, and the functions that
# read /proc and /var, and run the installer, are replaced.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/t3-code/install.sh
is_macos() { false; }
# Questions show in the output, and get no, unless a test says yes
confirm() { echo "$1"; false; }

MANUAL_SERVER="304|t3|t3 serve"
MANUAL_MESSAGE="PID 304, a t3 serve started by hand"

# The service's state lives in files: active and enabled. Its main PID is 4242 while active.
# systemd's loaded drop-in is loaded-drop-in, whose Environment= lines it shows.
STATE="$SANDBOX/state"
mkdir -p "$STATE"
SYSTEMCTL_STUB='
state="$(dirname "$STUB_LOG")/state"
case "$2" in
    is-active) [ -f "$state/active" ] ;;
    is-enabled) [ -f "$state/enabled" ] ;;
    start | restart)
        touch "$state/active"
        rm -f "$state/old-env" "$state/old-env-port" "$state/old-env-host"
        ;;
    daemon-reload)
        rm -f "$state/reload-needed"
        cp "$HOME/.config/systemd/user/t3code.service.d/dotfiles.conf" "$state/loaded-drop-in" 2> /dev/null || true
        ;;
    stop) rm -f "$state/active" ;;
    enable) touch "$state/enabled" ;;
    show)
        case "$*" in
            *NeedDaemonReload*)
                if [ -e "$state/reload-needed" ] || { [ -e "$state/loaded-drop-in" ] &&
                    ! cmp -s "$state/loaded-drop-in" "$HOME/.config/systemd/user/t3code.service.d/dotfiles.conf"; }; then
                    echo yes
                else
                    echo no
                fi
                ;;
            *Environment*) sed -n "s/^Environment=//p" "$state/loaded-drop-in" 2> /dev/null | tr "\n" " " ;;
            *) if [ -f "$state/active" ]; then echo 4242; else echo 0; fi ;;
        esac
        ;;
esac'
stub systemctl "$SYSTEMCTL_STUB"
# Processes, one per line of $SANDBOX/procs: "<pid>|<name>|<command line>". -x matches the name,
# -f the command line as an extended regex; -a prints the command line after the PID.
stub pgrep '
procs="$(dirname "$STUB_LOG")/procs"
pattern="${*: -1}" field=3 list=false found=1
for arg in "$@"; do
    case "$arg" in -x) field=2 ;; -a) list=true ;; esac
done
[ -f "$procs" ] || exit 1
while IFS="|" read -r pid name cmd; do
    if [ "$field" = 2 ]; then value="$name"; else value="$cmd"; fi
    if { [ "$field" = 2 ] && [ "$value" = "$pattern" ]; } ||
        { [ "$field" = 3 ] && printf "%s\n" "$value" | grep -qE -- "$pattern"; }; then
        if "$list"; then echo "$pid $cmd"; else echo "$pid"; fi
        found=0
    fi
done < "$procs"
exit "$found"'
stub sleep
# The t3 CLI: `t3 service install` starts the service
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/t3" << 'EOF'
#!/bin/bash
printf '%s\n' "t3 $*" >> "$STUB_LOG"
if [ "$*" == "service install" ]; then
    state="$(dirname "$STUB_LOG")/state"
    mkdir -p "$HOME/.config/systemd/user"
    touch "$HOME/.config/systemd/user/t3code.service" "$state/active" "$state/enabled"
fi
EOF
chmod +x "$HOME/.local/bin/t3"

# No process is in the service's cgroup unless a test says so, and linger is on
t3_code_in_service_cgroup() { false; }
t3_code_lingering() { true; }
# The service's running environment: old-env predates the telemetry line, old-env-port the port,
# old-env-host the host
t3_code_process_environ() {
    if [ -e "$STATE/old-env" ]; then echo T3CODE_TELEMETRY_ENABLED=true
    elif [ -e "$STATE/old-env-port" ]; then echo T3CODE_TELEMETRY_ENABLED=false
    elif [ -e "$STATE/old-env-host" ]; then printf '%s\n' T3CODE_TELEMETRY_ENABLED=false T3CODE_PORT=3773
    else printf '%s\n' T3CODE_TELEMETRY_ENABLED=false T3CODE_PORT=3773 T3CODE_HOST=127.0.0.1; fi
}

# A drop-in from an older version of this step, which systemd has loaded
old_drop_in() {
    echo "# old" > "$T3_CODE_SERVICE_DROP_IN"
    cp "$T3_CODE_SERVICE_DROP_IN" "$STATE/loaded-drop-in"
}

# reset: no processes, no service, no settings, and an empty stub log
reset() {
    rm -f "$SANDBOX/procs" "$STATE"/* "$T3_CODE_SETTINGS" "$T3_CODE_SERVICE_UNIT"
    rm -rf "$T3_CODE_SERVICE_UNIT.d"
    : > "$STUB_LOG"
}

# A unit that exists, with its drop-in and settings already in place
installed_unit() {
    mkdir -p "$(dirname "$T3_CODE_SERVICE_DROP_IN")"
    touch "$T3_CODE_SERVICE_UNIT"
    printf '%s\n' "$T3_CODE_SERVICE_DROP_IN_CONTENT" > "$T3_CODE_SERVICE_DROP_IN"
    cp "$T3_CODE_SERVICE_DROP_IN" "$STATE/loaded-drop-in"
    json_merge "$T3_CODE_SETTINGS" "$T3_CODE_SERVER_FILTER" > /dev/null
    : > "$STUB_LOG"
}

# A t3 serve started by hand, even with an existing, stopped service: neither the settings nor
# the service change, and nothing starts
reset
installed_unit
echo "$MANUAL_SERVER" > "$SANDBOX/procs"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Another T3 Code server is running, so skipping the server settings and the service"
assert_contains "$RUN_OUTPUT" "$MANUAL_MESSAGE"
assert_file_not_contains "$STUB_LOG" "systemctl --user start"

# A changed drop-in while another server runs is left for the next run, so the running service
# still gets restarted for it once that server stops
reset
installed_unit
old_drop_in
touch "$STATE/old-env"
touch "$STATE/active" "$STATE/enabled"
echo "$MANUAL_SERVER" > "$SANDBOX/procs"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "$MANUAL_MESSAGE"
t3_code_drop_in_current && fail "the drop-in was written while another server ran"
assert_file_not_contains "$STUB_LOG" "systemctl --user daemon-reload"
rm "$SANDBOX/procs"
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Restart the T3 Code service to apply its settings and drop-in?"
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running, without its new settings and drop-in."

# A t3 serve inside the service's cgroup is the service's own
reset
echo "$MANUAL_SERVER" > "$SANDBOX/procs"
t3_code_in_service_cgroup() { true; }
assert_eq "" "$(t3_code_other_servers)" "a server in the service's cgroup"
t3_code_in_service_cgroup() { false; }

# A server the Mac started over SSH, which runs the t3 its runner downloaded to ~/.t3/runtime, also
# skips both
reset
echo "302|t3|$HOME/.t3/runtime/versions/0.0.45/t3 serve --host 127.0.0.1 --port 3774 --base-dir $HOME/.t3" > "$SANDBOX/procs"
assert_eq "302 ssh $HOME/.t3/runtime/versions/0.0.45/t3 serve --host 127.0.0.1 --port 3774 --base-dir $HOME/.t3" \
    "$(t3_code_other_servers)" "other server"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "PID 302, a server the Mac started over SSH"
[ ! -f "$T3_CODE_SETTINGS" ] || fail "server settings were written while another server ran"
assert_file_not_contains "$STUB_LOG" "t3 service install"
# So does a t3 serve started by hand
reset
echo "304|t3|t3 serve" > "$SANDBOX/procs"
assert_eq "304 manual t3 serve" "$(t3_code_other_servers)" "other server"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "PID 304, a t3 serve started by hand (t3 serve); to fix it, stop it (kill 304)"
[ ! -f "$T3_CODE_SETTINGS" ] || fail "server settings were written while a manual server ran"

# Status names each T3 Code server outside the service, with its PID, kind, and command line, as
# missing: a server the Mac started over SSH, and a t3 serve started by hand. The service's own server, in its cgroup, isn't one, nor is another program that runs serve.
reset
installed_unit
touch "$STATE/active" "$STATE/enabled"
printf '%s\n' "302|t3|$HOME/.t3/runtime/versions/0.0.45/t3 serve --host 127.0.0.1 --port 3774 --base-dir $HOME/.t3" \
    "304|t3|$HOME/.local/bin/t3 serve --port 3780" \
    "305|t3|$HOME/.t3/runtime/versions/0.0.45/t3 serve" \
    "306|vim|vim notes.txt" \
    "307|python3|python3 manage.py serve --port 8000" > "$SANDBOX/procs"
t3_code_in_service_cgroup() { [ "$1" == 305 ]; }
assert_eq "302 ssh
304 manual" "$(t3_code_other_servers | cut -d' ' -f1-2)" "the other servers"
run status
assert_eq 3 "$RUN_STATUS" "status's exit with other servers"
assert_contains "$RUN_OUTPUT" "skipped    T3 Code desktop app and its settings: macOS only"
assert_contains "$RUN_OUTPUT" "missing    No T3 Code server outside t3code.service: PID 302, a server the Mac started over SSH"
assert_contains "$RUN_OUTPUT" "missing    No T3 Code server outside t3code.service: PID 304, a t3 serve started by hand ($HOME/.local/bin/t3 serve --port 3780)"
assert_not_contains "$RUN_OUTPUT" "PID 305"
assert_not_contains "$RUN_OUTPUT" "PID 306"
assert_not_contains "$RUN_OUTPUT" "PID 307"
assert_contains "$RUN_OUTPUT" "to fix it, remove this host's SSH connection in T3 Code on the Mac, connect over Tailscale instead (see ai_tools/README.md → Manual steps)"
# None: ok
rm -f "$SANDBOX/procs"
run status
assert_contains "$RUN_OUTPUT" "ok         No T3 Code server outside t3code.service"
t3_code_in_service_cgroup() { false; }

# No other server and no unit: the service is installed
reset
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "t3 service install"
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"

# An existing unit that's stopped and disabled gets enabled and started, without asking
reset
installed_unit
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user enable t3code.service"
assert_file_contains "$STUB_LOG" "systemctl --user start t3code.service"
assert_contains "$RUN_OUTPUT" "Enabled the T3 Code service"
assert_contains "$RUN_OUTPUT" "Started the T3 Code service"
assert_file_not_contains "$STUB_LOG" "reset-failed"

# Disabled but running: only enabled
reset
installed_unit
touch "$STATE/active"
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user enable t3code.service"
assert_file_not_contains "$STUB_LOG" "systemctl --user start"
assert_file_not_contains "$STUB_LOG" "systemctl --user restart"

# Running and enabled: nothing changes
reset
installed_unit
touch "$STATE/active" "$STATE/enabled"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "already installed and running"
for action in enable start stop restart daemon-reload; do
    assert_file_not_contains "$STUB_LOG" "systemctl --user $action"
done

# A service that won't stay up fails the step, saying where to look
reset
installed_unit
stub systemctl '
state="$(dirname "$STUB_LOG")/state"
case "$2" in
    is-enabled) [ -f "$state/enabled" ] ;;
    enable) touch "$state/enabled" ;;
    is-active) false ;;
    show) case "$*" in
        *NeedDaemonReload*) echo no ;;
        *Environment*) echo "T3CODE_TELEMETRY_ENABLED=false T3CODE_PORT=3773 T3CODE_HOST=127.0.0.1" ;;
        *) echo 0 ;;
    esac ;;
esac'
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Check ~/.t3/userdata/logs/boot-service.log"
stub systemctl "$SYSTEMCTL_STUB"

# Linger off with an existing unit: say so, still repair the service, and don't fail
reset
installed_unit
t3_code_lingering() { false; }
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Linger is off"
assert_file_contains "$STUB_LOG" "systemctl --user start t3code.service"
t3_code_lingering() { true; }

# Linger off with no unit: the service isn't installed, since it would start only at login, and
# the step fails, saying how to turn linger on. Status says the same.
reset
t3_code_lingering() { false; }
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Linger is off"
assert_contains "$RUN_OUTPUT" "bash setup.sh ubuntu"
assert_file_not_contains "$STUB_LOG" "t3 service install"
run status
assert_contains "$RUN_OUTPUT" 'missing    T3 Code service: turn on linger: `bash setup.sh ubuntu`'
t3_code_lingering() { true; }

# Status reports whether the service starts at boot
reset
installed_unit
touch "$STATE/active"
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service enabled at boot"
touch "$STATE/enabled"
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code service enabled at boot"

# No unit: status says how to create it, and doesn't blame linger
reset
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service: re-run the t3-code step (bash ai_tools/setup.sh t3-code), which runs t3 service install"
assert_not_contains "$RUN_OUTPUT" "inger"

# You're in the docker group, but the service's process isn't
reset
installed_unit
touch "$STATE/active" "$STATE/enabled"
stub id "case \"\$*\" in -nG*) echo 'me adm docker' ;; -u) echo 1000 ;; *) echo me ;; esac"
stub getent '[ "$*" != "group docker" ] || echo "docker:x:998:me"'
t3_code_process_groups() { echo "4 24 27"; }
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "still has the groups it had before you joined the docker group"
assert_contains "$RUN_OUTPUT" "sudo systemctl restart user@1000"
# The service has the group: no warning
t3_code_process_groups() { echo "4 24 27 998"; }
assert_exit 0 configure_t3_code_ubuntu
assert_not_contains "$RUN_OUTPUT" "docker group"
# You're not in the group: no warning
stub id "case \"\$*\" in -nG*) echo 'me adm' ;; -u) echo 1000 ;; *) echo me ;; esac"
t3_code_process_groups() { echo "4 24 27"; }
assert_exit 0 configure_t3_code_ubuntu
assert_not_contains "$RUN_OUTPUT" "docker group"
rm -f "$STUB_DIR/id" "$STUB_DIR/getent"

# Changing the settings of a running service stops it first, and fails, writing nothing, when it
# doesn't stop
reset
installed_unit
echo '{}' > "$T3_CODE_SETTINGS"
touch "$STATE/active" "$STATE/enabled"
confirm() { echo "$1"; }
stub systemctl "[ \"\$2\" != stop ] || exit 1
$SYSTEMCTL_STUB"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Couldn't stop the T3 Code service"
assert_eq '{}' "$(cat "$T3_CODE_SETTINGS")" "settings after a failed stop"
assert_not_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
# A stop that leaves it running fails too
stub systemctl "[ \"\$2\" != stop ] || exit 0
$SYSTEMCTL_STUB"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Couldn't stop the T3 Code service"
assert_eq '{}' "$(cat "$T3_CODE_SETTINGS")" "settings after a stop that left it running"
# A service that doesn't start again fails, after the settings change
stub systemctl "[ \"\$2\" != start ] || exit 1
$SYSTEMCTL_STUB"
assert_exit 1 configure_t3_code_ubuntu
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"
assert_not_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
assert_contains "$RUN_OUTPUT" "Check ~/.t3/userdata/logs/boot-service.log"
# Stopped and started again: success, after one question
stub systemctl "$SYSTEMCTL_STUB"
echo '{}' > "$T3_CODE_SETTINGS"
touch "$STATE/active"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
assert_eq 1 "$(grep -c 'Restart the T3 Code service' <<< "$RUN_OUTPUT")" "restart questions"
assert_file_contains "$STUB_LOG" "systemctl --user stop t3code.service"
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"
confirm() { echo "$1"; false; }

# A changed drop-in and settings on a running service are one question. Declined, nothing changes,
# the question comes again on the next run, and status reports the drop-in and the pending restart.
reset
installed_unit
old_drop_in
echo '{}' > "$T3_CODE_SETTINGS"
touch "$STATE/old-env" "$STATE/active" "$STATE/enabled"
assert_exit 0 configure_t3_code_ubuntu
assert_eq 1 "$(grep -c 'Restart the T3 Code service' <<< "$RUN_OUTPUT")" "restart questions"
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running, without its new settings and drop-in."
t3_code_drop_in_current && fail "the drop-in was written after a declined restart"
assert_eq '{}' "$(cat "$T3_CODE_SETTINGS")" "settings after a declined restart"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running"
run status
assert_contains "$RUN_OUTPUT" "missing    Telemetry off, port 3773, and host 127.0.0.1 in the service drop-in"
assert_contains "$RUN_OUTPUT" "missing    T3 Code service restarted for its drop-in: systemctl --user restart t3code"
# Accepted, the service stops, both change, and it starts again. Then nothing is pending.
confirm() { echo "$1"; }
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_eq "systemctl --user stop t3code.service
systemctl --user daemon-reload
systemctl --user start t3code.service" "$(grep -E 'systemctl --user (stop|start|restart|daemon-reload)' "$STUB_LOG")" "the restart"
t3_code_drop_in_current || fail "the drop-in wasn't written"
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"
confirm() { echo "$1"; false; }
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "already set"
assert_file_not_contains "$STUB_LOG" "systemctl --user stop"
run status
assert_not_contains "$RUN_OUTPUT" "restarted for its drop-in"

# A service whose process predates the drop-in's environment is pending a restart
reset
installed_unit
touch "$STATE/active" "$STATE/enabled" "$STATE/old-env"
assert_exit 0 t3_code_restart_pending

# A restart whose start fails fails the step, and the next run starts the service
confirm() { echo "$1"; }
stub systemctl '[ "$2" != start ] || exit 1
'"$SYSTEMCTL_STUB"
# As main runs it: under ||, where set -e is off
conditional_configure() { configure_t3_code_ubuntu || return 1; }
assert_exit 1 conditional_configure
assert_not_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
stub systemctl "$SYSTEMCTL_STUB"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Started the T3 Code service"
assert_exit 1 t3_code_restart_pending

# A failed reload is retried even though the drop-in now matches the desired file.
old_drop_in
touch "$STATE/reload-needed" "$STATE/old-env"
stub systemctl '[ "$2" != daemon-reload ] || exit 1
'"$SYSTEMCTL_STUB"
assert_exit 1 conditional_configure
stub systemctl "$SYSTEMCTL_STUB"
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" 'systemctl --user daemon-reload'
assert_exit 1 t3_code_restart_pending
confirm() { echo "$1"; false; }

# The drop-in sets only telemetry, the port, and the loopback host, in [Service]. The start limit
# and oomd's preference are left to T3's unit.
reset
assert_exit 0 configure_t3_code_ubuntu
assert_eq "[Service]
Environment=T3CODE_TELEMETRY_ENABLED=false
Environment=T3CODE_PORT=3773
Environment=T3CODE_HOST=127.0.0.1" "$(cat "$T3_CODE_SERVICE_DROP_IN")" "the drop-in"
run status
assert_contains "$RUN_OUTPUT" "ok         Telemetry off, port 3773, and host 127.0.0.1 in the service drop-in"
# A unit systemd loaded without the drop-in's environment is reloaded
installed_unit
rm "$STATE/loaded-drop-in"
touch "$STATE/active" "$STATE/enabled"
assert_exit 1 t3_code_drop_in_loaded
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
assert_exit 1 t3_code_restart_pending
# A server started before the port line is pending a restart, and status says so
touch "$STATE/old-env-port"
assert_exit 0 t3_code_restart_pending
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service restarted for its drop-in"
confirm() { echo "$1"; }
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user stop t3code.service"
assert_file_contains "$STUB_LOG" "systemctl --user start t3code.service"
assert_exit 1 t3_code_restart_pending
# Likewise a server started before the host line
touch "$STATE/old-env-host"
assert_exit 0 t3_code_restart_pending
confirm() { echo "$1"; false; }

# An enabled unit without linger doesn't start at boot until login.
t3_code_lingering() { false; }
run status
assert_contains "$RUN_OUTPUT" 'missing    Linger enabled for T3 Code to start without login'
t3_code_lingering() { true; }

# On Ubuntu, main sets up the server and its service, and nothing else: no desktop app, and no
# telemetry line in ~/.profile
reset
run main
assert_eq 0 "$RUN_STATUS" "main's exit status"
assert_file_contains "$STUB_LOG" "t3 service install"
assert_not_contains "$RUN_OUTPUT" "desktop app"
[ ! -e "$HOME/.profile" ] || assert_file_not_contains "$HOME/.profile" "T3CODE_TELEMETRY_ENABLED"

# A settings.json it can't parse fails the step, after it still installs the service and sets up
# the browser
reset
mkdir -p "$(dirname "$T3_CODE_SETTINGS")"
echo "not json" > "$T3_CODE_SETTINGS"
assert_exit 1 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "t3 service install"
assert_file_contains "$STUB_LOG" "t3 browser setup"

# Released CLIs without the browser subcommand are skipped; failures in supported CLIs are not.
cat > "$HOME/.local/bin/t3" << 'EOF'
#!/bin/bash
mode="$(cat "$(dirname "$STUB_LOG")/state/browser-mode")"
if [ "$1" == --help ]; then
    printf 'SUBCOMMANDS\n  serve    Run the server.\n'
    [ "$mode" == unsupported ] || echo '  browser  Manage the browser.'
    exit 0
fi
case "$mode" in
    unsupported) echo 'Unexpected positional argument: "setup"'; exit 1 ;;
    failed) echo 'Browser setup failed'; exit 1 ;;
    needs-root) echo 'AppArmor profile needs root' ;;
esac
EOF
echo unsupported > "$STATE/browser-mode"
assert_exit 3 t3_code_browser_ready
assert_exit 0 setup_t3_code_browser
assert_contains "$RUN_OUTPUT" 'does not provide t3 browser setup; skipping'
run status
assert_contains "$RUN_OUTPUT" 'skipped    Browser sandbox: this t3 release does not provide t3 browser setup'
echo failed > "$STATE/browser-mode"
assert_exit 2 t3_code_browser_ready
assert_exit 1 setup_t3_code_browser
echo needs-root > "$STATE/browser-mode"
assert_exit 1 t3_code_browser_ready
# Needing root, the step prints the command for you to run and doesn't fail. ~/.local/bin/t3 is
# yours to write and updates itself, so the step never runs it under sudo, even when you'd agree.
stub sudo 'exec "$@"'
confirm() { echo "$1"; }
: > "$STUB_LOG"
assert_exit 0 setup_t3_code_browser
assert_contains "$RUN_OUTPUT" 'sudo ~/.local/bin/t3 browser setup'
assert_file_not_contains "$STUB_LOG" 'sudo'
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code's browser can run in Chrome's sandbox: run sudo ~/.local/bin/t3 browser setup"
stub sudo 'exit 1'
confirm() { echo "$1"; false; }
echo ready > "$STATE/browser-mode"
assert_exit 0 t3_code_browser_ready

# Status reports T3 Connect from `t3 connect status --json`: linked and publishing agent activity
# is ok. Otherwise it names what's left: the whole sign-in, a restart that sets up a link already
# authorized, or only publishing. Output it can't read, or no t3, is unknown.
reset
installed_unit
touch "$STATE/active" "$STATE/enabled"
cat > "$HOME/.local/bin/t3" << 'EOF'
#!/bin/bash
printf '%s\n' "t3 $*" >> "$STUB_LOG"
[ "$*" != "connect status --json" ] || cat "$(dirname "$STUB_LOG")/state/connect"
EOF
chmod +x "$HOME/.local/bin/t3"
connect() {
    jq -n --argjson d "$1" --argjson a "$2" --argjson l "$3" --argjson p "$4" \
        '{desired: $d, authenticated: $a, linked: $l, cloudUserId: null, relayUrl: null, publishAgentActivity: $p, relayClient: null}' \
        > "$STATE/connect"
}
connect true true true true
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Connect linked and publishing agent activity"
assert_file_contains "$STUB_LOG" "t3 connect status --json"
connect true true true false
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Connect linked and publishing agent activity: run t3 connect publish"
connect true true false true
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Connect linked and publishing agent activity: the server sets up the link when it starts: t3 service restart"
connect false false false false
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Connect linked and publishing agent activity: run t3 connect --headless, then t3 connect publish and t3 service restart (see ai_tools/README.md → Manual steps)"
assert_eq 3 "$RUN_STATUS" "status's exit when T3 Connect isn't set up"
echo "not json" > "$STATE/connect"
run status
assert_contains "$RUN_OUTPUT" "unknown    T3 Connect: t3 connect status didn't say; run it to see why"
mv "$HOME/.local/bin/t3" "$SANDBOX/t3"
run status
assert_contains "$RUN_OUTPUT" "unknown    T3 Connect: needs the t3 CLI"
mv "$SANDBOX/t3" "$HOME/.local/bin/t3"

# The t3 installer fails with any status, 2 included, or succeeds without leaving t3: the step
# fails, and no service is installed. Only declining the sudo for libatomic1 doesn't fail it.
reset
rm -f "$HOME/.local/bin/t3"
apt_installed() { [ "$1" != libatomic1 ] || [ -e "$STATE/libatomic1" ]; }
run_installer() {
    echo "run_installer $*" >> "$STUB_LOG"
    return "$(cat "$STATE/installer-status")"
}
touch "$STATE/libatomic1"
for code in 2 3 0; do
    echo "$code" > "$STATE/installer-status"
    : > "$STUB_LOG"
    assert_exit 1 configure_t3_code_ubuntu
    assert_file_contains "$STUB_LOG" "run_installer sh https://t3.codes/install.sh"
    assert_file_not_contains "$STUB_LOG" "t3 service install"
    assert_contains "$RUN_OUTPUT" "Without the t3 CLI there's no service to install"
done
assert_contains "$RUN_OUTPUT" "The t3 installer finished, but $HOME/.local/bin/t3 isn't there"
rm "$STATE/libatomic1"
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Install libatomic1"
assert_file_not_contains "$STUB_LOG" "run_installer"
test_done
