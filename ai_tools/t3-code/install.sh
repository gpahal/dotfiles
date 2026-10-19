#!/bin/bash
set -euo pipefail

# Install T3 Code and set its settings, and on Ubuntu run its server as a service.
#
# On Ubuntu, the server runs as a systemd user service, which starts at boot (with linger, from the
# ubuntu step) and which the Mac reaches over Tailscale HTTPS. When its browser needs root to run in
# Chrome's sandbox, the step prints the command for you to run, since it never runs the
# user-writable t3 under sudo.
#
# A temp HOME doesn't isolate this step. On macOS it installs its cask and runs launchctl. On
# Ubuntu it installs libatomic1 and runs systemctl --user. Test the cask in a macOS VM or on a spare
# Mac, and the Ubuntu side in an Ubuntu VM that runs systemd, such as an OrbStack machine.
#
# T3 has no read-only check for its browser's setup, so on Ubuntu --status runs `t3 browser setup`
# without sudo, relying on it changing nothing then and saying "needs root" when there's something
# to do (as of T3 Code 0.1.0). Recheck that when T3 updates. --status --quick skips it.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=../../lib/casks.sh
source "$DOTFILES_DIR/lib/casks.sh"
# shellcheck source=../lib/app-json.sh
source "$DOTFILES_DIR/ai_tools/lib/app-json.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

T3_CODE_SETTINGS="$HOME/.t3/userdata/settings.json"
T3_CODE_CLIENT_SETTINGS="$HOME/.t3/userdata/client-settings.json"
# T3 Code reads T3CODE_TELEMETRY_ENABLED only from its environment, and an app opened from the Dock
# or Finder gets launchd's, not the shell's. At each login this LaunchAgent sets the variable in
# launchd's environment, then opens T3 Code: one agent does both, so it can't open T3 Code before
# the variable is set. macOS's "Reopen windows when logging back in" can still start T3 Code
# first, and open then only brings that copy forward, so the README says to quit and reopen it
# then. It opens T3 Code because T3 Connect, which the phone app goes through, runs only while
# the app is open. The app also reads the variable from the login shell, but gives that read 5 s,
# so a slow shell would leave telemetry on without launchd's copy. The app's name carries its release stage, so the agent opens it by bundle ID.
T3_CODE_TELEMETRY_AGENT="$HOME/Library/LaunchAgents/dotfiles.t3code-telemetry-off.plist"

# The LaunchAgent isn't loaded now, since it would open T3 Code, which must be quit for the
# settings below. launchd loads it at the next login.
t3_code_files() {
    "$1" "$DOTFILES_DIR/ai_tools/t3-code/dotfiles.t3code-telemetry-off.plist" "$T3_CODE_TELEMETRY_AGENT"
}
# Where `t3 service install` writes the unit, whatever XDG_CONFIG_HOME is. The systemd user manager
# doesn't see an XDG_CONFIG_HOME set in the shell either, so the drop-in goes beside the unit.
T3_CODE_SERVICE_UNIT="$HOME/.config/systemd/user/t3code.service"
# A drop-in, since `t3 service install` and `t3 update` rewrite the unit itself. It pins the port:
# without one, `t3 serve` falls back to a free port when 3773 is taken, and T3 has no lock against
# a second server on the same data, while `tailscale serve` and pairing links point at 3773. Pinned,
# the service fails its bind instead, and T3's unit (StartLimitIntervalSec=300,
# StartLimitBurst=5, RestartSec=5) stops retrying after about 25 s, while status
# names the other server. It binds the server to loopback, since `t3 serve` otherwise listens on
# every interface and ufw lets the tailnet reach every port: `tailscale serve` is the way in, over
# HTTPS. It leaves systemd-oomd's preference to T3, since sparing the server would spare a runaway
# agent in its cgroup too, while Restart= brings the server back.
T3_CODE_SERVICE_DROP_IN="$T3_CODE_SERVICE_UNIT.d/dotfiles.conf"
T3_CODE_PORT=3773
T3_CODE_HOST=127.0.0.1
T3_CODE_SERVICE_DROP_IN_CONTENT="[Service]
Environment=T3CODE_TELEMETRY_ENABLED=false
Environment=T3CODE_PORT=$T3_CODE_PORT
Environment=T3CODE_HOST=$T3_CODE_HOST"

# The default model and its effort, values you can change (replace_custom_value).
# t3_code_choose_custom_values sets T3_CODE_REPLACE_MODEL and T3_CODE_REPLACE_EFFORT to whether to
# write each over yours, which t3_code_server_filter reads.
T3_CODE_MODEL="claude-opus-5-5"
T3_CODE_MODEL_NAME="T3 Code's default model (defaultModelSelection.model)"
T3_CODE_REPLACE_MODEL=false
T3_CODE_EFFORT="medium"
T3_CODE_EFFORT_NAME="T3 Code's default effort (defaultModelSelection.options effort)"
T3_CODE_REPLACE_EFFORT=false

# What the server settings cover, for the step's messages
T3_CODE_SERVER_SETTINGS_NAME="server settings (model, threads, setup actions, cleanup, merge, writing style)"

