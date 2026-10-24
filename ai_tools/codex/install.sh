#!/bin/bash
set -euo pipefail

# Install the Codex CLI and the ChatGPT app, and set Codex's config and instructions.
# Installs casks, and on Ubuntu installs apt packages and loads AppArmor's bwrap profile, whatever
# HOME is; test in a macOS VM or spare Mac, and an Ubuntu VM.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=../../lib/casks.sh
source "$DOTFILES_DIR/lib/casks.sh"
# shellcheck source=../lib/keepable.sh
source "$DOTFILES_DIR/ai_tools/lib/keepable.sh"
# shellcheck source=../lib/tool-home.sh
source "$DOTFILES_DIR/ai_tools/lib/tool-home.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

CODEX_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CODEX_INSTRUCTIONS="$CODEX_DIR/AGENTS.md"
CODEX_CREDENTIALS="$CODEX_DIR/.credentials.json"
BWRAP_PROFILE=/etc/apparmor.d/bwrap-userns-restrict
USERNS_RESTRICT_SYSCTL=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
# yq -o toml's encoder arrived in 4.52.1 and was fixed up to 4.54.1
YQ_MIN_VERSION=4.54.1

# Prints nothing for a yq other than mikefarah's
codex_yq_version() {
    yq --version 2>/dev/null | sed -nE 's/^yq .*version v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1
}

codex_yq_new_enough() {
    local have
    have="$(codex_yq_version)"
    [ -n "$have" ] && version_at_least "$have" "$YQ_MIN_VERSION"
}

codex_yq_too_old() {
    local version
    version="$(codex_yq_version)"
    echo "yq ${version:-on PATH} isn't mikefarah's yq $YQ_MIN_VERSION or newer, which the Codex config edit needs; run brew upgrade yq"
}

# Values of your own are kept (keepable.sh). Built when used, since tests switch the OS after
# loading. The values are TOML that is also JSON.
codex_keep_list() {
    CODEX_KEEP=(
        .model '"gpt-6.1-sol"' "Codex's model (model)"
        .model_reasoning_effort '"high"' "Codex's reasoning effort (model_reasoning_effort)"
        .tui.status_line '["model-with-reasoning", "current-dir", "git-branch", "context-used"]'
        "Codex's status line (tui.status_line)"
    )
    # Over SSH a tmux pane may lack TERM_PROGRAM, and `auto` then rings the bell; OSC 9 reaches Ghostty.
    if is_ubuntu; then
        CODEX_KEEP+=(.tui.notification_method '"osc9"' "Codex's notification method (tui.notification_method)")
    fi
}

codex_read_custom_values() {
    codex_keep_list
    read_custom_values "$(yq -p toml -o json -I=0 "$CODEX_CONFIG" 2>/dev/null)" "${CODEX_KEEP[@]}"
}

