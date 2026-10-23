#!/bin/bash
# shellcheck disable=SC2329

# The t3-code step on Ubuntu: the t3 CLI, the server settings, and the t3code.service user service
# with its drop-in, which other servers on its data, the desktop app, and its listeners hold back.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script ai_tools/t3-code/install.sh
as_os ubuntu
# Ubuntu Server, with no desktop app; the desktop cases turn GNOME on, and
# test-t3-desktop-ubuntu.sh covers the app's own setup
replace_fn has_gnome_desktop 'false'
answer no
# No docker group, so the service's groups aren't checked
stub getent 'exit 2'

MANUAL_SERVER="304|t3|t3 serve"
MANUAL_MESSAGE="PID 304, a t3 serve started by hand"

# start-limit-hit refuses a start until reset-failed; idle (no server) clears on a start.
STATE="$SANDBOX/state"
mkdir -p "$STATE"
SYSTEMCTL_STUB='
state="$SANDBOX/state"
case "$2" in
    is-active) [ -f "$state/active" ] ;;
    is-enabled) [ -f "$state/enabled" ] ;;
    is-failed) [ -e "$state/start-limit-hit" ] ;;
    start | restart)
        [ ! -e "$state/start-limit-hit" ] || exit 1
        touch "$state/active"
        rm -f "$state/stale-env" "$state/stale-env-host" "$state/idle"
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
procs="$SANDBOX/procs"
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
# The service's main process has run 100 s, or 1 s with $STATE/young
stub ps 'if [ -e "$SANDBOX/state/young" ]; then echo "      1"; else echo "    100"; fi'
stub ss '
state="$SANDBOX/state"
[ ! -f "$state/active" ] || echo "LISTEN 0      511        127.0.0.1:3773      0.0.0.0:*"
[ ! -f "$state/listeners" ] || cat "$state/listeners"'
# A t3 CLI in ~/.local/bin, where the t3 installer puts it
stub_at "$HOME/.local/bin/t3" 'if [ "$*" == "service install" ]; then
    state="$SANDBOX/state"
    mkdir -p "$HOME/.config/systemd/user"
    touch "$HOME/.config/systemd/user/t3code.service" "$state/active" "$state/enabled"
fi'

replace_fn t3_code_in_service_cgroup 'false'
replace_fn t3_code_lingering 'true'
# always-idle survives a start.
replace_fn t3_code_launcher_has_server '[ ! -e "$STATE/idle" ] && [ ! -e "$STATE/always-idle" ]'
# The running server lacks the drop-in's environment: stale-env all of it, stale-env-host its host.
replace_fn t3_code_process_environ '
if [ -e "$STATE/stale-env" ]; then
    echo T3CODE_TELEMETRY_ENABLED=true
    return
fi
echo T3CODE_TELEMETRY_ENABLED=false
echo T3CODE_PORT=3773
[ -e "$STATE/stale-env-host" ] || echo T3CODE_HOST=127.0.0.1'

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
    cp "$REPO_DIR/ai_tools/t3-code/dotfiles.conf" "$T3_CODE_SERVICE_DROP_IN"
    cp "$T3_CODE_SERVICE_DROP_IN" "$STATE/loaded-drop-in"
    json_merge "$T3_CODE_SETTINGS" "$(t3_code_server_filter)" > /dev/null
    : > "$STUB_LOG"
}

running_service() {
    touch "$STATE/active" "$STATE/enabled"
}

# systemctl's <verb> fails; `stub systemctl "$SYSTEMCTL_STUB"` puts it back
systemctl_fails() {
    stub systemctl "[ \"\$2\" != $1 ] || exit 1
$SYSTEMCTL_STUB"
}

# A t3 serve started by hand: nothing changes or starts
reset
installed_unit
echo "$MANUAL_SERVER" > "$SANDBOX/procs"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Another T3 Code server is running, so skipping the server settings and the service"
assert_contains "$RUN_OUTPUT" "$MANUAL_MESSAGE"
assert_file_not_contains "$STUB_LOG" "systemctl --user start"

