#!/bin/bash
set -euo pipefail

# Install T3 Code and set its settings, and on Ubuntu run its server as a service.
# Installs a cask and runs launchctl (macOS), or apt and systemctl --user (Ubuntu), whatever HOME
# is; test in a macOS VM or spare Mac, and an Ubuntu VM with systemd such as an OrbStack machine.
# On Ubuntu the desktop app connects to the service, with its own server off.
# --status runs `t3 browser setup` without sudo, which changes nothing (T3 Code 0.1.1).

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
# T3 Code reads T3CODE_TELEMETRY_ENABLED only from its environment, which from the Dock is
# launchd's. One agent sets it then opens the app (by bundle ID), so the order holds; T3 Connect,
# which the phone app needs, runs only while the app is open.
T3_CODE_TELEMETRY_AGENT="$HOME/Library/LaunchAgents/dotfiles.t3code-telemetry-off.plist"

# On Ubuntu GNOME starts apps with environment.d's variables, from the next login
T3_CODE_ENVIRONMENT="$HOME/.config/environment.d/60-dotfiles-t3code.conf"

# Not loaded now: it would open T3 Code, which must be quit for the settings merge.
t3_code_files() {
    if is_macos; then
        "$1" "$DOTFILES_DIR/ai_tools/t3-code/dotfiles.t3code-telemetry-off.plist" "$T3_CODE_TELEMETRY_AGENT"
    else
        "$1" "$DOTFILES_DIR/ai_tools/t3-code/60-dotfiles-t3code.conf" "$T3_CODE_ENVIRONMENT"
    fi
}

# Ubuntu's desktop app: its own server would share the service's data, which the server's lock
# refuses, so it connects to the service instead. Only the desktop app reads this file.
T3_CODE_DESKTOP_SETTINGS="$HOME/.t3/userdata/desktop-settings.json"
T3_CODE_DESKTOP_FILTER='.localEnvironmentEnabled = false'
T3_CODE_RELEASE_API=https://api.github.com/repos/pingdotgg/t3code/releases/latest

t3_code_desktop_installed() {
    apt_installed t3code
}

# The latest release's .deb, checked against GitHub's digest. It updates itself after, asking for
# your password. Runs where set -e is off: each command checks its own failure.
install_t3_code_desktop() {
    local arch dir url digest status=0
    arch="$(dpkg --print-architecture)" || return 1
    dir="$(mktemp -d)" || return 1
    if ! fetch "$T3_CODE_RELEASE_API" "$dir/release.json" "T3 Code's latest release"; then
        rm -rf "$dir"
        return 1
    fi
    read -r url digest < <(jq -r --arg suffix "-$arch.deb" \
        '[.assets[] | select(.name | endswith($suffix))][0] // empty | "\(.browser_download_url) \(.digest // "")"' \
        "$dir/release.json")
    if [ -z "${url:-}" ] || [[ "${digest:-}" != sha256:* ]]; then
        echo "  T3 Code's latest release has no $arch .deb with a digest, so nothing was installed." >&2
        rm -rf "$dir"
        return 1
    fi
    # apt reads the file as _apt
    chmod 755 "$dir"
    if ! fetch "$url" "$dir/t3code.deb" "T3 Code's .deb"; then
        status=1
    elif [ "$(sha256sum "$dir/t3code.deb" | cut -d' ' -f1)" != "${digest#sha256:}" ]; then
        echo "  T3 Code's .deb doesn't match the digest GitHub lists for it, so it wasn't installed." >&2
        status=1
    else
        chmod 644 "$dir/t3code.deb"
        apt_get install -y "$dir/t3code.deb" || status=1
    fi
    rm -rf "$dir"
    return "$status"
}

t3_code_desktop_items() {
    items_reset
    item --sudo "T3 Code desktop app" "Install the T3 Code desktop app from its latest GitHub release" \
        t3_code_desktop_installed install_t3_code_desktop
}

