#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script ai_tools/t3-code/install.sh
as_os ubuntu
# The service alone, as on Ubuntu Server; test-t3-desktop-ubuntu.sh covers the desktop app
replace_fn has_gnome_desktop 'false'
answer no

MANUAL_SERVER="304|t3|t3 serve"
MANUAL_MESSAGE="PID 304, a t3 serve started by hand"

# start-limit-hit refuses a start until reset-failed; idle (no server) clears on a start.
STATE="$SANDBOX/state"
mkdir -p "$STATE"
SYSTEMCTL_STUB='
state="$(dirname "$STUB_LOG")/state"
case "$2" in
    is-active) [ -f "$state/active" ] ;;
    is-enabled) [ -f "$state/enabled" ] ;;
    is-failed) [ -e "$state/start-limit-hit" ] ;;
    start | restart)
        [ ! -e "$state/start-limit-hit" ] || exit 1
        touch "$state/active"
        rm -f "$state/old-env" "$state/old-env-host" "$state/idle"
        ;;
    daemon-reload)
        rm -f "$state/reload-needed"
        cp "$HOME/.config/systemd/user/t3code.service.d/dotfiles.conf" "$state/loaded-drop-in" 2> /dev/null || true
        ;;
    stop) rm -f "$state/active" ;;
    reset-failed) rm -f "$state/start-limit-hit" ;;
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
# Each line of $SANDBOX/procs is "<pid>|<name>|<command line>".
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
stub ss '
state="$(dirname "$STUB_LOG")/state"
[ ! -f "$state/active" ] || echo "LISTEN 0      511        127.0.0.1:3773      0.0.0.0:*"
[ ! -f "$state/listeners" ] || cat "$state/listeners"'
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

replace_fn t3_code_in_service_cgroup 'false'
replace_fn t3_code_lingering 'true'
# always-idle survives a start.
replace_fn t3_code_launcher_has_server '[ ! -e "$STATE/idle" ] && [ ! -e "$STATE/always-idle" ]'
# old-env predates the telemetry line, old-env-host the host line.
replace_fn t3_code_process_environ '
if [ -e "$STATE/old-env" ]; then
    echo T3CODE_TELEMETRY_ENABLED=true
    return
fi
echo T3CODE_TELEMETRY_ENABLED=false
echo T3CODE_PORT=3773
[ -e "$STATE/old-env-host" ] || echo T3CODE_HOST=127.0.0.1'

different_drop_in() {
    echo "# different" > "$T3_CODE_SERVICE_DROP_IN"
    cp "$T3_CODE_SERVICE_DROP_IN" "$STATE/loaded-drop-in"
}