# Sets CODEX_REPLACE[k] to true for each value of your own you agree to replace
codex_choose_custom_values() {
    local k
    codex_read_custom_values
    CODEX_REPLACE=()
    for ((k = 0; k < ${#CODEX_KEEP[@]} / 3; k++)); do
        if replace_custom_value "${CODEX_KEEP[k * 3 + 2]}" "${CUSTOM_VALUES[k * 2]:-}" \
            "${CUSTOM_VALUES[k * 2 + 1]:-}"; then
            CODEX_REPLACE[k]=true
        fi
    done
}

codex_status_custom_values() {
    local k current wanted
    codex_read_custom_values
    for ((k = 0; k < ${#CODEX_KEEP[@]} / 3; k++)); do
        current="${CUSTOM_VALUES[k * 2]:-}"
        wanted="${CUSTOM_VALUES[k * 2 + 1]:-}"
        [ -z "$current" ] || [ "$current" == "$wanted" ] ||
            status_custom_value "${CODEX_KEEP[k * 3 + 2]}" "$current" "$wanted"
    done
}

# Values are TOML, which for the types used here is also a yq literal
codex_set() {
    CODEX_PATHS+=("$1")
    CODEX_VALUES+=("$2")
}

codex_settings() {
    local k
    CODEX_PATHS=()
    CODEX_VALUES=()
    codex_read_custom_values
    for ((k = 0; k < ${#CODEX_KEEP[@]} / 3; k++)); do
        if [ "${CODEX_REPLACE[k]:-}" == true ] || [ -z "${CUSTOM_VALUES[k * 2]:-}" ]; then
            codex_set "${CODEX_KEEP[k * 3]}" "${CODEX_KEEP[k * 3 + 1]}"
        fi
    done
    codex_set .model_verbosity '"low"'
    codex_set .model_reasoning_summary '"concise"'
    codex_set .approval_policy '"on-request"'
    codex_set .approvals_reviewer '"auto_review"'
    codex_set .sandbox_mode '"workspace-write"'
    codex_set .analytics.enabled 'false'
    codex_set .feedback.enabled 'false'
    if is_ubuntu; then
        # Over SSH the GNOME keyring stays locked until a desk login
        codex_set .mcp_oauth_credentials_store '"file"'
    fi

    # Bracketed: yq reads dashes as minus otherwise
    if is_macos; then
        codex_set '.desktop["git-pull-request-merge-method"]' '"squash"'
        codex_set '.desktop["worktree-upstream-refresh-mode"]' '"never"'
        codex_set '.desktop["notifications-turn-mode"]' '"unfocused"'
        codex_set '.desktop["notifications-permissions-enabled"]' 'true'
        codex_set '.desktop["notifications-questions-enabled"]' 'true'
        codex_set '.desktop["preventSleepWhileRunning"]' 'true'
        # Also stops it running after the window closes
        codex_set '.desktop["mac-menu-bar-enabled"]' 'false'
        codex_set '.desktop["keepRemoteControlAwakeWhilePluggedIn"]' 'true'
        codex_set '.desktop["followUpQueueMode"]' '"steer"'
        codex_set '.desktop["conversationDetailMode"]' '"STEPS_COMMANDS"'
        codex_set '.desktop["show-context-window-usage"]' 'true'
        codex_set '.desktop["ambient-suggestions-enabled"]' 'true'
        codex_set '.desktop["open-link-in-target-preference"]' '"external-browser"'
        codex_set '.desktop["open-local-url-in-target-preference"]' '"external-browser"'
        codex_set '.desktop["enabled-reasoning-efforts"]' \
            '["low", "medium", "high", "xhigh", "ultra", "persistent", "max"]'
    fi
}

# Usage: codex_settings_joined <separator> set|path|value
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

# Print a TOML file's full-line comments, sorted, skipping lines inside multi-line strings.
# scan returns the multi-line string a line ends inside, if any.
codex_comments() {
    awk -v dq='"""' -v sq="'''" -v q="'" '
        function scan(s, open,   i, c, d, n) {
            n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                d = substr(s, i, 3)
                if (open != "") {
                    if (open == dq && c == "\\") i++
                    else if (d == open) { open = ""; i += 2 }
                } else if (c == "#") {
                    break
                } else if (d == dq || d == sq) {
                    open = d
                    i += 2
                } else if (c == "\"") {
                    for (i++; i <= n && substr(s, i, 1) != "\""; i++) if (substr(s, i, 1) == "\\") i++
                } else if (c == q) {
                    for (i++; i <= n && substr(s, i, 1) != q; i++) ;
                }
            }
            return open
        }
        str != "" { str = scan($0, str); next }
        /^[[:space:]]*#/ { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; next }
        { str = scan($0, "") }
    ' "$1" | LC_ALL=C sort
}

# Usage: codex_comments_kept <edited> <source>
codex_comments_kept() {
    [ -z "$(LC_ALL=C comm -23 <(codex_comments "$2") <(codex_comments "$1"))" ]
}

# For merge_file: prints the config it reads on stdin with the settings set. yq can drop trailing
# comments and misplace values after top-level dotted keys or arrays of inline tables, so the edit
# is verified first.
codex_config_edit() {
    local source edited filter status=1
    codex_settings
    filter="$(codex_settings_joined ' | ' set)"
    source="$(mktemp)" || return 1
    if ! edited="$(mktemp)" || ! cat > "$source"; then
        rm -f "$source"
        return 1
    fi
    if ! yq -p toml -o toml "$filter" "$source" > "$edited" ||
        ! yq -p toml -o json '.' "$edited" > /dev/null; then
        echo "  Couldn't edit $CODEX_CONFIG with yq; is it valid TOML? Leaving it unchanged." >&2
    elif [ "$(yq -p toml -o json -I=0 "$filter | sort_keys(..)" "$source")" != \
        "$(yq -p toml -o json -I=0 'sort_keys(..)' "$edited")" ]; then
        echo "  yq would change other values in $CODEX_CONFIG while editing it; leaving it unchanged." >&2
        echo "  Write top-level dotted keys such as a.b = 1 as [a] tables, and top-level arrays of" >&2
        echo "  inline tables such as a = [{...}] as [[a]] tables, then re-run." >&2
    elif ! codex_comments_kept "$edited" "$source"; then
        echo "  yq would drop comments from $CODEX_CONFIG while editing it; leaving it unchanged." >&2
    else
        cat "$edited" && status=0
    fi
    rm -f "$source" "$edited"
    return "$status"
}

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
    codex_choose_custom_values
    local settings="model, output, sandbox, approval, data-sharing, and status line settings"
    if is_macos; then
        settings="model, output, sandbox, approval, data-sharing, status line, and desktop app settings"
    fi
    if codex_config_matches; then
        echo "  The $settings are already set in $CODEX_CONFIG"
        return 0
    fi

    # Check the edit works before asking to quit ChatGPT, which can rewrite the config as it quits,
    # so the edit is made again after
    if pgrep -ax "$(regex_escape ChatGPT)" > /dev/null 2>&1; then
        file_contents "$CODEX_CONFIG" | codex_config_edit > /dev/null || return 1
    fi
    ensure_app_quit "ChatGPT" || return 0
    merge_file "$CODEX_CONFIG" codex_config_edit || return 1
    echo "  Set the $settings in $CODEX_CONFIG"
}

user_instructions_files() {
    "$1" "$DOTFILES_DIR/ai_tools/user-instructions.md" "$CODEX_INSTRUCTIONS"
}

install_codex_cli() {
    install_cask codex "$(codex_cask_path)"
}

# Prints nothing without Homebrew's environment, rather than /bin/codex
codex_cask_path() {
    [ -z "${HOMEBREW_PREFIX:-}" ] || echo "$HOMEBREW_PREFIX/bin/codex"
}

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

codex_items() {
    items_reset
    if is_ubuntu && [ -e "$CODEX_CREDENTIALS" ]; then
        item "Codex's MCP tokens, ~/.codex/.credentials.json, readable only by you" \
            "Make ~/.codex/.credentials.json readable only by you" \
            codex_credentials_private secure_codex_credentials
    fi
}

codex_credentials_private() {
    [ "$(file_mode "$CODEX_CREDENTIALS" 2>/dev/null)" == 600 ]
}

secure_codex_credentials() {
    if ! chmod 600 "$CODEX_CREDENTIALS"; then
        echo "  Couldn't make $CODEX_CREDENTIALS readable only by you." >&2
        return 1
    fi
    echo "  Made Codex's MCP tokens, ~/.codex/.credentials.json, readable only by you"
}

bwrap_works() {
    bwrap --unshare-all --ro-bind / / /bin/true &>/dev/null
}

userns_restricted() {
    [ "$(cat "$USERNS_RESTRICT_SYSCTL" 2>/dev/null)" == "1" ]
}

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

# Per https://learn.chatgpt.com/docs/sandboxing
setup_codex_sandbox() {
    echo "Setting up Codex's sandbox..."
    local pending=() install=false
    if ! apt_installed bubblewrap; then
        install=true
        pending+=("Install bubblewrap, which Codex's sandbox runs commands in")
        # The profile loads at boot, so it may not be needed
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
        apt_install_fresh bubblewrap || return 1
    fi
    if ! bwrap_works; then
        bwrap_profile_can_fix || return 1
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
    if is_macos; then
        status_cask chatgpt /Applications/ChatGPT.app
    else
        status_item skipped "ChatGPT desktop app: macOS only"
    fi
    if status_require_cmd brew codex; then
        status_cask codex "$(codex_cask_path)"
    fi
    codex_status_signed_in
    if tool_home_guard --status "Codex settings and instructions" Codex CODEX_HOME "$CODEX_DIR"; then
        if ! status_require_cmd yq "Settings in ~/.codex/config.toml"; then
            :
        elif ! status_require_cmd jq "Settings in ~/.codex/config.toml"; then
            :
        elif ! codex_yq_new_enough; then
            status_item unknown "Settings in ~/.codex/config.toml: $(codex_yq_too_old)"
        else
            status_check "Settings in ~/.codex/config.toml" codex_config_matches
            codex_status_custom_values
        fi
        user_instructions_files status_file
        codex_items
        items_status codex_credentials_private
    fi
    if is_ubuntu; then
        status_check "Codex's sandbox: bwrap can create one" bwrap_works
    else
        status_item skipped "Codex's sandbox: macOS's built-in sandbox needs no setup"
    fi
}

apply() {
    echo "Setting up Codex..."
    tool_home_guard Codex CODEX_HOME "$CODEX_DIR" || return 1
    require_cmd yq || return 1
    require_cmd jq || return 1
    if ! codex_yq_new_enough; then
        echo "  $(codex_yq_too_old)" >&2
        return 1
    fi
    require_cmd brew || return 1
    local result=0
    if is_macos; then
        install_cask chatgpt /Applications/ChatGPT.app || result=1
    fi
    install_codex_cli || result=1
    configure_codex || result=1
    echo "  User-level instructions:"
    user_instructions_files copy_file || result=1
    if is_ubuntu; then
        codex_items
        items_apply codex_credentials_private || result=1
        setup_codex_sandbox || result=1
    fi
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
