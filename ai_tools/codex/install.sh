#!/bin/bash
set -euo pipefail

# Install the Codex CLI and the ChatGPT desktop app, configure ~/.codex/config.toml (shared by
# both), and copy the user-level instructions to ~/.codex/AGENTS.md. The ChatGPT app writes to
# config.toml too, so it must be quit first; when run interactively the script offers to quit
# it, otherwise it skips the settings. On Ubuntu, also set up what Codex's sandbox needs.
#
# A temp HOME doesn't isolate this step. On macOS it installs the chatgpt and codex casks, and on
# Ubuntu it installs packages and loads an AppArmor profile with sudo. Test the casks in a macOS VM
# or on a spare Mac, and the Ubuntu side in an Ubuntu VM.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

CODEX_CONFIG="$HOME/.codex/config.toml"
CODEX_INSTRUCTIONS="$HOME/.codex/AGENTS.md"
# The config path, the instructions, and the docs all assume ~/.codex, so another CODEX_HOME fails
# the step rather than leaving Codex reading files setup never wrote
CODEX_HOME_POLICY="setup assumes Codex's default home (~/.codex); unset CODEX_HOME or move it"
# Ubuntu's apparmor package installs this profile, which loads at boot
BWRAP_PROFILE=/etc/apparmor.d/bwrap-userns-restrict
# 1 when AppArmor restricts unprivileged user namespaces
USERNS_RESTRICT_SYSCTL=/proc/sys/kernel/apparmor_restrict_unprivileged_userns

# Settings you may keep your own values of (replace_custom_value), each a yq path, the repo's
# value as TOML (see codex_set), and a name. configure_codex sets CODEX_REPLACE to whether to write
# each over yours. Values only Ubuntu gets are marked ubuntu.
# Usage: codex_keepable <yq path> <TOML value> <name> [ubuntu]
CODEX_KEEP_PATHS=()
CODEX_KEEP_VALUES=()
CODEX_KEEP_NAMES=()
CODEX_KEEP_UBUNTU=()
CODEX_REPLACE=()
codex_keepable() {
    CODEX_KEEP_PATHS+=("$1")
    CODEX_KEEP_VALUES+=("$2")
    CODEX_KEEP_NAMES+=("Codex's $3")
    CODEX_KEEP_UBUNTU+=("$([ "${4:-}" == ubuntu ] && echo true || echo false)")
    CODEX_REPLACE+=(false)
}
# The default model and high reasoning effort, which /model changes
codex_keepable .model '"gpt-6.1-sol"' "model (model)"
codex_keepable .model_reasoning_effort '"high"' "reasoning effort (model_reasoning_effort)"
# The CLI footer: model with reasoning effort, directory, git branch, and context used. /statusline
# lists every item ID, and saves your choice here.
codex_keepable .tui.status_line '["model-with-reasoning", "current-dir", "git-branch", "context-used"]' \
    "status line (tui.status_line)"
# How the CLI sends notifications. Ubuntu is used over SSH, where a tmux pane may not carry
# Ghostty's TERM_PROGRAM (see the claude-code step), and `auto` then rings the bell. OSC 9, wrapped
# for tmux, reaches Ghostty on the Mac. On macOS, the repo's tmux config passes TERM_PROGRAM into
# panes, so `auto` finds Ghostty.
codex_keepable .tui.notification_method '"osc9"' "notification method (tui.notification_method)" ubuntu

# Succeeds when value $1 of CODEX_KEEP_PATHS applies on this OS
codex_keep_applies() {
    ! "${CODEX_KEEP_UBUNTU[$1]}" || is_ubuntu
}

# Print one line of JSON without a string's quotes
codex_unquote() {
    local value="${1#\"}"
    printf '%s\n' "${value%\"}"
}

# Print the config's value at path $1 of CODEX_KEEP_PATHS as one line of JSON, without a string's
# quotes, or nothing when it's unset or the config can't be read
codex_keep_current() {
    local value
    value="$(yq -p toml -o json -I=0 "${CODEX_KEEP_PATHS[$1]}" "$CODEX_CONFIG" 2>/dev/null)" || return 0
    [ "$value" == null ] || codex_unquote "$value"
}