reset() {
    rm -f "$SANDBOX/procs" "$STATE"/* "$T3_CODE_SETTINGS" "$T3_CODE_SERVICE_UNIT"
    rm -rf "$T3_CODE_SERVICE_UNIT.d"
    : > "$STUB_LOG"
}

installed_unit() {
    mkdir -p "$(dirname "$T3_CODE_SERVICE_DROP_IN")"
    touch "$T3_CODE_SERVICE_UNIT"
    printf '%s\n' "$T3_CODE_SERVICE_DROP_IN_CONTENT" > "$T3_CODE_SERVICE_DROP_IN"
    cp "$T3_CODE_SERVICE_DROP_IN" "$STATE/loaded-drop-in"
    json_merge "$T3_CODE_SETTINGS" "$(t3_code_server_filter)" > /dev/null
    : > "$STUB_LOG"
}

# A t3 serve started by hand: nothing changes or starts
reset
installed_unit
echo "$MANUAL_SERVER" > "$SANDBOX/procs"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Another T3 Code server is running, so skipping the server settings and the service"
assert_contains "$RUN_OUTPUT" "$MANUAL_MESSAGE"
assert_file_not_contains "$STUB_LOG" "systemctl --user start"

# A drop-in change while another server runs is applied once it stops
reset
installed_unit
different_drop_in
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
assert_contains "$RUN_OUTPUT" "Wrote the drop-in; it applies at the next restart of the T3 Code service"

reset
echo "$MANUAL_SERVER" > "$SANDBOX/procs"
replace_fn t3_code_in_service_cgroup 'true'
assert_eq "" "$(t3_code_other_servers)" "a server in the service's cgroup"
replace_fn t3_code_in_service_cgroup 'false'

# A server the Mac started over SSH from ~/.t3/runtime is skipped too
reset
echo "302|t3|$HOME/.t3/runtime/versions/0.0.45/t3 serve --host 127.0.0.1 --port 3774 --base-dir $HOME/.t3" > "$SANDBOX/procs"
assert_eq "302 ssh $HOME/.t3/runtime/versions/0.0.45/t3 serve --host 127.0.0.1 --port 3774 --base-dir $HOME/.t3" \
    "$(t3_code_other_servers)" "other server"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "PID 302, a server the Mac started over SSH"
[ ! -f "$T3_CODE_SETTINGS" ] || fail "server settings were written while another server ran"
assert_file_not_contains "$STUB_LOG" "t3 service install"

# Regex characters in HOME match only themselves
special_home() {
    HOME="$SANDBOX/a+b"
    load_script ai_tools/t3-code/install.sh
    replace_fn t3_code_in_service_cgroup 'false'
    echo "302|t3|$SANDBOX/a+b/.t3/runtime/versions/0.0.45/t3 serve" > "$SANDBOX/procs"
    assert_eq "302 ssh" "$(t3_code_other_servers | cut -d' ' -f1-2)" "a server under a HOME with a +"
    echo "302|t3|$SANDBOX/aab/.t3/runtime/versions/0.0.45/t3 serve" > "$SANDBOX/procs"
    assert_eq "302 manual" "$(t3_code_other_servers | cut -d" " -f1-2)" "a server under another HOME"
}
reset
subtest special_home
reset

reset
installed_unit
touch "$STATE/active" "$STATE/enabled"
printf '%s\n' "302|t3|$HOME/.t3/runtime/versions/0.0.45/t3 serve --host 127.0.0.1 --port 3774 --base-dir $HOME/.t3" \
    "304|t3|$HOME/.local/bin/t3 serve --port 3780" \
    "305|t3|$HOME/.t3/runtime/versions/0.0.45/t3 serve" \
    "306|vim|vim notes.txt" \
    "307|python3|python3 manage.py serve --port 8000" > "$SANDBOX/procs"
replace_fn t3_code_in_service_cgroup '[ "$1" == 305 ]'
assert_eq "302 ssh
304 manual" "$(t3_code_other_servers | cut -d' ' -f1-2)" "the other servers"
run status
assert_eq 3 "$RUN_STATUS" "status's exit with other servers"
assert_contains "$RUN_OUTPUT" "skipped    T3 Code desktop app: no GNOME desktop"
assert_contains "$RUN_OUTPUT" "missing    No T3 Code server outside t3code.service: PID 302, a server the Mac started over SSH"
assert_contains "$RUN_OUTPUT" "missing    No T3 Code server outside t3code.service: PID 304, a t3 serve started by hand ($HOME/.local/bin/t3 serve --port 3780)"
assert_not_contains "$RUN_OUTPUT" "PID 305"
assert_not_contains "$RUN_OUTPUT" "PID 306"
assert_not_contains "$RUN_OUTPUT" "PID 307"
assert_contains "$RUN_OUTPUT" "to fix it, remove this host's SSH connection in T3 Code on the Mac, connect over Tailscale instead (see ai_tools/README.md → Manual steps)"
rm -f "$SANDBOX/procs"
run status
assert_contains "$RUN_OUTPUT" "ok         No T3 Code server outside t3code.service"
replace_fn t3_code_in_service_cgroup 'false'

reset
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "t3 service install"
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"

reset
installed_unit
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user enable t3code.service"
assert_file_contains "$STUB_LOG" "systemctl --user start t3code.service"
assert_contains "$RUN_OUTPUT" "Enabled the T3 Code service"
assert_contains "$RUN_OUTPUT" "Started the T3 Code service"
assert_file_not_contains "$STUB_LOG" "reset-failed"

# systemd refuses a start for 5 minutes after the start limit, so reset it first
reset
installed_unit
touch "$STATE/enabled" "$STATE/start-limit-hit"
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user reset-failed t3code.service"
assert_contains "$RUN_OUTPUT" "Started the T3 Code service"
[ -f "$STATE/active" ] || fail "the service wasn't started after hitting its start limit"

reset
installed_unit
touch "$STATE/active" "$STATE/enabled"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "already installed and running"
for action in enable start stop restart daemon-reload; do
    assert_file_not_contains "$STUB_LOG" "systemctl --user $action"
done

# A launcher that runs no server is restarted without asking
reset
installed_unit
touch "$STATE/active" "$STATE/enabled" "$STATE/idle"
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service running a server: it runs none"
assert_not_contains "$RUN_OUTPUT" "ok         T3 Code service running"
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user restart t3code.service"
assert_contains "$RUN_OUTPUT" "Restarted the T3 Code service, which ran no server"
[ ! -e "$STATE/idle" ] || fail "the idle service wasn't restarted"
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code service running"
assert_not_contains "$RUN_OUTPUT" "running a server"

# A launcher briefly without a server, as during an update, isn't restarted
reset
installed_unit
touch "$STATE/active" "$STATE/enabled" "$STATE/idle"
stub sleep '[ "$1" != 1 ] || rm -f "$(dirname "$STUB_LOG")/state/idle"'
assert_exit 0 configure_t3_code_ubuntu
assert_file_not_contains "$STUB_LOG" "systemctl --user restart"
stub sleep

reset
installed_unit
touch "$STATE/active" "$STATE/enabled" "$STATE/always-idle"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "The T3 Code service runs no server. Check ~/.t3/userdata/logs/boot-service.log"

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

# Linger off with a unit: repair the service, don't fail
reset
installed_unit
replace_fn t3_code_lingering 'false'
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Linger is off"
assert_file_contains "$STUB_LOG" "systemctl --user start t3code.service"
replace_fn t3_code_lingering 'true'

# Linger off with no unit: don't install, since it would start only at login
reset
replace_fn t3_code_lingering 'false'
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Linger is off"
assert_contains "$RUN_OUTPUT" "bash setup.sh ubuntu"
assert_file_not_contains "$STUB_LOG" "t3 service install"
run status
assert_contains "$RUN_OUTPUT" 'missing    T3 Code service: turn on linger: `bash setup.sh ubuntu`'
replace_fn t3_code_lingering 'true'

reset
installed_unit
touch "$STATE/active"
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service enabled at boot"
touch "$STATE/enabled"
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code service enabled at boot"

reset
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service: re-run the t3-code step (bash ai_tools/setup.sh t3-code), which runs t3 service install"
assert_not_contains "$RUN_OUTPUT" "inger"

reset
installed_unit
touch "$STATE/active" "$STATE/enabled"
stub id "case \"\$*\" in -nG*) echo 'me adm docker' ;; -u) echo 1000 ;; *) echo me ;; esac"
stub getent '[ "$*" != "group docker" ] || echo "docker:x:998:me"'
replace_fn t3_code_process_groups 'echo "4 24 27"'
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "still has the groups it had before you joined the docker group"
assert_contains "$RUN_OUTPUT" "sudo systemctl restart user@1000"
replace_fn t3_code_process_groups 'echo "4 24 27 998"'
assert_exit 0 configure_t3_code_ubuntu
assert_not_contains "$RUN_OUTPUT" "docker group"
rm -f "$STUB_DIR/id" "$STUB_DIR/getent"

reset
installed_unit
echo '{}' > "$T3_CODE_SETTINGS"
touch "$STATE/active" "$STATE/enabled"
answer yes
stub systemctl "[ \"\$2\" != stop ] || exit 1
$SYSTEMCTL_STUB"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Couldn't stop the T3 Code service"
assert_eq '{}' "$(cat "$T3_CODE_SETTINGS")" "settings after a failed stop"
assert_not_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
stub systemctl "[ \"\$2\" != start ] || exit 1
$SYSTEMCTL_STUB"
assert_exit 1 configure_t3_code_ubuntu
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"
assert_not_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
assert_contains "$RUN_OUTPUT" "Check ~/.t3/userdata/logs/boot-service.log"
stub systemctl "$SYSTEMCTL_STUB"
echo '{}' > "$T3_CODE_SETTINGS"
touch "$STATE/active"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
assert_eq 1 "$(grep -c 'Restart the T3 Code service' <<< "$RUN_OUTPUT")" "restart questions"
assert_file_contains "$STUB_LOG" "systemctl --user stop t3code.service"
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"
answer no

# Declined: the drop-in is still written and loaded for the next restart; settings stay
reset
installed_unit
different_drop_in
echo '{}' > "$T3_CODE_SETTINGS"
touch "$STATE/old-env" "$STATE/active" "$STATE/enabled"
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_eq 1 "$(grep -c 'Restart the T3 Code service' <<< "$RUN_OUTPUT")" "restart questions"
assert_contains "$RUN_OUTPUT" "Wrote the drop-in; it applies at the next restart of the T3 Code service"
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running, without its new settings and its drop-in."
t3_code_drop_in_current || fail "the drop-in wasn't written after a declined restart"
assert_eq "systemctl --user daemon-reload" "$(grep -E 'systemctl --user (stop|start|restart|daemon-reload)' "$STUB_LOG")" "systemctl after a declined restart"
assert_eq '{}' "$(cat "$T3_CODE_SETTINGS")" "settings after a declined restart"
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_eq 1 "$(grep -c 'Restart the T3 Code service' <<< "$RUN_OUTPUT")" "restart questions on the next run"
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running, without its new settings and its drop-in."
assert_not_contains "$RUN_OUTPUT" "Wrote the drop-in"
assert_file_not_contains "$STUB_LOG" "systemctl --user daemon-reload"
run status
assert_contains "$RUN_OUTPUT" "ok         Telemetry off, port 3773, and host 127.0.0.1 in the service drop-in"
assert_contains "$RUN_OUTPUT" "missing    T3 Code service restarted for its drop-in: systemctl --user restart t3code"
answer yes
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_eq "systemctl --user stop t3code.service
systemctl --user start t3code.service" "$(grep -E 'systemctl --user (stop|start|restart|daemon-reload)' "$STUB_LOG")" "the restart"
t3_code_drop_in_current || fail "the drop-in wasn't written"
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"
answer no
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "already set"
assert_file_not_contains "$STUB_LOG" "systemctl --user stop"
run status
assert_not_contains "$RUN_OUTPUT" "restarted for its drop-in"

reset
installed_unit
different_drop_in
touch "$STATE/old-env" "$STATE/active" "$STATE/enabled"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Wrote the drop-in; it applies at the next restart of the T3 Code service"
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running, without its drop-in. Re-run from a terminal"
t3_code_drop_in_current || fail "the drop-in wasn't written after a declined restart"
different_drop_in
stub systemctl '[ "$2" != daemon-reload ] || exit 1
'"$SYSTEMCTL_STUB"
: > "$STUB_LOG"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Couldn't write and load $T3_CODE_SERVICE_DROP_IN"
assert_contains "$RUN_OUTPUT" "install, enable, or start it."
assert_not_contains "$RUN_OUTPUT" "Left the T3 Code service running"
assert_eq "systemctl --user daemon-reload" "$(grep -E 'systemctl --user (stop|start|restart|enable|daemon-reload)' "$STUB_LOG")" "systemctl after a declined restart with a failed reload"
[ -f "$STATE/active" ] || fail "the running service was stopped"
stub systemctl "$SYSTEMCTL_STUB"

reset
installed_unit
touch "$STATE/active" "$STATE/enabled" "$STATE/old-env"
assert_exit 0 t3_code_restart_pending
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running, without its drop-in."
assert_not_contains "$RUN_OUTPUT" "Wrote the drop-in"

answer yes
stub systemctl '[ "$2" != start ] || exit 1
'"$SYSTEMCTL_STUB"
# As main runs it, under || where set -e is off
conditional_configure() { configure_t3_code_ubuntu || return 1; }
assert_exit 1 conditional_configure
assert_not_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
stub systemctl "$SYSTEMCTL_STUB"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Started the T3 Code service"
assert_exit 1 t3_code_restart_pending

different_drop_in
touch "$STATE/reload-needed" "$STATE/old-env"
stub systemctl '[ "$2" != daemon-reload ] || exit 1
'"$SYSTEMCTL_STUB"
assert_exit 1 conditional_configure
stub systemctl "$SYSTEMCTL_STUB"
: > "$STUB_LOG"
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" 'systemctl --user daemon-reload'
assert_exit 1 t3_code_restart_pending
answer no

# The start limit and oomd preference are left to T3's unit.
reset
assert_exit 0 configure_t3_code_ubuntu
assert_eq "[Service]
Environment=T3CODE_TELEMETRY_ENABLED=false
Environment=T3CODE_PORT=3773
Environment=T3CODE_HOST=127.0.0.1" "$(cat "$T3_CODE_SERVICE_DROP_IN")" "the drop-in"
run status
assert_contains "$RUN_OUTPUT" "ok         Telemetry off, port 3773, and host 127.0.0.1 in the service drop-in"
installed_unit
rm "$STATE/loaded-drop-in"
touch "$STATE/active" "$STATE/enabled"
assert_exit 1 t3_code_drop_in_loaded
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user daemon-reload"
assert_exit 1 t3_code_restart_pending
touch "$STATE/old-env-host"
assert_exit 0 t3_code_restart_pending
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service restarted for its drop-in"
answer yes
assert_exit 0 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "systemctl --user stop t3code.service"
assert_file_contains "$STUB_LOG" "systemctl --user start t3code.service"
assert_exit 1 t3_code_restart_pending
answer no

# Every listener on the port must be loopback; other ports don't count, and an ss failure is unknown
reset
installed_unit
touch "$STATE/active" "$STATE/enabled"
printf '%s\n' "LISTEN 0 511 [::1]:3773 [::]:*" "LISTEN 0 511 127.0.0.1%lo:3773 0.0.0.0:*" \
    "LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*" "LISTEN 0 511 *:37730 *:*" > "$STATE/listeners"
run status
assert_contains "$RUN_OUTPUT" "ok         Port 3773 open only on loopback"
assert_exit 0 configure_t3_code_ubuntu
printf '%s\n' "LISTEN 0 511 0.0.0.0:3773 0.0.0.0:*" "LISTEN 0 511 [::]:3773 [::]:*" >> "$STATE/listeners"
run status
assert_eq 3 "$RUN_STATUS" "status's exit with the port open beyond loopback"
assert_contains "$RUN_OUTPUT" "missing    Port 3773 open only on loopback: also on 0.0.0.0:3773, [::]:3773, which the tailnet can reach"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Port 3773 is open beyond loopback, where the tailnet can reach it: 0.0.0.0:3773, [::]:3773."
[ -f "$STATE/active" ] || fail "the step stopped the service"
stub ss 'exit 1'
run status
assert_contains "$RUN_OUTPUT" "unknown    Port 3773 open only on loopback: ss couldn't list the listeners"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "ss couldn't list the listeners on port 3773"
rm "$STATE/listeners"
stub ss '[ ! -f "$(dirname "$STUB_LOG")/state/active" ] || echo "LISTEN 0 511 127.0.0.1:3773 0.0.0.0:*"'

replace_fn t3_code_lingering 'false'
run status
assert_contains "$RUN_OUTPUT" 'missing    Linger enabled for T3 Code to start without login'
replace_fn t3_code_lingering 'true'

reset
run main
assert_eq 0 "$RUN_STATUS" "main's exit status"
assert_file_contains "$STUB_LOG" "t3 service install"
assert_contains "$RUN_OUTPUT" "No GNOME desktop, so no desktop app; the service runs the server."
[ ! -e "$HOME/.profile" ] || assert_file_not_contains "$HOME/.profile" "T3CODE_TELEMETRY_ENABLED"

reset
mkdir -p "$(dirname "$T3_CODE_SETTINGS")"
echo "not json" > "$T3_CODE_SETTINGS"
assert_exit 1 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "t3 service install"
assert_file_contains "$STUB_LOG" "t3 browser setup"

# Without the drop-in the service would serve on every interface, so none is installed
reset
mkdir -p "$(dirname "$T3_CODE_SERVICE_UNIT")"
touch "$T3_CODE_SERVICE_UNIT.d"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Without its drop-in, the service would serve on every interface, so setup doesn't"
assert_file_not_contains "$STUB_LOG" "t3 service install"
assert_file_contains "$STUB_LOG" "t3 browser setup"
reset
installed_unit
different_drop_in
touch "$STATE/active" "$STATE/enabled"
stub systemctl '[ "$2" != daemon-reload ] || exit 1
'"$SYSTEMCTL_STUB"
answer yes
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Left the T3 Code service stopped, since it would start without its drop-in"
assert_file_not_contains "$STUB_LOG" "systemctl --user start"
answer no
stub systemctl "$SYSTEMCTL_STUB"
# A cut-short write must leave the old drop-in whole
reset
installed_unit
different_drop_in
printf() {
    if [ "${2:-}" = "$T3_CODE_SERVICE_DROP_IN_CONTENT" ]; then
        builtin printf '%s\n' "${2%%$'\n'*}"
        return 1
    fi
    # shellcheck disable=SC2059 # pass the caller's format through
    builtin printf "$@"
}
assert_exit 1 configure_t3_code_ubuntu
unset -f printf
assert_eq "# different" "$(cat "$T3_CODE_SERVICE_DROP_IN")" "the drop-in after a failed write"

cat > "$HOME/.local/bin/t3" << 'EOF'
#!/bin/bash
case "$(cat "$(dirname "$STUB_LOG")/state/browser-mode")" in
    failed) echo 'Browser setup failed'; exit 1 ;;
    needs-root) echo 'AppArmor profile needs root' ;;
esac
EOF
echo failed > "$STATE/browser-mode"
assert_exit 2 t3_code_browser_ready
assert_exit 1 setup_t3_code_browser
run status
assert_contains "$RUN_OUTPUT" "unknown    T3 Code's browser sandbox: t3 browser setup failed"
echo needs-root > "$STATE/browser-mode"
assert_exit 1 t3_code_browser_ready
# ~/.local/bin/t3 is the user's and updates itself, so it never runs under sudo
stub_sudo_exec
answer yes
: > "$STUB_LOG"
assert_exit 0 setup_t3_code_browser
assert_contains "$RUN_OUTPUT" 'sudo ~/.local/bin/t3 browser setup'
assert_file_not_contains "$STUB_LOG" 'sudo'
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code's browser can run in Chrome's sandbox: run sudo ~/.local/bin/t3 browser setup"
stub sudo 'exit 1'
answer no
echo ready > "$STATE/browser-mode"
assert_exit 0 t3_code_browser_ready

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
echo "not json" > "$STATE/connect"
run status
assert_contains "$RUN_OUTPUT" "unknown    T3 Connect: t3 connect status didn't say; run it to see why"
mv "$HOME/.local/bin/t3" "$SANDBOX/t3"
run status
assert_contains "$RUN_OUTPUT" "unknown    T3 Connect: needs the t3 CLI"
mv "$SANDBOX/t3" "$HOME/.local/bin/t3"

# Only declining the sudo for libatomic1 doesn't fail the step.
reset
rm -f "$HOME/.local/bin/t3"
replace_fn apt_installed '[ "$1" != libatomic1 ] || [ -e "$STATE/libatomic1" ]'
replace_fn run_installer '
echo "run_installer $*" >> "$STUB_LOG"
return "$(cat "$STATE/installer-status")"'
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
# Stale apt lists can 404, so they're updated first
answer yes
stub sudo
echo 0 > "$STATE/installer-status"
: > "$STUB_LOG"
assert_exit 1 install_t3_cli
assert_eq "update
install -y libatomic1" "$(sed -n 's/^sudo .* apt-get -o [^ ]* //p' "$STUB_LOG")" "apt-get's commands"
assert_file_contains "$STUB_LOG" "run_installer sh https://t3.codes/install.sh"
stub sudo 'exit 1'
test_done