# Server settings, used by T3 Code on the Mac and by the server it starts on Ubuntu. Existing
# worktree setup actions wait for completion: T3 has no global async default, so each action list
# gets it.
# A model of your own keeps its instance and options, a custom Claude instance's included, and its
# effort is left to you too. Replacing it switches to Claude's instance, which drops another
# provider's options. Model options are set in place, so any others and their order survive a
# re-run. The global worktreeCleanup holds the worktree rules. Objects are set key by key, never
# replaced whole, so keys a newer T3 Code adds to them survive and a re-run settles. Project
# overrides are left alone, but for their setup actions.
# T3 Code writes only values that differ from a key's default, so a value equal to it never
# settles. Checked against T3 Code 0.1.0; scripts/check-t3-settings.sh checks every key, and warns
# about such values, against the latest release in CI.
# Print the server filter, keeping a model and effort of your own unless T3_CODE_REPLACE_MODEL and
# T3_CODE_REPLACE_EFFORT say to replace them
t3_code_server_filter() {
    # shellcheck disable=SC2016 # jq variables, not shell ones
    printf '%s\n' '
    # Set an option in the list of a model selection, in place
    def set_option($id; $value):
        if any(.[]; .id == $id)
        then map(if .id == $id then .value = $value else . end)
        else . + [{"id": $id, "value": $value}]
        end;
    (
        .defaultProjectScripts[]?,
        .projectSettingsOverrides[]?.defaultProjectScripts[]?
    ) |= if .runOnWorktreeCreate == true then .async = false else . end
    | (.defaultModelSelection.model // "") as $model
    | if $model == "" or ($model != "'"$T3_CODE_MODEL"'" and '"$T3_CODE_REPLACE_MODEL"')
      then
        (if .defaultModelSelection.instanceId != "claudeAgent"
          then .defaultModelSelection.options = []
          else .
          end)
        | .defaultModelSelection.instanceId = "claudeAgent"
        | .defaultModelSelection.model = "'"$T3_CODE_MODEL"'"
      else .
      end
    # The 1M context window goes with the effort set here, so an effort of your own keeps your
    # context window too. A window of your own stays unless this run replaced your model or effort.
    | if .defaultModelSelection.model == "'"$T3_CODE_MODEL"'"
      then .defaultModelSelection.instanceId //= "claudeAgent"
        | .defaultModelSelection.options |= ((. // [])
          | (map(select(.id == "effort") | .value) | . == [] or . == ["'"$T3_CODE_EFFORT"'"])
            as $effort_is_ours
          | if $effort_is_ours or '"$T3_CODE_REPLACE_EFFORT"'
            then set_option("effort"; "'"$T3_CODE_EFFORT"'")
              | if (any(.[]; .id == "contextWindow") | not)
                  or $model != "'"$T3_CODE_MODEL"'"
                  or ($effort_is_ours | not)
                then set_option("contextWindow"; "1m")
                else .
                end
            else .
            end)
      else .
      end
    | .defaultRuntimeMode = "auto"
    | .defaultThreadEnvMode = "worktree"
    | .newWorktreesStartFromOrigin = false
    | .addProjectBaseDirectory = "~/Dev"
    | .branchNamingMode = "semantic"
    | .defaultAutoPull = true
    | .sidebarAutoSettleAfterDays = 10
    | .sidebarAutoSettleKeepPullRequests = true
    | .snoozeLimitedThreads = true
    | .autoResumeLimitedThreads = true
    | .worktreeCleanup.mode = "custom"
    | .worktreeCleanup.rules.worktreeAfterDays = 30
    | .worktreeCleanup.rules.worktreeSettledAfterDays = 15
    | .worktreeCleanup.rules.worktreeOnMerge = true
    | .worktreeCleanup.rules.worktreeOnDelete = true
    | .worktreeCleanup.rules.worktreeUnchanged = true
    | .storageCleanup.browserArtifactsAfterDays = 30
    | .storageCleanup.logsAfterDays = 30
    | .pullRequestMergeMethod = "squash"
    | .removeAgentCreditsOnMerge = true
    | .sourceControlWritingStyle.mode = "custom"
    | .sourceControlWritingStyle.customInstructions = "Keep titles concise. Use short bullet points in the description."
'
}

# Print the default model in the server settings, or nothing when it's unset or the file can't be
# read
t3_code_model() {
    jq -r '.defaultModelSelection.model // empty' "$T3_CODE_SETTINGS" 2>/dev/null || true
}

# Print the default model's effort, the same way. It counts only on the repo's model, whichever
# instance runs it: the server filter drops another provider's options when it replaces a model.
t3_code_effort() {
    jq -r --arg model "$T3_CODE_MODEL" '.defaultModelSelection | select(.model == $model)
        | [.options[]? | select(.id == "effort") | .value][0] // empty' \
        "$T3_CODE_SETTINGS" 2>/dev/null || true
}

# Decide whether to replace a model or effort of your own, asking with a terminal, for
# t3_code_server_filter. A model of your own that stays leaves its effort alone.
t3_code_choose_custom_values() {
    T3_CODE_REPLACE_MODEL=false
    T3_CODE_REPLACE_EFFORT=false
    if replace_custom_value "$T3_CODE_MODEL_NAME" "$(t3_code_model)" "$T3_CODE_MODEL"; then
        T3_CODE_REPLACE_MODEL=true
        if replace_custom_value "$T3_CODE_EFFORT_NAME" "$(t3_code_effort)" "$T3_CODE_EFFORT"; then
            T3_CODE_REPLACE_EFFORT=true
        fi
    fi
}

# Status items naming a model or effort of your own. The effort counts only with the repo's model.
t3_code_status_custom_values() {
    local model effort
    model="$(t3_code_model)"
    [ -n "$model" ] || return 0
    status_custom_value "$T3_CODE_MODEL_NAME" "$model" "$T3_CODE_MODEL"
    [ "$model" == "$T3_CODE_MODEL" ] || return 0
    effort="$(t3_code_effort)"
    [ -z "$effort" ] || status_custom_value "$T3_CODE_EFFORT_NAME" "$effort" "$T3_CODE_EFFORT"
}

# Status items for the server settings, and a model or effort of your own
t3_code_status_server_settings() {
    status_check "Server settings in ~/.t3/userdata/settings.json" json_applied "$T3_CODE_SETTINGS" "$(t3_code_server_filter)"
    t3_code_status_custom_values
}

# Desktop app settings
T3_CODE_CLIENT_FILTER='
    .notificationMode = "notifications-and-sound"
    | .inAppNotificationsEnabled = true
    | .followUpBehavior = "steer"
    | .sidebarWorkingShelfEnabled = true
    | .diffFilesCollapsed = false
    | .wordWrap = false
'

# The app's name can change between releases. Ask brew which app the t3-code cask installs, and
# otherwise take any T3 Code*.app beside where brew puts it, or in /Applications, except the separate nightly build. A caller that already asked brew passes its
# answer, cask_app_path's output, so brew isn't asked again.
# Usage: t3_code_app_path [cask app path]
t3_code_app_path() {
    local app dir=/Applications
    if [ $# -gt 0 ]; then
        app="$1"
    else
        app="$(cask_app_path t3-code)"
    fi
    if [ -n "$app" ] && [ -d "$app" ]; then
        echo "$app"
        return 0
    fi
    [ -z "$app" ] || dir="${app%/*}"
    for app in "$dir/T3 Code"*.app; do
        if [ -d "$app" ] && [[ "$app" != *"(Nightly).app" ]]; then
            echo "$app"
            return 0
        fi
    done
    return 1
}

# Print how the t3-code cask is installed, a tab, and its app's path, as cask_state does, asking
# brew once. "renamed" is a cask brew lists whose app has a name other than the one the cask now
# gives: T3 Code can rename itself in an update, which can get there before the cask does. The app
# is then installed, not gone, and brew's record catches up at the next upgrade-ai-tools once the
# cask does. A renamed app brew doesn't list is "other".
t3_code_cask_state() {
    local state app found
    IFS=$'\t' read -r state app <<< "$(cask_state t3-code)"
    if [ "$state" == gone ] || [ "$state" == missing ]; then
        if found="$(t3_code_app_path "$app")"; then
            app="$found"
            if [ "$state" == gone ]; then state=renamed; else state=other; fi
        fi
    fi
    printf '%s\t%s\n' "$state" "$app"
}

t3_code_macos_items() {
    items_reset
    item "T3 Code's telemetry off in launchd's environment" \
        "Turn off T3 Code's telemetry in launchd's environment" t3_code_telemetry_off turn_off_t3_code_telemetry
}

# Succeeds when launchd's environment has the variable now
t3_code_telemetry_off() {
    [ "$(launchctl getenv T3CODE_TELEMETRY_ENABLED 2>/dev/null)" == false ]
}

# Set the variable in launchd's environment now. When that fails, the LaunchAgent still sets it at
# the next login.
turn_off_t3_code_telemetry() {
    if ! launchctl setenv T3CODE_TELEMETRY_ENABLED false; then
        echo "  Couldn't set T3CODE_TELEMETRY_ENABLED in launchd's environment, so telemetry stays on" >&2
        echo "  until the next login" >&2
        return 1
    fi
    echo "  Turned off telemetry (restart T3 Code if it's running)"
}

# Usage: configure_t3_code [cask app path], as t3_code_app_path takes it
configure_t3_code() {
    echo "Configuring T3 Code..."
    local app_name
    app_name="$(t3_code_app_path "$@" || true)"
    app_name="${app_name##*/}"
    app_name="${app_name%.app}"
    # The settings below apply even when this fails
    local result=0
    echo "  LaunchAgent that opens T3 Code at login with telemetry off:"
    t3_code_files copy_file || result=1
    t3_code_macos_items
    if items_ok t3_code_telemetry_off; then
        echo "  Telemetry is already off in launchd's environment"
    else
        items_apply t3_code_telemetry_off || result=1
    fi

    t3_code_choose_custom_values
    merge_app_json "${app_name:-T3 Code}" \
        "The $T3_CODE_SERVER_SETTINGS_NAME and app settings are already set" \
        "Set the $T3_CODE_SERVER_SETTINGS_NAME and app settings" \
        "$T3_CODE_SETTINGS" "$(t3_code_server_filter)" \
        "$T3_CODE_CLIENT_SETTINGS" "$T3_CODE_CLIENT_FILTER" || return 1
    return "$result"
}

# A T3 Code server started by hand or over SSH. The Mac's SSH connection (as of T3 Code 0.1.0)
# runs ~/.t3/ssh-launch/<key>/run-t3.sh serve, which downloads t3 to ~/.t3/runtime and execs it.
# HOME is escaped, since pgrep and =~ read the patterns as extended regexes.
T3_CODE_HOME_RE="$(regex_escape "$HOME")"
T3_CODE_CLI_SERVER_PATTERN="$T3_CODE_HOME_RE/\.t3/(runtime|ssh-launch)/.* serve( |\$)|(^|/)t3 (serve|start)( |\$)"
T3_CODE_SSH_SERVER_PATTERN="$T3_CODE_HOME_RE/\.t3/(runtime|ssh-launch)/"

# Succeeds when a process is the service's own, in its cgroup. The service's launcher and the
# server it starts share it.
t3_code_in_service_cgroup() {
    grep -q '/t3code\.service$' "/proc/$1/cgroup" 2>/dev/null
}

# Print each T3 Code server running outside the service, one "<pid> <kind> <command line>" per
# line. Any of them shares ~/.t3/userdata's database with the service's server.
# - ssh: one the Mac started over SSH, from a t3 under ~/.t3
# - manual: `t3 serve` or `t3 start` run by hand
t3_code_other_servers() {
    local line pid cmd kind
    while IFS= read -r line; do
        pid="${line%% *}"
        cmd="${line#* }"
        if [ -z "$pid" ] || t3_code_in_service_cgroup "$pid"; then
            continue
        fi
        kind=manual
        [[ "$cmd" =~ $T3_CODE_SSH_SERVER_PATTERN ]] && kind=ssh
        echo "$pid $kind $cmd"
    done < <(pgrep -a -u "$(id -u)" -f "$T3_CODE_CLI_SERVER_PATTERN" || true)
}

# Print what a server from t3_code_other_servers is, from its line there, and how to stop it
t3_code_describe_server() {
    local pid kind cmd name fix
    pid="${1%% *}"
    kind="${1#* }"
    cmd="${kind#* }"
    kind="${kind%% *}"
    case "$kind" in
        ssh)
            name="a server the Mac started over SSH"
            fix="remove this host's SSH connection in T3 Code on the Mac, connect over Tailscale instead (see ai_tools/README.md → Manual steps), stop the server (kill $pid), then re-run the t3-code step"
            ;;
        *)
            name="a t3 serve started by hand"
            fix="stop it (kill $pid), then re-run the t3-code step"
            ;;
    esac
    echo "PID $pid, $name ($cmd); to fix it, $fix"
}

# Linger starts user services at boot, without a login. The ubuntu step turns it on.
t3_code_lingering() {
    [ -e "/var/lib/systemd/linger/$(id -un)" ]
}

t3_code_service_enabled() {
    systemctl --user is-enabled --quiet t3code.service 2>/dev/null
}

t3_code_service_active() {
    systemctl --user is-active --quiet t3code.service 2>/dev/null
}

# The service's log, which T3's unit writes
# shellcheck disable=SC2088 # shown, not expanded
T3_CODE_SERVICE_LOG="~/.t3/userdata/logs/boot-service.log"

# Start the service. wait_for_t3_code_service reports a start that fails. A unit that hit its start
# limit, as when another server held the port, is reset first, since systemd would otherwise refuse
# to start it for 5 minutes.
start_t3_code_service() {
    if [ "$(systemctl --user show -p Result --value t3code.service 2>/dev/null)" == start-limit-hit ]; then
        systemctl --user reset-failed t3code.service || true
    fi
    systemctl --user start t3code.service || true
}

# Wait up to 10 s for the service to be running. Fails, saying where to look, when it isn't. A
# server that crashes on start shows as active between restarts, so it must keep one PID for 2 s.
wait_for_t3_code_service() {
    local _ pid last="" polls=0
    for _ in $(seq 1 20); do
        pid="$(systemctl --user show -p MainPID --value t3code.service 2>/dev/null || true)"
        if t3_code_service_active && [ "${pid:-0}" != 0 ] && [ "$pid" == "$last" ]; then
            polls=$((polls + 1))
            [ "$polls" -ge 4 ] && return 0
        else
            polls=0
        fi
        last="$pid"
        sleep 0.5
    done
    echo "  The T3 Code service isn't running. Check $T3_CODE_SERVICE_LOG" >&2
    return 1
}

# Print the local address of each TCP listener on the server's port that isn't on loopback, one per
# line, from ss -Hltn, whose fourth column is <address>:<port>, such as 127.0.0.1:3773, [::1]:3773,
# or *:3773. The drop-in sets the host, but T3 could take one from elsewhere, such as its settings
# or a --host flag, so the step checks what actually listens. Fails when ss does.
t3_code_exposed_listeners() {
    local listeners
    listeners="$(ss -Hltn 2>/dev/null)" || return 1
    awk -v port=":$T3_CODE_PORT" '
        { addr = $4 }
        length(addr) > length(port) && substr(addr, length(addr) - length(port) + 1) == port {
            host = substr(addr, 1, length(addr) - length(port))
            # An interface scope, as in 127.0.0.1%lo
            sub(/%[^]]*$/, "", host)
            if (host !~ /^127\./ && host != "[::1]" && host !~ /^\[::ffff:127\./) print addr
        }' <<< "$listeners"
}

# Fail, saying what to do, when the server listens anywhere but loopback, where ufw would let the
# tailnet reach it without tailscale serve's HTTPS
t3_code_check_listeners() {
    local exposed
    if ! exposed="$(t3_code_exposed_listeners)"; then
        echo "  ss couldn't list the listeners on port $T3_CODE_PORT, so the step couldn't check that the" >&2
        echo "  T3 Code server listens only on loopback." >&2
        return 1
    fi
    [ -n "$exposed" ] || return 0
    echo "  Port $T3_CODE_PORT is open beyond loopback, where the tailnet can reach it: $(join_lines ', ' <<< "$exposed")." >&2
    echo "  Stop the service (systemctl --user stop t3code), and check T3's host setting." >&2
    return 1
}

# Returns 1 when installing t3 failed, whatever the installer exited with, and 2 only when you
# declined the sudo it needs
install_t3_cli() {
    if [ -x "$HOME/.local/bin/t3" ]; then
        echo "  t3 already installed."
        return 0
    fi
    # t3 links against libatomic, which build-essential (from the homebrew step) brings in
    if ! apt_installed libatomic1; then
        confirm_sudo_changes "Install libatomic1, which the t3 CLI needs" || return 2
        # Stale package lists would point at versions the mirror no longer has
        # shellcheck disable=SC2119 # it passes options on to apt-get update, and needs none here
        apt_get_update || return 1
        apt_get install -y libatomic1 || return 1
    fi
    echo "  Installing the t3 CLI to ~/.local/bin..."
    run_installer sh https://t3.codes/install.sh "the t3 installer" || return 1
    if [ ! -x "$HOME/.local/bin/t3" ]; then
        echo "  The t3 installer finished, but $HOME/.local/bin/t3 isn't there." >&2
        return 1
    fi
}

t3_code_drop_in_current() {
    file_is "$T3_CODE_SERVICE_DROP_IN" "$T3_CODE_SERVICE_DROP_IN_CONTENT"
}

# Check systemd's loaded unit separately from the running process: daemon-reload changes the
# unit properties, but the process keeps its original environment until restarted.
t3_code_drop_in_loaded() {
    local environment
    [ "$(systemctl --user show -p NeedDaemonReload --value t3code.service 2>/dev/null)" == no ] || return 1
    environment=" $(systemctl --user show -p Environment --value t3code.service 2>/dev/null) "
    [[ "$environment" == *" T3CODE_TELEMETRY_ENABLED=false "* ]] &&
        [[ "$environment" == *" T3CODE_PORT=$T3_CODE_PORT "* ]] &&
        [[ "$environment" == *" T3CODE_HOST=$T3_CODE_HOST "* ]]
}

# Have systemd load the drop-in when the unit exists and hasn't: a new drop-in, or a reload that
# failed last run
t3_code_load_drop_in() {
    if [ ! -f "$T3_CODE_SERVICE_UNIT" ] || t3_code_drop_in_loaded; then
        return 0
    fi
    systemctl --user daemon-reload || return 1
    if ! t3_code_drop_in_loaded; then
        echo "  systemd hasn't loaded the T3 Code drop-in. Check: systemctl --user cat t3code" >&2
        return 1
    fi
}

t3_code_process_environ() {
    tr '\0' '\n' < "/proc/$1/environ"
}

# Succeeds when the service's running process has the drop-in's environment
t3_code_running_env_current() {
    local pid environment
    pid="$(systemctl --user show -p MainPID --value t3code.service 2>/dev/null)" || return 1
    case "$pid" in '' | 0 | *[!0-9]*) return 1 ;; esac
    environment="$(t3_code_process_environ "$pid" 2>/dev/null)" || return 1
    grep -qxF 'T3CODE_TELEMETRY_ENABLED=false' <<< "$environment" &&
        grep -qxF "T3CODE_PORT=$T3_CODE_PORT" <<< "$environment" &&
        grep -qxF "T3CODE_HOST=$T3_CODE_HOST" <<< "$environment" &&
        [ "$pid" == "$(systemctl --user show -p MainPID --value t3code.service 2>/dev/null)" ]
}