# Print the repo's value $1 of CODEX_KEEP_VALUES as codex_keep_current prints it
codex_keep_wanted() {
    codex_unquote "$(printf 'v = %s\n' "${CODEX_KEEP_VALUES[$1]}" | yq -p toml -o json -I=0 '.v')"
}

# Add `<yq path> = <value>` to the settings codex_settings collects. Each value is written as
# TOML, which for the strings, booleans, and arrays of strings set here is also a yq literal.
codex_set() {
    CODEX_PATHS+=("$1")
    CODEX_VALUES+=("$2")
}

# Collect the settings to write in CODEX_PATHS and CODEX_VALUES
codex_settings() {
    local i
    CODEX_PATHS=()
    CODEX_VALUES=()
    # The settings you may keep, unless you chose your own and keep them
    for i in "${!CODEX_KEEP_PATHS[@]}"; do
        codex_keep_applies "$i" || continue
        if "${CODEX_REPLACE[i]}" || [ -z "$(codex_keep_current "$i")" ]; then
            codex_set "${CODEX_KEEP_PATHS[i]}" "${CODEX_KEEP_VALUES[i]}"
        fi
    done
    # Short answers and reasoning summaries
    codex_set .model_verbosity '"low"'
    codex_set .model_reasoning_summary '"concise"'
    # Edit and run commands in the workspace without network access. Anything else, including
    # network access, goes to the auto-review agent instead of asking you.
    codex_set .approval_policy '"on-request"'
    codex_set .approvals_reviewer '"auto_review"'
    # Codex's built-in workspace-write sandbox, which keeps the network off unless
    # [sandbox_workspace_write] turns it on. Your settings there stay.
    codex_set .sandbox_mode '"workspace-write"'
    # Send OpenAI less: no usage metrics or product events (CLI and desktop app), and no
    # /feedback log uploads. Training on your chats is an account setting (see
    # ai_tools/README.md → Privacy).
    codex_set .analytics.enabled 'false'
    codex_set .feedback.enabled 'false'
    if is_ubuntu; then
        # Keep MCP OAuth tokens in ~/.codex/.credentials.json. Over SSH, the GNOME keyring stays
        # locked until someone logs in at the desk, so with `auto` where tokens go, and whether
        # Codex can read them, depends on that.
        codex_set .mcp_oauth_credentials_store '"file"'
    fi

    # The ChatGPT desktop app is macOS-only, so Ubuntu gets no [desktop] keys. Its keys have
    # dashes, which yq reads as minus outside brackets.
    if is_macos; then
        # Desktop app: Settings → Git → Pull request merge method → Squash
        codex_set '.desktop["git-pull-request-merge-method"]' '"squash"'
        # Desktop app: don't refresh worktrees from their upstream branch
        codex_set '.desktop["worktree-upstream-refresh-mode"]' '"never"'
        # Desktop app: Settings → Notifications
        codex_set '.desktop["notifications-turn-mode"]' '"unfocused"'
        codex_set '.desktop["notifications-permissions-enabled"]' 'true'
        codex_set '.desktop["notifications-questions-enabled"]' 'true'
        # Desktop app: Settings → General → Prevent sleep while running
        codex_set '.desktop["preventSleepWhileRunning"]' 'true'
        # Desktop app: Settings → General → Show in menu bar (keeps ChatGPT in the menu bar, and
        # running, after the main window is closed)
        codex_set '.desktop["mac-menu-bar-enabled"]' 'false'
        # Desktop app: Settings → Connections → Keep this Mac awake (plugged in, remote access on)
        codex_set '.desktop["keepRemoteControlAwakeWhilePluggedIn"]' 'true'
        # Desktop app: a message sent mid-turn steers the running turn instead of queueing, and
        # threads show steps and commands
        codex_set '.desktop["followUpQueueMode"]' '"steer"'
        codex_set '.desktop["conversationDetailMode"]' '"STEPS_COMMANDS"'
        # Desktop app: show context window usage and ambient suggestions
        codex_set '.desktop["show-context-window-usage"]' 'true'
        codex_set '.desktop["ambient-suggestions-enabled"]' 'true'
        # Desktop app: open links and local URLs in your browser, not the built-in one
        codex_set '.desktop["open-link-in-target-preference"]' '"external-browser"'
        codex_set '.desktop["open-local-url-in-target-preference"]' '"external-browser"'
        # Desktop app: offer every reasoning effort in the picker
        codex_set '.desktop["enabled-reasoning-efforts"]' \
            '["low", "medium", "high", "xhigh", "ultra", "persistent", "max"]'
    fi
}