# A drop-in change waits while another server runs
reset
installed_unit
different_drop_in
touch "$STATE/stale-env"
running_service
echo "$MANUAL_SERVER" > "$SANDBOX/procs"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "$MANUAL_MESSAGE"
t3_code_drop_in_current && fail "the drop-in was written while another server ran"
assert_file_not_contains "$STUB_LOG" "systemctl --user daemon-reload"

reset
installed_unit
running_service
printf '%s\n' "302|t3|$HOME/.t3/runtime/versions/0.0.45/t3 serve --host 127.0.0.1 --port 3774 --base-dir $HOME/.t3" \
    "304|t3|$HOME/.local/bin/t3 serve --port 3780" \
    "305|t3|$HOME/.t3/runtime/versions/0.0.45/t3 serve" \
    "306|vim|vim notes.txt" \
    "307|python3|python3 manage.py serve --port 8000" > "$SANDBOX/procs"
replace_fn t3_code_in_service_cgroup '[ "$1" == 305 ]'
assert_eq "302 ssh
304 manual" "$(t3_code_other_servers | cut -d' ' -f1-2)" "the other servers"
run main --status
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
running_service
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "already installed and running"
for action in enable start stop restart daemon-reload; do
    assert_file_not_contains "$STUB_LOG" "systemctl --user $action"
done

# A launcher that runs no server is restarted without asking
reset
installed_unit
running_service
touch "$STATE/idle"
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
running_service
# The first check finds no server, the next finds one
replace_fn t3_code_launcher_has_server '[ ! -e "$STATE/idle" ] || { rm "$STATE/idle"; return 1; }'
touch "$STATE/idle"
assert_exit 0 configure_t3_code_ubuntu
assert_file_not_contains "$STUB_LOG" "systemctl --user restart"
replace_fn t3_code_launcher_has_server '[ ! -e "$STATE/idle" ] && [ ! -e "$STATE/always-idle" ]'

reset
installed_unit
running_service
touch "$STATE/always-idle"
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "The T3 Code service runs no server. Check ~/.t3/userdata/logs/boot-service.log"

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
echo '{}' > "$T3_CODE_SETTINGS"
running_service
answer yes
systemctl_fails stop
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Couldn't stop the T3 Code service"
assert_eq '{}' "$(cat "$T3_CODE_SETTINGS")" "settings after a failed stop"
assert_not_contains "$RUN_OUTPUT" "Restarted the T3 Code service"
systemctl_fails start
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
touch "$STATE/stale-env"
running_service
assert_exit 0 configure_t3_code_ubuntu
assert_eq 1 "$(grep -c 'Restart the T3 Code service' <<< "$RUN_OUTPUT")" "restart questions"
assert_contains "$RUN_OUTPUT" "Wrote the drop-in; it applies at the next restart of the T3 Code service"
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running, without its new settings and its drop-in."
t3_code_drop_in_current || fail "the drop-in wasn't written after a declined restart"
assert_eq "systemctl --user daemon-reload" "$(grep -E 'systemctl --user (stop|start|restart|daemon-reload)' "$STUB_LOG")" "systemctl after a declined restart"
assert_eq '{}' "$(cat "$T3_CODE_SETTINGS")" "settings after a declined restart"
assert_exit 0 configure_t3_code_ubuntu
assert_eq 1 "$(grep -c 'Restart the T3 Code service' <<< "$RUN_OUTPUT")" "restart questions on the next run"
assert_contains "$RUN_OUTPUT" "Left the T3 Code service running, without its new settings and its drop-in."
assert_not_contains "$RUN_OUTPUT" "Wrote the drop-in"
assert_file_not_contains "$STUB_LOG" "systemctl --user daemon-reload"
run status
assert_contains "$RUN_OUTPUT" "ok         Telemetry off, port 3773, and host 127.0.0.1 in the service drop-in"
assert_contains "$RUN_OUTPUT" "missing    T3 Code service restarted for its drop-in: systemctl --user restart t3code"
answer yes
assert_exit 0 configure_t3_code_ubuntu
assert_eq "systemctl --user stop t3code.service
systemctl --user start t3code.service" "$(grep -E 'systemctl --user (stop|start|restart|daemon-reload)' "$STUB_LOG")" "the restart"
t3_code_drop_in_current || fail "the drop-in wasn't written"
assert_file_contains "$T3_CODE_SETTINGS" "claude-opus-5-5"
answer no
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "already set"
assert_file_not_contains "$STUB_LOG" "systemctl --user stop"
run status
assert_not_contains "$RUN_OUTPUT" "restarted for its drop-in"