# A running service that hasn't loaded the drop-in, or started before it did, as after a failed
# restart. Unreadable process state can't show that the drop-in took effect, so it counts too.
t3_code_restart_pending() {
    [ -f "$T3_CODE_SERVICE_DROP_IN" ] || return 1
    t3_code_service_active || return 1
    ! { t3_code_drop_in_loaded && t3_code_running_env_current; }
}

# Say which server outside the service, from its t3_code_other_servers line, keeps the step from
# changing the server's settings and the service, and how to stop it
t3_code_print_other_server() {
    echo "  Another T3 Code server is running, so skipping the server settings and the service, which"
    echo "  would run a second one:"
    t3_code_describe_server "$1" | fold -s -w 96 | sed 's/ *$//; s/^/  /'
}

configure_t3_code_ubuntu() {
    echo "Configuring the T3 Code server..."
    local have_cli=true cli_status=0 step_failed=false update_status=0
    install_t3_cli || cli_status=$?
    [ "$cli_status" -eq 0 ] || have_cli=false

    # Two servers on one database conflict, and a running server writes settings.json too. So
    # while another server runs, change neither the settings nor the service, which
    # `t3 service install` or a start would run beside it.
    local other
    other="$(t3_code_other_servers | head -1)"
    if [ -n "$other" ]; then
        t3_code_print_other_server "$other"
    else
        # Settings that fail to apply don't stop the service or the browser setup below. A drop-in
        # that isn't written and loaded does stop the service, which would serve on every
        # interface without it.
        update_t3_code_server || update_status=$?
        [ "$update_status" -eq 0 ] || step_failed=true
        # The service runs the server from boot, so the phone app (through T3 Connect) and the
        # Mac can reach it without a login
        if ! "$have_cli"; then
            echo "  Without the t3 CLI there's no service to install; skipping it."
        elif [ "$update_status" -eq 2 ]; then
            # A running service whose restart was declined is left running, as it was
            echo "  Without its drop-in, the service would serve on every interface, so setup doesn't" >&2
            echo "  install, enable, or start it." >&2
        else
            ensure_t3_code_service || step_failed=true
        fi
    fi

    if "$have_cli"; then
        setup_t3_code_browser || step_failed=true
    fi
    # A failed install, setting, service, or browser setup fails the step, after the rest above; a
    # declined install doesn't
    [ "$cli_status" -ne 1 ] && ! "$step_failed"
}