# Join what codex_settings collected with a separator: each setting's assignment (set), path
# (path), or value (value)
codex_settings_joined() {
    local separator="$1" part="$2" joined="" item i
    for i in "${!CODEX_PATHS[@]}"; do
        case "$part" in
            set) item="${CODEX_PATHS[i]} = ${CODEX_VALUES[i]}" ;;
            path) item="${CODEX_PATHS[i]}" ;;
            value) item="${CODEX_VALUES[i]}" ;;
        esac
        joined+="${joined:+$separator}$item"
    done
    printf '%s\n' "$joined"
}

# Print the number of full-line comments in a file
comment_lines() {
    grep -c '^[[:space:]]*#' "$1" || true
}

# Write a copy of the Codex config with the settings applied, and print its path. yq rewrites the
# whole file: values and full-line comments stay, but end-of-line comments may move or go,
# multi-line strings become one-line strings with \n, and dotted keys such as profile.fast = {...}
# may become tables. yq 4.54.1 drops the comments after the last key, such as a commented-out
# table at the end, so they're added back, and the copy must keep every full-line comment. It also
# moves values in two shapes, a top-level inline table after a top-level dotted key, and top-level
# keys after a top-level array of inline tables, so the copy is checked against the edit's own
# result before use.
codex_config_edited() {
    local edited filter source=/dev/null
    codex_settings
    filter="$(codex_settings_joined ' | ' set)"
    [ ! -f "$CODEX_CONFIG" ] || source="$CODEX_CONFIG"
    edited="$(mktemp)" || return 1
    if ! yq -p toml -o toml "$filter" "$source" > "$edited" ||
        ! yq -p toml -o json '.' "$edited" > /dev/null; then
        echo "  Couldn't edit $CODEX_CONFIG with yq; is it valid TOML? Leaving it unchanged." >&2
        rm -f "$edited"
        return 1
    fi
    if [ "$(yq -p toml -o json -I=0 "$filter | sort_keys(..)" "$source")" != \
        "$(yq -p toml -o json -I=0 'sort_keys(..)' "$edited")" ]; then
        echo "  yq would change other values in $CODEX_CONFIG while editing it; leaving it unchanged." >&2
        echo "  Write top-level dotted keys such as a.b = 1 as [a] tables, and top-level arrays of" >&2
        echo "  inline tables such as a = [{...}] as [[a]] tables, then re-run." >&2
        rm -f "$edited"
        return 1
    fi
    if [ "$(comment_lines "$edited")" -lt "$(comment_lines "$source")" ]; then
        awk '/^[[:space:]]*(#|$)/ { tail = tail $0 "\n"; next } { tail = "" } END { printf "%s", tail }' \
            "$source" >> "$edited"
    fi
    if [ "$(comment_lines "$edited")" -lt "$(comment_lines "$source")" ]; then
        echo "  yq would drop comments from $CODEX_CONFIG while editing it; leaving it unchanged." >&2
        rm -f "$edited"
        return 1
    fi
    echo "$edited"
}

# Succeeds when every setting codex_settings collects is already in the config
codex_config_matches() {
    local got want
    codex_settings
    [ -f "$CODEX_CONFIG" ] &&
        got="$(yq -p toml -o json -I=0 "[$(codex_settings_joined ', ' path)]" "$CODEX_CONFIG" 2>/dev/null)" &&
        want="$(yq -n -o json -I=0 "[$(codex_settings_joined ', ' value)]")" &&
        [ "$got" == "$want" ]
}

