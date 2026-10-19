#!/bin/bash
set -euo pipefail

# Install the Codex CLI and the ChatGPT app, and set Codex's config and instructions.
#
# The CLI and the app share ~/.codex/config.toml. On Ubuntu, also set up Codex's sandbox.
#
# A temp HOME doesn't isolate this step. On macOS it installs the chatgpt and codex casks, and on
# Ubuntu it installs packages and loads an AppArmor profile with sudo. Test the casks in a macOS VM
# or on a spare Mac, and the Ubuntu side in an Ubuntu VM.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=../../lib/casks.sh
source "$DOTFILES_DIR/lib/casks.sh"
# shellcheck source=../lib/keepable.sh
source "$DOTFILES_DIR/ai_tools/lib/keepable.sh"
# shellcheck source=../lib/tool-home.sh
source "$DOTFILES_DIR/ai_tools/lib/tool-home.sh"
# shellcheck source=../lib/user-instructions.sh
source "$DOTFILES_DIR/ai_tools/lib/user-instructions.sh"

# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew"

CODEX_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CODEX_INSTRUCTIONS="$CODEX_DIR/AGENTS.md"
# Where Ubuntu keeps MCP OAuth tokens in plain text (mcp_oauth_credentials_store below)
CODEX_CREDENTIALS="$CODEX_DIR/.credentials.json"
# Ubuntu's apparmor package installs this profile, which loads at boot
BWRAP_PROFILE=/etc/apparmor.d/bwrap-userns-restrict
# 1 when AppArmor restricts unprivileged user namespaces
USERNS_RESTRICT_SYSCTL=/proc/sys/kernel/apparmor_restrict_unprivileged_userns

# Print yq's version, such as 4.54.1, from mikefarah's yq's "yq (...) version v4.54.1", or nothing
# for another yq
codex_yq_version() {
    yq --version 2>/dev/null | sed -nE 's/^yq .*version v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1
}

# Succeeds when yq is YQ_MIN_VERSION or newer
codex_yq_new_enough() {
    local have
    have="$(codex_yq_version)"
    [ -n "$have" ] && version_at_least "$have" "$YQ_MIN_VERSION"
}

# Print why yq is too old, and how to update it
codex_yq_too_old() {
    local version
    version="$(codex_yq_version)"
    echo "yq ${version:-on PATH} isn't mikefarah's yq $YQ_MIN_VERSION or newer, which the Codex config edit needs; run brew upgrade yq"
}

# Settings you may keep your own values of (ai_tools/lib/keepable.sh), each with a yq path and
# the repo's value as TOML (see codex_set)
# Usage: codex_keepable <yq path> <TOML value> <name> [ubuntu]
codex_keepable() {
    keepable codex "$1" "$2" "Codex's $3" "${4:-}"
}
# The default model and high reasoning effort, which /model changes
keepable_forget codex
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

# Print the config's value at yq path $1 as one line of JSON, without a string's quotes, or
# nothing when it's unset or the config can't be read
codex_keep_current() {
    local value
    value="$(yq -p toml -o json -I=0 "$1" "$CODEX_CONFIG" 2>/dev/null)" || return 0
    [ "$value" == null ] || keepable_unquote "$value"
}

# Print a TOML value as codex_keep_current prints it
codex_keep_wanted() {
    keepable_unquote "$(printf 'v = %s\n' "$1" | yq -p toml -o json -I=0 '.v')"
}

# Print the config's value at each yq path given, one line each, as codex_keep_current does, with
# one yq. Each value is one line of JSON, so the lines line up with the paths.
codex_keep_current_all() {
    local filter values value
    filter="$(printf '%s, ' "$@")"
    values="$(yq -p toml -o json -I=0 "[${filter%, }] | .[]" "$CODEX_CONFIG" 2>/dev/null)" || return 0
    while IFS= read -r value; do
        if [ "$value" == null ]; then echo; else keepable_unquote "$value"; fi
    done <<< "$values"
}