# Write the service's drop-in when it isn't current, then have systemd load it. Neither touches the
# running server, which keeps its environment until it restarts. Fails when either fails.
t3_code_write_drop_in() {
    local tmp=""
    if ! t3_code_drop_in_current; then
        # Through write_back, since a drop-in cut short without its host line would have the
        # enabled unit serve on every interface at the next boot
        if ! tmp="$(mktemp)" || ! printf '%s\n' "$T3_CODE_SERVICE_DROP_IN_CONTENT" > "$tmp" ||
            ! mkdir -p "$(dirname "$T3_CODE_SERVICE_DROP_IN")"; then
            rm -f "$tmp"
            return 1
        fi
        write_back "$tmp" "$T3_CODE_SERVICE_DROP_IN" || return 1
    fi
    t3_code_load_drop_in
}

# Set the server settings and write the service's drop-in (telemetry, port, and host). The
# running server writes settings.json too, and keeps its environment until it restarts, so when
# either needs changing a running service is stopped around the change, after asking once. A
# declined restart still writes and loads the drop-in, which applies at the next restart, such as
# a reboot, and leaves the settings for a later run. Fails with 2 when the drop-in isn't written
# and loaded, and then doesn't start a service it stopped. Fails with 1 when only something else
# failed.
update_t3_code_server() {
    local settings_set=false stopped=false result=0 drop_in_ok=true drop_in_was_current=false
    t3_code_choose_custom_values
    json_applied "$T3_CODE_SETTINGS" "$(t3_code_server_filter)" && settings_set=true
    # Loading a current drop-in, as after a failed reload, needs no restart unless the running
    # server lacks its environment
    if t3_code_drop_in_current; then
        drop_in_was_current=true
        t3_code_load_drop_in || return 2
    fi
    if "$settings_set" && "$drop_in_was_current" && ! t3_code_restart_pending; then
        echo "  The $T3_CODE_SERVER_SETTINGS_NAME and the service's drop-in are already set"
        return 0
    fi
    if t3_code_service_active; then
        if ! confirm "  Restart the T3 Code service to apply its settings and drop-in? Threads running on it stop."; then
            local lacks=""
            if ! "$drop_in_was_current"; then
                if ! t3_code_write_drop_in; then
                    echo "  Couldn't write and load $T3_CODE_SERVICE_DROP_IN" >&2
                    return 2
                fi
                echo "  Wrote the drop-in; it applies at the next restart of the T3 Code service"
            fi
            "$settings_set" || lacks="its new settings"
            ! t3_code_restart_pending || lacks="${lacks:+$lacks and }its drop-in"
            if [ -n "$lacks" ]; then
                echo "  Left the T3 Code service running, without $lacks. Re-run from a terminal to"
                echo "  restart it."
            fi
            return 0
        fi
        if ! systemctl --user stop t3code.service || t3_code_service_active; then
            echo "  Couldn't stop the T3 Code service, so its settings are unchanged. Check:" >&2
            echo "  systemctl --user status t3code" >&2
            return 1
        fi
        stopped=true
    fi
    if ! "$settings_set"; then
        json_merge "$T3_CODE_SETTINGS" "$(t3_code_server_filter)" || result=1
    fi
    # A drop-in that was current is loaded above
    "$drop_in_was_current" || t3_code_write_drop_in || drop_in_ok=false
    if "$stopped" && "$drop_in_ok"; then
        start_t3_code_service
        wait_for_t3_code_service || result=1
    elif "$stopped"; then
        echo "  Left the T3 Code service stopped, since it would start without its drop-in" >&2
    fi
    if [ "$result" -ne 0 ] || ! "$drop_in_ok"; then
        echo "  Couldn't set all of the $T3_CODE_SERVER_SETTINGS_NAME and $T3_CODE_SERVICE_DROP_IN" >&2
        "$drop_in_ok" || return 2
        return 1
    fi
    echo "  Set the $T3_CODE_SERVER_SETTINGS_NAME and $T3_CODE_SERVICE_DROP_IN"
    if "$stopped"; then
        echo "  Restarted the T3 Code service"
    fi
}