# The settings go first, so the app's first launch doesn't try to start a server
setup_t3_code_desktop_ubuntu() {
    echo "Setting up the T3 Code desktop app..."
    local result=0 pending=()
    if ! has_gnome_desktop; then
        echo "  No GNOME desktop, so no desktop app; the service runs the server."
        return 0
    fi
    t3_code_files copy_file || result=1
    merge_app_json t3code \
        "The desktop app's own server is already off, and its app settings are set" \
        "Turned off the desktop app's own server, so it connects to the service, and set its app settings" \
        "$T3_CODE_DESKTOP_SETTINGS" "$T3_CODE_DESKTOP_FILTER" \
        "$T3_CODE_CLIENT_SETTINGS" "$T3_CODE_CLIENT_FILTER" || result=1
    t3_code_desktop_items
    items_pending
    if [ ${#pending[@]} -eq 0 ]; then
        echo "  The T3 Code desktop app is already installed; it updates itself."
    elif confirm_sudo_changes "${pending[@]}"; then
        items_apply || result=1
    fi
    return "$result"
}

# The desktop app may run its own server on the service's data while it runs without its settings
t3_code_desktop_server_pending() {
    has_gnome_desktop && ! json_applied "$T3_CODE_DESKTOP_SETTINGS" "$T3_CODE_DESKTOP_FILTER" &&
        pgrep -x t3code > /dev/null 2>&1
}

# Not XDG_CONFIG_HOME: neither `t3 service install` nor the systemd user manager reads the shell's.
T3_CODE_SERVICE_UNIT="$HOME/.config/systemd/user/t3code.service"
# A drop-in, since `t3 service install` and `t3 update` rewrite the unit. The port is pinned because
# `t3 serve` otherwise picks a free one while `tailscale serve` points at 3773. Loopback only, since
# ufw lets the tailnet reach every port; `tailscale serve` is the way in.
T3_CODE_SERVICE_DROP_IN="$T3_CODE_SERVICE_UNIT.d/dotfiles.conf"
T3_CODE_PORT=3773
T3_CODE_HOST=127.0.0.1
T3_CODE_SERVICE_DROP_IN_CONTENT="[Service]
Environment=T3CODE_TELEMETRY_ENABLED=false
Environment=T3CODE_PORT=$T3_CODE_PORT
Environment=T3CODE_HOST=$T3_CODE_HOST"

T3_CODE_MODEL="claude-opus-5-5"
T3_CODE_MODEL_NAME="T3 Code's default model (defaultModelSelection.model)"
T3_CODE_REPLACE_MODEL=false
T3_CODE_EFFORT="medium"
T3_CODE_EFFORT_NAME="T3 Code's default effort (defaultModelSelection.options effort)"
T3_CODE_REPLACE_EFFORT=false

T3_CODE_SERVER_SETTINGS_NAME="server settings (model, threads, setup actions, cleanup, merge, writing style)"

# Objects are set key by key so keys a newer T3 Code adds survive. T3 Code drops values equal to a
# key's default, so setting one never settles (scripts/check-t3-settings.sh warns). Setup actions
# get async=false per list, as T3 has no global default.
t3_code_server_filter() {
    # shellcheck disable=SC2016 # jq variables, not shell ones
    printf '%s\n' '
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
    # The 1m context window goes with our effort; a custom window stays unless model or effort changed
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

t3_code_model() {
    jq -r '.defaultModelSelection.model // empty' "$T3_CODE_SETTINGS" 2>/dev/null || true
}

# Only on the repo's model, whichever instance runs it
t3_code_effort() {
    jq -r --arg model "$T3_CODE_MODEL" '.defaultModelSelection | select(.model == $model)
        | [.options[]? | select(.id == "effort") | .value][0] // empty' \
        "$T3_CODE_SETTINGS" 2>/dev/null || true
}

# A model of your own that stays leaves its effort alone
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

t3_code_status_custom_values() {
    local model effort
    model="$(t3_code_model)"
    [ -n "$model" ] || return 0
    status_custom_value "$T3_CODE_MODEL_NAME" "$model" "$T3_CODE_MODEL"
    [ "$model" == "$T3_CODE_MODEL" ] || return 0
    effort="$(t3_code_effort)"
    [ -z "$effort" ] || status_custom_value "$T3_CODE_EFFORT_NAME" "$effort" "$T3_CODE_EFFORT"
}

t3_code_status_server_settings() {
    status_check "Server settings in ~/.t3/userdata/settings.json" json_applied "$T3_CODE_SETTINGS" "$(t3_code_server_filter)"
    t3_code_status_custom_values
    t3_code_status_fresh_bases
}

# Project IDs whose override sets key $1 to false, comma-separated
t3_code_projects_with_false() {
    jq -r --arg key "$1" '[.projectSettingsOverrides // {} | to_entries[]
        | select(.value[$key] == false) | .key] | join(", ")' "$T3_CODE_SETTINGS" 2>/dev/null
}

# Reported, not set: newWorktreesStartFromOrigin is on by T3's default, which T3 drops from the
# file, so writing it would never settle. A project's override can turn either off.
t3_code_status_fresh_bases() {
    local name projects
    # The server settings line reports a missing or broken file
    jq -e 'type == "object"' "$T3_CODE_SETTINGS" &> /dev/null || return 0
    name="New worktrees start from origin's tip (newWorktreesStartFromOrigin)"
    projects="$(t3_code_projects_with_false newWorktreesStartFromOrigin)"
    if [ "$(jq -r '.newWorktreesStartFromOrigin' "$T3_CODE_SETTINGS" 2>/dev/null)" == false ]; then
        status_item missing "$name: off; in T3 Code's settings, turn on New worktrees start from remote"
    elif [ -n "$projects" ]; then
        status_item missing "$name: off for projects $projects; with each selected in T3 Code's settings, turn on New worktrees start from remote"
    else
        status_item ok "$name"
    fi
    name="Auto-pull on for every project (defaultAutoPull)"
    projects="$(t3_code_projects_with_false defaultAutoPull)"
    if [ -n "$projects" ]; then
        status_item missing "$name: off for projects $projects; with each selected in T3 Code's Settings → Source Control, turn on Automatically pull"
    else
        status_item ok "$name"
    fi
}

T3_CODE_CLIENT_FILTER='
    .notificationMode = "notifications-and-sound"
    | .inAppNotificationsEnabled = true
    | .followUpBehavior = "steer"
    | .sidebarWorkingShelfEnabled = true
    | .diffFilesCollapsed = false
    | .wordWrap = false
'

t3_code_status_client_settings() {
    status_check "App settings in ~/.t3/userdata/client-settings.json" json_applied "$T3_CODE_CLIENT_SETTINGS" "$T3_CODE_CLIENT_FILTER"
}

# The app's name changes between releases, so fall back to any non-nightly T3 Code*.app.
# Usage: t3_code_app_path [cask_app_path output, to skip asking brew again]
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

# As cask_state, plus "renamed": brew lists the cask but the app renamed itself in an update before
# the cask caught up. A renamed app brew doesn't list is "other".
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

t3_code_telemetry_off() {
    [ "$(launchctl getenv T3CODE_TELEMETRY_ENABLED 2>/dev/null)" == false ]
}

turn_off_t3_code_telemetry() {
    if ! launchctl setenv T3CODE_TELEMETRY_ENABLED false; then
        echo "  Couldn't set T3CODE_TELEMETRY_ENABLED in launchd's environment, so telemetry stays on" >&2
        echo "  until the next login" >&2
        return 1
    fi
    echo "  Turned off telemetry (restart T3 Code if it's running)"
}

# Usage: configure_t3_code [cask app path]
configure_t3_code() {
    echo "Configuring T3 Code..."
    local app_name
    app_name="$(t3_code_app_path "$@" || true)"
    app_name="${app_name##*/}"
    app_name="${app_name%.app}"
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

# A server started by hand, over SSH from the Mac via ~/.t3/ssh-launch and ~/.t3/runtime, or by the
# desktop app, which runs its own Electron binary on app.asar's server entry with --bootstrap-fd
# (T3 Code 0.1.1)
T3_CODE_HOME_RE="$(regex_escape "$HOME")"
T3_CODE_SSH_SERVER_PATTERN="$T3_CODE_HOME_RE/\.t3/(runtime|ssh-launch)/"
T3_CODE_DESKTOP_SERVER_PATTERN="/app\.asar/apps/server/dist/bin\.mjs --bootstrap-fd( |\$)"
T3_CODE_CLI_SERVER_PATTERN="$T3_CODE_SSH_SERVER_PATTERN.* serve( |\$)|(^|/)t3 (serve|start)( |\$)|$T3_CODE_DESKTOP_SERVER_PATTERN"

t3_code_in_service_cgroup() {
    grep -q '/t3code\.service$' "/proc/$1/cgroup" 2>/dev/null
}

# Print "<pid> desktop|ssh|manual <command line>" per T3 Code server outside the service
t3_code_other_servers() {
    local line pid cmd kind
    while IFS= read -r line; do
        pid="${line%% *}"
        cmd="${line#* }"
        if [ -z "$pid" ] || t3_code_in_service_cgroup "$pid"; then
            continue
        fi
        if [[ "$cmd" =~ $T3_CODE_DESKTOP_SERVER_PATTERN ]]; then
            kind=desktop
        elif [[ "$cmd" =~ $T3_CODE_SSH_SERVER_PATTERN ]]; then
            kind=ssh
        else
            kind=manual
        fi
        echo "$pid $kind $cmd"
    done < <(pgrep -a -u "$(id -u)" -f "$T3_CODE_CLI_SERVER_PATTERN" || true)
}

t3_code_describe_server() {
    local pid kind cmd name fix
    pid="${1%% *}"
    kind="${1#* }"
    cmd="${kind#* }"
    kind="${kind%% *}"
    case "$kind" in
        desktop)
            name="the desktop app's own server"
            fix="quit T3 Code, then re-run the t3-code step, which turns that server off"
            ;;
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

t3_code_lingering() {
    [ -e "/var/lib/systemd/linger/$(id -un)" ]
}

t3_code_service_enabled() {
    systemctl --user is-enabled --quiet t3code.service 2>/dev/null
}

t3_code_service_active() {
    systemctl --user is-active --quiet t3code.service 2>/dev/null
}

t3_code_launcher_has_server() {
    pgrep -P "$1" > /dev/null 2>&1
}

# Prints the service's main PID; fails when it has none
t3_code_main_pid() {
    local pid
    pid="$(systemctl --user show -p MainPID --value t3code.service 2>/dev/null)" || return 1
    case "$pid" in '' | 0 | *[!0-9]*) return 1 ;; esac
    echo "$pid"
}

# Active with no server: in 0.1.1 a server that finds ~/.t3/userdata locked exits, and the
# launcher idles until restarted. Checks 3 times since a swap (update) briefly has none too.
t3_code_service_serving_nothing() {
    local pid check
    for check in 1 2 3; do
        pid="$(t3_code_main_pid)" || return 1
        ! t3_code_launcher_has_server "$pid" || return 1
        if [ "$check" -lt 3 ] && ! status_quick; then
            sleep 1
        else
            return 0
        fi
    done
}

# shellcheck disable=SC2088 # shown, not expanded
T3_CODE_SERVICE_LOG="~/.t3/userdata/logs/boot-service.log"

# Reset any failed unit: one at its start limit refuses starts for 5 min, and systemd 259 reports
# it as exit-code, not start-limit-hit.
start_t3_code_service() {
    if systemctl --user is-failed --quiet t3code.service 2>/dev/null; then
        systemctl --user reset-failed t3code.service || true
    fi
    systemctl --user start t3code.service || true
}

# A crash-looping server shows active between restarts, so require one PID for 2 s (10 s max).
wait_for_t3_code_service() {
    local _ pid last="" polls=0
    for _ in $(seq 1 20); do
        pid="$(t3_code_main_pid || true)"
        if t3_code_service_active && [ -n "$pid" ] && [ "$pid" == "$last" ]; then
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

# Print each non-loopback listener on the port. T3 may take a host from elsewhere than the drop-in.
t3_code_exposed_listeners() {
    local listeners
    listeners="$(ss -Hltn 2>/dev/null)" || return 1
    awk -v port=":$T3_CODE_PORT" '
        { addr = $4 }
        length(addr) > length(port) && substr(addr, length(addr) - length(port) + 1) == port {
            host = substr(addr, 1, length(addr) - length(port))
            # Strip an interface scope, as in 127.0.0.1%lo
            sub(/%[^]]*$/, "", host)
            if (host !~ /^127\./ && host != "[::1]" && host !~ /^\[::ffff:127\./) print addr
        }' <<< "$listeners"
}

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

# Returns 1 on failure, 2 when sudo was declined
install_t3_cli() {
    if [ -x "$HOME/.local/bin/t3" ]; then
        echo "  t3 already installed."
        return 0
    fi
    if ! apt_installed libatomic1; then
        confirm_sudo_changes "Install libatomic1, which the t3 CLI needs" || return 2
        # shellcheck disable=SC2119 # needs no options
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

# The loaded unit, not the running process, which keeps its environment until restarted
t3_code_drop_in_loaded() {
    local environment
    [ "$(systemctl --user show -p NeedDaemonReload --value t3code.service 2>/dev/null)" == no ] || return 1
    environment=" $(systemctl --user show -p Environment --value t3code.service 2>/dev/null) "
    [[ "$environment" == *" T3CODE_TELEMETRY_ENABLED=false "* ]] &&
        [[ "$environment" == *" T3CODE_PORT=$T3_CODE_PORT "* ]] &&
        [[ "$environment" == *" T3CODE_HOST=$T3_CODE_HOST "* ]]
}

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

t3_code_running_env_current() {
    local pid environment
    pid="$(t3_code_main_pid)" || return 1
    environment="$(t3_code_process_environ "$pid" 2>/dev/null)" || return 1
    grep -qxF 'T3CODE_TELEMETRY_ENABLED=false' <<< "$environment" &&
        grep -qxF "T3CODE_PORT=$T3_CODE_PORT" <<< "$environment" &&
        grep -qxF "T3CODE_HOST=$T3_CODE_HOST" <<< "$environment" &&
        [ "$pid" == "$(t3_code_main_pid)" ]
}

# Unreadable process state counts as pending
t3_code_restart_pending() {
    [ -f "$T3_CODE_SERVICE_DROP_IN" ] || return 1
    t3_code_service_active || return 1
    ! { t3_code_drop_in_loaded && t3_code_running_env_current; }
}

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

    # Another server shares the database and writes settings.json, so leave both alone
    local other
    other="$(t3_code_other_servers | head -1)"
    if [ -n "$other" ]; then
        t3_code_print_other_server "$other"
    elif t3_code_desktop_server_pending; then
        echo "  The T3 Code desktop app is running with its own server on, so the server settings and the"
        echo "  service are pending until you quit it. Quit T3 Code, then re-run the t3-code step."
    else
        update_t3_code_server || update_status=$?
        [ "$update_status" -eq 0 ] || step_failed=true
        if ! "$have_cli"; then
            echo "  Without the t3 CLI there's no service to install; skipping it."
        elif [ "$update_status" -eq 2 ]; then
            echo "  Without its drop-in, the service would serve on every interface, so setup doesn't" >&2
            echo "  install, enable, or start it." >&2
        else
            ensure_t3_code_service || step_failed=true
        fi
    fi

    if "$have_cli"; then
        setup_t3_code_browser || step_failed=true
    fi
    [ "$cli_status" -ne 1 ] && ! "$step_failed"
}

t3_code_write_drop_in() {
    local tmp=""
    if ! t3_code_drop_in_current; then
        # write_back: a truncated drop-in without its host line would serve on every interface
        if ! tmp="$(mktemp)" || ! printf '%s\n' "$T3_CODE_SERVICE_DROP_IN_CONTENT" > "$tmp" ||
            ! mkdir -p "$(dirname "$T3_CODE_SERVICE_DROP_IN")"; then
            rm -f "$tmp"
            return 1
        fi
        write_back "$tmp" "$T3_CODE_SERVICE_DROP_IN" || return 1
    fi
    t3_code_load_drop_in
}

# Stops a running service around the change, since it writes settings.json too. Returns 2 when the
# drop-in isn't written and loaded (and leaves a stopped service stopped), 1 for other failures.
update_t3_code_server() {
    local settings_set=false stopped=false result=0 drop_in_ok=true drop_in_was_current=false
    t3_code_choose_custom_values
    json_applied "$T3_CODE_SETTINGS" "$(t3_code_server_filter)" && settings_set=true
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

# Run after wait_for_t3_code_service. Restarting a launcher that serves nothing stops no thread, so
# it doesn't ask. Sets the caller's changed=true when it restarts.
restart_t3_code_service_serving_nothing() {
    t3_code_service_serving_nothing || return 0
    systemctl --user restart t3code.service || true
    wait_for_t3_code_service || return 1
    if t3_code_service_serving_nothing; then
        echo "  The T3 Code service runs no server. Check $T3_CODE_SERVICE_LOG" >&2
        return 1
    fi
    echo "  Restarted the T3 Code service, which ran no server, as when another server had its"
    echo "  data as it started"
    changed=true
}

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
        restart_t3_code_service_serving_nothing || return 1
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
        restart_t3_code_service_serving_nothing || return 1
        if "$changed"; then
            echo "  The T3 Code service is running"
        else
            echo "  The T3 Code service is already installed and running"
        fi
    fi
    t3_code_check_listeners || return 1
    warn_t3_code_service_docker_group
}

t3_code_process_groups() {
    sed -n 's/^Groups:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null
}

# The service keeps the user manager's groups from before the docker step added you
warn_t3_code_service_docker_group() {
    local gid pid groups
    [[ " $(id -nG "$(id -un)" 2>/dev/null) " == *" docker "* ]] || return 0
    gid="$(getent group docker 2>/dev/null | cut -d: -f3)"
    [ -n "$gid" ] && pid="$(t3_code_main_pid)" || return 0
    groups="$(t3_code_process_groups "$pid")" || return 0
    [[ " $groups " == *" $gid "* ]] && return 0
    echo "  The T3 Code service's agents can't use docker yet: the systemd user manager that starts the"
    echo "  service still has the groups it had before you joined the docker group. Reboot, or run"
    echo "  \`sudo systemctl restart user@$(id -u)\`, which stops the service and tmux."
}

# Without sudo, `t3 browser setup` changes nothing. Returns 0 ready, 1 needs root, 2 failed.
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

t3_code_service_running_now() {
    if status_quick; then
        t3_code_service_active
    else
        wait_for_t3_code_service 2>/dev/null
    fi
}

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

# The phone app needs this for push notifications. The server links only when it starts.
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

t3_code_status_service() {
    if [ ! -f "$T3_CODE_SERVICE_UNIT" ] && ! t3_code_lingering; then
        status_item missing "T3 Code service: turn on linger: \`bash setup.sh ubuntu\`, then re-run the t3-code step"
    elif [ ! -f "$T3_CODE_SERVICE_UNIT" ]; then
        status_item missing "T3 Code service: re-run the t3-code step (bash ai_tools/setup.sh t3-code), which runs t3 service install"
    elif ! t3_code_service_running_now; then
        status_item missing "T3 Code service running; check $T3_CODE_SERVICE_LOG"
    elif t3_code_service_serving_nothing; then
        status_item missing "T3 Code service running a server: it runs none, as when another T3 Code server had its data as it started; stop any other server, then re-run the t3-code step"
    else
        status_item ok "T3 Code service running"
    fi
}

status() {
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
            # Pass the listing so brew isn't asked again
            case "$state" in brew | gone) listing="t3-code"$'\t'"$app" ;; esac
            status_cask t3-code "$app" "$listing"
        fi
        if "$jq"; then
            t3_code_status_server_settings
            t3_code_status_client_settings
        fi
        t3_code_files status_file
        t3_code_macos_items
        items_status t3_code_telemetry_off
        status_item skipped "t3 CLI and the T3 Code service: Ubuntu only; on macOS the app runs the server"
        status_result
        return
    fi
    if ! has_gnome_desktop; then
        status_item skipped "T3 Code desktop app: no GNOME desktop"
    else
        t3_code_desktop_items
        items_status
        t3_code_files status_file
        if "$jq"; then
            status_check "Desktop app's own server off in ~/.t3/userdata/desktop-settings.json" \
                json_applied "$T3_CODE_DESKTOP_SETTINGS" "$T3_CODE_DESKTOP_FILTER"
            t3_code_status_client_settings
            if t3_code_desktop_server_pending; then
                status_item missing "T3 Code server settings and service: pending while the desktop app runs with its own server on; quit T3 Code, then re-run the t3-code step"
            fi
        fi
    fi
    local have_cli=false ready=0
    [ -x "$HOME/.local/bin/t3" ] && have_cli=true
    status_check "t3 CLI in ~/.local/bin" "$have_cli"
    status_check "Telemetry off, port $T3_CODE_PORT, and host $T3_CODE_HOST in the service drop-in" \
        t3_code_drop_in_current
    ! "$jq" || t3_code_status_server_settings
    t3_code_status_service
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
        require_cmd curl || return 1
    fi
    if is_macos; then
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
        local desktop_failed=0
        setup_t3_code_desktop_ubuntu || desktop_failed=1
        configure_t3_code_ubuntu || return 1
        return "$desktop_failed"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