configure_codex() {
    echo "Configuring Codex..."
    local edited i
    for i in "${!CODEX_KEEP_PATHS[@]}"; do
        CODEX_REPLACE[i]=false
        if codex_keep_applies "$i" && replace_custom_value "${CODEX_KEEP_NAMES[i]}" \
            "$(codex_keep_current "$i")" "$(codex_keep_wanted "$i")"; then
            CODEX_REPLACE[i]=true
        fi
    done
    local settings="model, output, sandbox, approval, data-sharing, and status line settings"
    if is_macos; then
        settings="model, output, sandbox, approval, data-sharing, status line, and desktop app settings"
    fi
    if codex_config_matches; then
        echo "  The $settings are already set in $CODEX_CONFIG"
        return 0
    fi

    # Check the edit works before asking to quit the app. The ChatGPT app writes to config.toml
    # too, so quit it before editing, then re-apply the settings to whatever it wrote on the way
    # out.
    edited="$(codex_config_edited)" || return 1
    rm -f "$edited"
    ensure_app_quit "ChatGPT" || return 0
    edited="$(codex_config_edited)" || return 1
    if ! maybe_backup "$CODEX_CONFIG"; then
        rm -f "$edited"
        return 1
    fi
    mkdir -p "$(dirname "$CODEX_CONFIG")" || { rm -f "$edited"; return 1; }
    write_back "$edited" "$CODEX_CONFIG" || return 1
    echo "  Set the $settings in $CODEX_CONFIG"
}

# See user_instructions_to
user_instructions_files() {
    user_instructions_to "$CODEX_INSTRUCTIONS" "$@"
}

install_codex_cli() {
    install_cask codex "$(codex_cask_path)"
}

# Print the path of a codex Homebrew's cask installs. Prints nothing without brew, rather than
# /bin/codex.
codex_cask_path() {
    local prefix
    prefix="$(brew --prefix 2>/dev/null)" && [ -n "$prefix" ] || return 0
    echo "$prefix/bin/codex"
}

# Print an item for whether Codex is signed in. codex login status exits 0 when it is, and prints
# "Not logged in" and exits 1 when it isn't.
codex_status_signed_in() {
    local codex out
    codex="$(codex_cask_path)"
    if [ -z "$codex" ] || [ ! -x "$codex" ]; then
        status_item unknown "Signed in to Codex: Codex isn't installed"
        return
    fi
    if out="$("$codex" login status 2>&1)"; then
        status_item ok "Signed in to Codex"
    elif [[ "$out" != *"Not logged in"* ]]; then
        status_item unknown "Signed in to Codex: codex login status failed; run it to see why"
    elif is_macos; then
        status_item missing "Signed in to Codex: sign in to the ChatGPT app, or run codex login"
    else
        status_item missing "Signed in to Codex: run codex login --device-auth (see ai_tools/README.md → Manual steps)"
    fi
}

bwrap_works() {
    bwrap --unshare-all --ro-bind / / /bin/true &>/dev/null
}

# Ubuntu stops unprivileged processes from using the user namespaces bwrap needs,
# unless an AppArmor profile allows them
userns_restricted() {
    [ "$(cat "$USERNS_RESTRICT_SYSCTL" 2>/dev/null)" == "1" ]
}

# Succeeds when loading the bwrap-userns-restrict profile can fix a bwrap that fails, and says why
# not otherwise
bwrap_profile_can_fix() {
    if ! userns_restricted; then
        echo "  bwrap can't create a sandbox, and AppArmor's user namespace restriction isn't the" >&2
        echo "  cause. Check: bwrap --unshare-all --ro-bind / / /bin/true" >&2
        return 1
    fi
    if [ ! -f "$BWRAP_PROFILE" ]; then
        echo "  bwrap needs AppArmor's $BWRAP_PROFILE, which is missing. Reinstall the" >&2
        echo "  apparmor package that provides it, restoring its deleted config files:" >&2
        echo "  sudo apt-get install --reinstall -o Dpkg::Options::=--force-confmiss apparmor" >&2
        return 1
    fi
}