# Install the service, or repair an installed one. Enabling or starting it stops no thread, so it
# happens without asking. Fails when the service doesn't stay up, or when there's none to repair
# and linger is off.
ensure_t3_code_service() {
    local changed=false
    if [ ! -f "$T3_CODE_SERVICE_UNIT" ]; then
        if ! t3_code_lingering; then
            echo "  Linger is off, so the service would only start once you log in; skipping it. Run:" >&2
            echo "  bash setup.sh ubuntu, then re-run this script." >&2
            return 1
        fi
        "$HOME/.local/bin/t3" service install || true
        wait_for_t3_code_service || return 1
        echo "  Installed the T3 Code service, which starts at boot"
    else
        if ! t3_code_lingering; then
            echo "  Linger is off, so the service only starts once you log in. Run: bash setup.sh ubuntu"
        fi
        if ! t3_code_service_enabled; then
            if ! systemctl --user enable t3code.service; then
                echo "  Couldn't enable the T3 Code service. Check: systemctl --user status t3code" >&2
                return 1
            fi
            echo "  Enabled the T3 Code service, so it starts at boot"
            changed=true
        fi
        if ! t3_code_service_active; then
            start_t3_code_service
            echo "  Started the T3 Code service"
            changed=true
        fi
        wait_for_t3_code_service || return 1
        if "$changed"; then
            echo "  The T3 Code service is running"
        else
            echo "  The T3 Code service is already installed and running"
        fi
    fi
    t3_code_check_listeners || return 1
    warn_t3_code_service_docker_group
}