# Print each TOML value given, one line each, as codex_keep_wanted does, with one yq
codex_keep_wanted_all() {
    local i=0 toml="" filter="" value
    for value; do
        toml+="v$i = $value"$'\n'
        filter+="${filter:+, }.v$i"
        i=$((i + 1))
    done
    printf '%s' "$toml" | yq -p toml -o json -I=0 "[$filter] | .[]" | while IFS= read -r value; do
        keepable_unquote "$value"
    done
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
    for i in $(keepable_indexes codex); do
        if "${KEEP_REPLACE[i]}" || [ -z "$(keepable_current codex "$i")" ]; then
            codex_set "${KEEP_PATHS[i]}" "${KEEP_VALUES[i]}"
        fi
    done
    codex_set .model_verbosity '"low"'
    codex_set .model_reasoning_summary '"concise"'
    # Edit and run commands in the workspace without network access. Anything else, including
    # network access, goes to the auto-review agent instead of asking you.
    codex_set .approval_policy '"on-request"'
    codex_set .approvals_reviewer '"auto_review"'
    # Codex's built-in workspace-write sandbox, which keeps the network off unless
    # [sandbox_workspace_write] turns it on. Your settings there stay.
    codex_set .sandbox_mode '"workspace-write"'
    # No usage metrics or product events (CLI and desktop app), and no /feedback log uploads
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
        # Settings → Git → Pull request merge method → Squash
        codex_set '.desktop["git-pull-request-merge-method"]' '"squash"'
        codex_set '.desktop["worktree-upstream-refresh-mode"]' '"never"'
        # Settings → Notifications
        codex_set '.desktop["notifications-turn-mode"]' '"unfocused"'
        codex_set '.desktop["notifications-permissions-enabled"]' 'true'
        codex_set '.desktop["notifications-questions-enabled"]' 'true'
        # Settings → General → Prevent sleep while running
        codex_set '.desktop["preventSleepWhileRunning"]' 'true'
        # Settings → General → Show in menu bar (keeps ChatGPT in the menu bar, and
        # running, after the main window is closed)
        codex_set '.desktop["mac-menu-bar-enabled"]' 'false'
        # Settings → Connections → Keep this Mac awake (plugged in, remote access on)
        codex_set '.desktop["keepRemoteControlAwakeWhilePluggedIn"]' 'true'
        # A message sent mid-turn steers the running turn instead of queueing
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

# Print a TOML file's full-line comments, trimmed and sorted. Lines inside a multi-line string
# aren't comments, even when they start with #. scan walks a line from the multi-line string it
# starts in, if any, and returns the one it ends in, so a """ or ''' inside a one-line string or
# a comment opens none.
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

# Succeeds when the edited copy, given first, still has every full-line comment of the source
codex_comments_kept() {
    [ -z "$(LC_ALL=C comm -23 <(codex_comments "$2") <(codex_comments "$1"))" ]
}

# Add the comments and blank lines after the source's last key back into the edited copy, given
# first. They go at the end of the last table in the copy that the source has too, so a
# commented-out key stays under the table it was written in. yq may put a table the edit added
# before or after that one, such as a new [tui] above [tui.x], and rewrites headers, such as
# [ "tui" ] # note to [tui], so headers are compared by their table path.
codex_add_tail() {
    local edited="$1" tmp
    tmp="$(mktemp)" || return 1
    awk -v source="$2" -v q="'" '
        # A header as yq writes it: no spaces or trailing comment, and quotes only where needed
        function path(s,   key) {
            sub(/^[[:space:]]+/, "", s)
            sub(/\][[:space:]]*#.*$/, "]", s)
            sub(/[[:space:]]+$/, "", s)
            gsub(/[[:space:]]*\.[[:space:]]*/, ".", s)
            gsub(/\[[[:space:]]+/, "[", s)
            gsub(/[[:space:]]+\]/, "]", s)
            while (match(s, q "[^" q "\"\\\\]*" q)) {
                s = substr(s, 1, RSTART - 1) "\"" substr(s, RSTART + 1, RLENGTH - 2) "\"" \
                    substr(s, RSTART + RLENGTH)
            }
            while (match(s, /"[A-Za-z0-9_-]+"/)) {
                s = substr(s, 1, RSTART - 1) substr(s, RSTART + 1, RLENGTH - 2) \
                    substr(s, RSTART + RLENGTH)
            }
            return s
        }
        FILENAME == source {
            if (/^[[:space:]]*\[/) header[path($0)] = 1
            if (/^[[:space:]]*(#|$)/) tail = tail $0 "\n"; else tail = ""
            next
        }
        # First pass over the copy: find the header that ends the last table the source has
        FNR == 1 { pass++ }
        pass == 1 {
            if (/^\[/) {
                if (path($0) in header) { at = 0; last = FNR }
                else if (!at) at = FNR
            }
            next
        }
        FNR == at {
            # The edit already left a blank line above this table
            sub(/^\n+/, "", tail)
            if (tail != "") printf "%s\n", tail
        }
        { print }
        END { if (!at) printf "%s", tail }
    ' "$2" "$edited" "$edited" > "$tmp" && mv "$tmp" "$edited"
}

# Write a copy of the Codex config with the settings applied, and print its path. yq rewrites the
# whole file: values and full-line comments stay, but end-of-line comments may move or go,
# multi-line strings become one-line strings with \n, and dotted keys such as profile.fast = {...}
# may become tables. yq 4.54.1 drops the comments after the last key, such as a commented-out
# table at the end, so they're added back, and the copy must keep every full-line comment the
# source has. It also moves values in two shapes, a top-level inline table after a top-level dotted
# key, and top-level keys after a top-level array of inline tables, so the copy is checked against
# the edit's own result before use.
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
    if ! codex_comments_kept "$edited" "$source" && ! codex_add_tail "$edited" "$source"; then
        rm -f "$edited"
        return 1
    fi
    if ! codex_comments_kept "$edited" "$source"; then
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

# Read the values you can change once for each phase, then forget them, since the config changes
# under them: once here, and again once ChatGPT quits, since it can save the config as it quits
configure_codex() {
    local result=0
    keepable_load codex
    configure_codex_settings || result=$?
    keepable_unload
    return "$result"
}

configure_codex_settings() {
    echo "Configuring Codex..."
    local edited
    keepable_choose codex
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
    keepable_load codex
    edited="$(codex_config_edited)" || return 1
    if ! maybe_backup "$CODEX_CONFIG"; then
        rm -f "$edited"
        return 1
    fi
    mkdir -p "$(dirname "$CODEX_CONFIG")" || { rm -f "$edited"; return 1; }
    write_back "$edited" "$CODEX_CONFIG" || return 1
    echo "  Set the $settings in $CODEX_CONFIG"
}

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

# The step's items. Only Ubuntu keeps the MCP tokens in a file, and there's nothing to say of them
# before there are any.
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
        elif ! codex_yq_new_enough; then
            status_item unknown "Settings in ~/.codex/config.toml: $(codex_yq_too_old)"
        else
            keepable_load codex
            status_check "Settings in ~/.codex/config.toml" codex_config_matches
            keepable_status codex
            keepable_unload
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
    status_result
}

apply() {
    echo "Setting up Codex..."
    tool_home_guard Codex CODEX_HOME "$CODEX_DIR" || return 1
    require_cmd yq || return 1
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
    install_user_instructions "$CODEX_INSTRUCTIONS" || result=1
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