# The workspace-write sandbox runs commands with bubblewrap on Linux. Without a working bwrap, Codex
# warns at startup. These are the steps in https://learn.chatgpt.com/docs/sandboxing.
setup_codex_sandbox() {
    echo "Setting up Codex's sandbox..."
    local pending=() install=false
    if ! apt_installed bubblewrap; then
        install=true
        pending+=("Install bubblewrap, which Codex's sandbox runs commands in")
        # The profile bwrap needs loads at boot, so it's loaded only if bwrap then fails
        if userns_restricted; then
            pending+=("Load the bwrap-userns-restrict AppArmor profile, if bwrap then can't create user namespaces")
        fi
    elif bwrap_works; then
        echo "  Codex's sandbox already works."
        return 0
    else
        bwrap_profile_can_fix || return 1
        pending+=("Load the bwrap-userns-restrict AppArmor profile, so bwrap can create user namespaces")
    fi

    confirm_sudo_changes "${pending[@]}" || return 0
    if "$install"; then
        # shellcheck disable=SC2119 # it passes options on to apt-get update, and needs none here
        apt_get_update || return 1
        apt_get install -y bubblewrap || return 1
    fi
    if ! bwrap_works; then
        bwrap_profile_can_fix || return 1
        # The profile may not be loaded; apparmor_parser -r is safe to repeat
        sudo apparmor_parser -r "$BWRAP_PROFILE" || return 1
    fi
    if ! bwrap_works; then
        echo "  bwrap still can't create a sandbox, so Codex will warn at startup. Check:" >&2
        echo "  bwrap --unshare-all --ro-bind / / /bin/true" >&2
        return 1
    fi
    echo "  Codex's sandbox works now."
}

status() {
    local wanted value i
    if is_macos; then
        status_cask chatgpt /Applications/ChatGPT.app
    else
        status_item skipped "ChatGPT desktop app: macOS only"
    fi
    if status_require_cmd brew codex; then
        status_cask codex "$(codex_cask_path)"
    fi
    codex_status_signed_in
    if ! tool_home_is "${CODEX_HOME:-}" "$HOME/.codex"; then
        status_item unknown "Codex settings and instructions: $CODEX_HOME_POLICY"
    else
        if status_require_cmd yq "Settings in ~/.codex/config.toml"; then
            status_check "Settings in ~/.codex/config.toml" codex_config_matches
            for i in "${!CODEX_KEEP_PATHS[@]}"; do
                codex_keep_applies "$i" || continue
                value="$(codex_keep_current "$i")"
                wanted="$(codex_keep_wanted "$i")"
                if [ -n "$value" ] && [ "$value" != "$wanted" ]; then
                    status_custom_value "${CODEX_KEEP_NAMES[i]}" "$value" "$wanted"
                fi
            done
        fi
        user_instructions_files status_file "merge by hand, or re-run the step from a terminal to replace it"
    fi
    if is_ubuntu; then
        status_check "Codex's sandbox: bwrap can create one" bwrap_works
    else
        status_item skipped "Codex's sandbox: macOS's built-in sandbox needs no setup"
    fi
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Setting up Codex..."
    if ! tool_home_is "${CODEX_HOME:-}" "$HOME/.codex"; then
        echo "  CODEX_HOME is $CODEX_HOME, but $CODEX_HOME_POLICY" >&2
        return 1
    fi
    require_cmd yq || return 1
    require_cmd brew || return 1
    local result=0
    if is_macos; then
        install_cask chatgpt /Applications/ChatGPT.app || result=1
    fi
    install_codex_cli || result=1
    configure_codex || result=1
    install_user_instructions "$CODEX_INSTRUCTIONS" || result=1
    if is_ubuntu; then
        setup_codex_sandbox || result=1
    fi
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