# Print a process's supplementary group IDs, from the Groups line of /proc/<pid>/status. Fails
# when it can't read them.
t3_code_process_groups() {
    sed -n 's/^Groups:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null
}

# The docker step adds you to the docker group while the systemd user manager runs, and the
# service it starts keeps the manager's groups until the manager restarts. Warn, without failing,
# when you're in the group and the service isn't.
warn_t3_code_service_docker_group() {
    local gid pid groups
    [[ " $(id -nG "$(id -un)" 2>/dev/null) " == *" docker "* ]] || return 0
    gid="$(getent group docker 2>/dev/null | cut -d: -f3)"
    pid="$(systemctl --user show -p MainPID --value t3code.service 2>/dev/null || true)"
    [ -n "$gid" ] && [ "${pid:-0}" != 0 ] || return 0
    groups="$(t3_code_process_groups "$pid")" || return 0
    [[ " $groups " == *" $gid "* ]] && return 0
    echo "  The T3 Code service's agents can't use docker yet: the systemd user manager that starts the"
    echo "  service still has the groups it had before you joined the docker group. Reboot, or run"
    echo "  \`sudo systemctl restart user@$(id -u)\`, which stops the service and tmux."
}

# Ubuntu blocks Chrome's sandbox, which T3 Code's browser runs in, until an AppArmor
# profile allows it. `t3 browser setup` adds the profile and any libraries the browser is missing.
# Without sudo it changes nothing and, when there's something to do, says it needs root. Returns 0
# when there's nothing to do, 1 when it needs root, and 2 on failure.
t3_code_browser_ready() {
    local report
    report="$("$HOME/.local/bin/t3" browser setup 2>&1)" || return 2
    [[ "$report" != *"needs root"* ]]
}