# Every listener on the port must be loopback, and an ss failure is unknown
reset
installed_unit
running_service
printf '%s\n' "LISTEN 0 511 [::1]:3773 [::]:*" "LISTEN 0 511 127.0.0.1%lo:3773 0.0.0.0:*" > "$STATE/listeners"
run status
assert_contains "$RUN_OUTPUT" "ok         Port 3773 open only on loopback"
assert_file_contains "$STUB_LOG" "ss -Hltn sport = :3773"
printf '%s\n' "LISTEN 0 511 0.0.0.0:3773 0.0.0.0:*" "LISTEN 0 511 [::]:3773 [::]:*" >> "$STATE/listeners"
run main --status
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
stub ss '[ ! -f "$SANDBOX/state/active" ] || echo "LISTEN 0 511 127.0.0.1:3773 0.0.0.0:*"'

# On Ubuntu Desktop, the app's own server runs its Electron binary on app.asar's server entry. While
# it may hold the data, a full apply leaves the server settings and the service pending.
desktop_app() {
    local backend="/opt/T3 Code (Beta)/t3code --require /opt/T3 Code (Beta)/resources/app.asar/apps/desktop/dist-electron/compileCache.cjs /opt/T3 Code (Beta)/resources/app.asar/apps/server/dist/bin.mjs --bootstrap-fd 3"
    replace_fn has_gnome_desktop 'true'
    replace_fn t3_code_desktop_installed 'true'
    replace_fn running_inside 'false'

    printf '%s\n' "400|t3code|/opt/T3 Code (Beta)/t3code" "401|t3code|$backend" > "$SANDBOX/procs"
    assert_eq "401 desktop" "$(t3_code_other_servers | cut -d' ' -f1-2)" "the desktop app's server"

    # Its server may not have started yet
    echo "400|t3code|/opt/T3 Code (Beta)/t3code" > "$SANDBOX/procs"
    run apply
    assert_eq 0 "$RUN_STATUS" "apply while the desktop app runs without its settings"
    [ ! -e "$T3_CODE_SETTINGS" ] || fail "server settings were written while the desktop app ran"
    assert_file_not_contains "$STUB_LOG" "t3 service install"
    assert_file_not_contains "$STUB_LOG" "systemctl --user start"
    run main --status
    assert_eq 3 "$RUN_STATUS" "status while the server settings are pending"
    assert_contains "$RUN_OUTPUT" "missing    T3 Code server settings and service: pending while the desktop app runs with its own server on; quit T3 Code"
    rm -rf "$SANDBOX/procs" "$HOME/.t3/userdata" "$HOME/.config/environment.d"
}
reset
subtest desktop_app