setup_t3_code_browser() {
    local ready=0
    t3_code_browser_ready || ready=$?
    if [ "$ready" -eq 2 ]; then
        echo "  t3 browser setup failed; run it directly to inspect the error." >&2
        return 1
    fi
    if [ "$ready" -eq 0 ]; then
        echo "  T3 Code's browser can already run in Chrome's sandbox"
        return 0
    fi
    echo "  T3 Code's browser needs a one-time root setup to run in Chrome's sandbox. Run:"
    echo "    sudo ~/.local/bin/t3 browser setup"
    echo "  The step doesn't run it: t3 is writable by you and updates itself, so check it's the one you installed."
}

# Status's check that the service runs. --quick checks once that it's active, instead of
# watching it for up to 10 s for a server that crashes on start.
t3_code_service_running_now() {
    if status_quick; then
        t3_code_service_active
    else
        wait_for_t3_code_service 2>/dev/null
    fi
}

# Status items for T3 Code servers outside the service, each of which shares its data
t3_code_status_other_servers() {
    local servers line
    servers="$(t3_code_other_servers)"
    if [ -z "$servers" ]; then
        status_item ok "No T3 Code server outside t3code.service"
        return 0
    fi
    while IFS= read -r line; do
        status_item missing "No T3 Code server outside t3code.service: $(t3_code_describe_server "$line")"
    done <<< "$servers"
}

# Print an item for whether everything listening on the server's port is on loopback
t3_code_status_listeners() {
    local exposed name="Port $T3_CODE_PORT open only on loopback"
    if ! exposed="$(t3_code_exposed_listeners)"; then
        status_item unknown "$name: ss couldn't list the listeners"
    elif [ -n "$exposed" ]; then
        status_item missing "$name: also on $(join_lines ', ' <<< "$exposed"), which the tailnet can reach; stop the service (systemctl --user stop t3code) and check T3's host setting"
    else
        status_item ok "$name"
    fi
}