# The desktop app isn't installed: one sudo question covers it and libatomic1 for the t3 CLI, and
# it's installed only once its settings are set, so it starts no server on the service's data
desktop_install() {
    replace_fn has_gnome_desktop 'true'
    replace_fn running_inside 'false'
    replace_fn t3_code_desktop_installed '[ -e "$STATE/desktop" ]'
    replace_fn install_t3_code_desktop 'echo "install the desktop app" >> "$STUB_LOG"; touch "$STATE/desktop"'
    replace_fn apt_installed '[ "$1" != libatomic1 ] || [ -e "$STATE/libatomic1" ]'
    replace_fn install_t3_code_libatomic 'echo "install libatomic1" >> "$STUB_LOG"; touch "$STATE/libatomic1"'
    replace_fn run_installer 'echo "run_installer $*" >> "$STUB_LOG"'
    mv "$HOME/.local/bin/t3" "$SANDBOX/t3"
    answer yes

    run apply
    assert_eq 1 "$(grep -c 'These need sudo' <<< "$RUN_OUTPUT")" "sudo questions for the app and libatomic1"
    assert_file_contains "$STUB_LOG" "install the desktop app"
    assert_file_contains "$STUB_LOG" "install libatomic1"

    rm -f "$STATE/desktop"
    : > "$STUB_LOG"
    echo "not json" > "$T3_CODE_DESKTOP_SETTINGS"
    assert_exit 1 setup_t3_code_desktop_ubuntu
    assert_file_not_contains "$STUB_LOG" "install the desktop app"

    # With t3, the .deb is still a download, so a missing curl fails before any change
    mv "$SANDBOX/t3" "$HOME/.local/bin/t3"
    rm -rf "$HOME/.t3/userdata" "$HOME/.config/environment.d"
    hide curl
    assert_exit 1 apply
    [ ! -e "$HOME/.t3/userdata" ] || fail "settings were written with no curl for the app's download"
    [ ! -e "$HOME/.config/environment.d" ] || fail "files were copied with no curl for the app's download"
}
reset
subtest desktop_install

reset
run main
assert_eq 0 "$RUN_STATUS" "main's exit status"
assert_file_contains "$STUB_LOG" "t3 service install"

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
running_service
systemctl_fails daemon-reload
answer yes
assert_exit 1 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Couldn't write and load $T3_CODE_SERVICE_DROP_IN"
assert_file_not_contains "$STUB_LOG" "systemctl --user stop"
[ -f "$STATE/active" ] || fail "the service was stopped though its drop-in couldn't load"
answer no
stub systemctl "$SYSTEMCTL_STUB"

# A main process under 2 s old may be crash-looping. --for-alerts skips that check and t3 browser setup,
# but still finds the service stopped. No drop-in, so only the service's own checks query systemd.
reset
mkdir -p "$(dirname "$T3_CODE_SERVICE_UNIT")"
touch "$T3_CODE_SERVICE_UNIT"
running_service
run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code service running"
assert_file_contains "$STUB_LOG" "ps -o etimes= -p 4242"
assert_file_contains "$STUB_LOG" "t3 browser setup"
touch "$STATE/young"
run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service running; check ~/.t3/userdata/logs/boot-service.log"
DOTFILES_STATUS_FOR_ALERTS=1 run status
assert_contains "$RUN_OUTPUT" "ok         T3 Code service running"
assert_file_not_contains "$STUB_LOG" "ps -o etimes"
assert_file_not_contains "$STUB_LOG" "t3 browser setup"
assert_contains "$RUN_OUTPUT" "unverified T3 Code's browser sandbox: skipped by --for-alerts"
rm "$STATE/active"
DOTFILES_STATUS_FOR_ALERTS=1 run status
assert_contains "$RUN_OUTPUT" "missing    T3 Code service running"

# Only declining the sudo for libatomic1 doesn't fail the step.
reset
rm -f "$HOME/.local/bin/t3"
replace_fn apt_installed '[ "$1" != libatomic1 ] || [ -e "$STATE/libatomic1" ]'
replace_fn run_installer 'echo "run_installer $*" >> "$STUB_LOG"'
touch "$STATE/libatomic1"
assert_exit 1 configure_t3_code_ubuntu
assert_file_contains "$STUB_LOG" "run_installer sh https://t3.codes/install.sh"
assert_file_not_contains "$STUB_LOG" "t3 service install"
assert_contains "$RUN_OUTPUT" "Without the t3 CLI there's no service to install"
assert_contains "$RUN_OUTPUT" "The t3 installer finished, but $HOME/.local/bin/t3 isn't there"
rm "$STATE/libatomic1"
assert_exit 0 configure_t3_code_ubuntu
assert_contains "$RUN_OUTPUT" "Install libatomic1"
assert_file_not_contains "$STUB_LOG" "run_installer"
test_done