# Print an item for whether the server is linked to T3 Connect and publishes agent activity, which
# the phone app needs for push notifications. t3 connect status reads what's saved; the server
# sets up an authorized link only when it starts.
t3_code_status_connect() {
    local name="T3 Connect linked and publishing agent activity" state
    state="$("$HOME/.local/bin/t3" connect status --json 2>/dev/null |
        jq -r 'if .linked == true and .publishAgentActivity == true then "ok"
            elif .linked == true then "publish"
            elif .desired == true and .authenticated == true then "restart"
            elif has("linked") then "connect"
            else empty end' 2>/dev/null || true)"
    case "$state" in
        ok) status_item ok "$name" ;;
        publish) status_item missing "$name: run t3 connect publish" ;;
        restart) status_item missing "$name: the server sets up the link when it starts: t3 service restart" ;;
        connect) status_item missing "$name: run t3 connect --headless, then t3 connect publish and t3 service restart (see ai_tools/README.md → Manual steps)" ;;
        *) status_item unknown "T3 Connect: t3 connect status didn't say; run it to see why" ;;
    esac
}

status() {
    # jq reads the settings and t3 connect status; the rest doesn't need it
    local jq=true
    status_require_cmd jq "T3 Code's settings" || jq=false
    if is_macos; then
        local state="" app="" listing=""
        if command -v brew &>/dev/null; then
            IFS=$'\t' read -r state app <<< "$(t3_code_cask_state)"
        fi
        if [ "$state" == renamed ]; then
            status_item ok "t3-code (cask), as ${app##*/}"
        else
            # Whether brew lists the cask goes to status_cask as its listing, so brew isn't asked
            # again
            case "$state" in brew | gone) listing="t3-code"$'\t'"$app" ;; esac
            status_cask t3-code "$app" "$listing"
        fi
        if "$jq"; then
            t3_code_status_server_settings
            status_check "App settings in ~/.t3/userdata/client-settings.json" json_applied "$T3_CODE_CLIENT_SETTINGS" "$T3_CODE_CLIENT_FILTER"
        fi
        t3_code_files status_file
        t3_code_macos_items
        items_status t3_code_telemetry_off
        status_item skipped "t3 CLI and the T3 Code service: Ubuntu only; on macOS the app runs the server"
        status_result
        return
    fi
    status_item skipped "T3 Code desktop app and its settings: macOS only; on Ubuntu the service runs the server"
    local have_cli=false ready=0
    [ -x "$HOME/.local/bin/t3" ] && have_cli=true
    status_check "t3 CLI in ~/.local/bin" "$have_cli"
    status_check "Telemetry off, port $T3_CODE_PORT, and host $T3_CODE_HOST in the service drop-in" \
        t3_code_drop_in_current
    ! "$jq" || t3_code_status_server_settings
    if [ ! -f "$T3_CODE_SERVICE_UNIT" ] && ! t3_code_lingering; then
        status_item missing "T3 Code service: turn on linger: \`bash setup.sh ubuntu\`, then re-run the t3-code step"
    elif [ ! -f "$T3_CODE_SERVICE_UNIT" ]; then
        status_item missing "T3 Code service: re-run the t3-code step (bash ai_tools/setup.sh t3-code), which runs t3 service install"
    elif t3_code_service_running_now; then
        status_item ok "T3 Code service running"
    else
        status_item missing "T3 Code service running; check $T3_CODE_SERVICE_LOG"
    fi
    if [ -f "$T3_CODE_SERVICE_UNIT" ]; then
        status_check "T3 Code service enabled at boot" t3_code_service_enabled
        status_check "Linger enabled for T3 Code to start without login" t3_code_lingering
    fi
    t3_code_status_listeners
    if t3_code_restart_pending; then
        status_item missing "T3 Code service restarted for its drop-in: systemctl --user restart t3code"
    fi
    t3_code_status_other_servers
    if "$have_cli" && status_quick; then
        status_item unverified "T3 Code's browser sandbox: skipped by --quick, since it runs t3 browser setup"
    elif "$have_cli"; then
        t3_code_browser_ready || ready=$?
        case "$ready" in
            0) status_item ok "T3 Code's browser can run in Chrome's sandbox" ;;
            1) status_item missing "T3 Code's browser can run in Chrome's sandbox: run sudo ~/.local/bin/t3 browser setup" ;;
            *) status_item unknown "T3 Code's browser sandbox: t3 browser setup failed; run it directly to inspect the error" ;;
        esac
    fi
    if "$have_cli"; then
        if "$jq"; then
            t3_code_status_connect
        else
            status_item unknown "T3 Connect: $(missing_cmd_hint jq)"
        fi
    else
        status_item unknown "T3 Connect: needs the t3 CLI"
    fi
    status_result
}

apply() {
    echo "Setting up T3 Code..."
    require_cmd jq || return 1
    if is_macos; then
        require_cmd brew || return 1
    elif [ ! -x "$HOME/.local/bin/t3" ]; then
        # To download the t3 installer
        require_cmd curl || return 1
    fi
    if is_macos; then
        # Telemetry and the settings don't need the app. brew is asked about the cask once, for
        # the install and the app's path.
        local cask_failed=0 state app
        IFS=$'\t' read -r state app <<< "$(t3_code_cask_state)"
        if [ "$state" == renamed ]; then
            echo "  t3-code already installed, as ${app##*/}."
        else
            install_cask t3-code "" "$state" || cask_failed=1
        fi
        configure_t3_code "$app" || return 1
        return "$cask_failed"
    else
        configure_t3_code_ubuntu || return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
