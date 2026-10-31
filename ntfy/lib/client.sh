# shellcheck shell=bash
# The ntfy client's config and the desktop notifier, for the ntfy step, just ntfy-user, and
# just ntfy-device. Source after lib/common.sh.

# The copies of ntfy/subscribe.sh and ntfy/notify.sh the notifier runs, so it doesn't depend on the
# checkout. client.yml's default-command names notify.sh by this path.
NTFY_NOTIFIER_DIR="$HOME/.local/share/dotfiles/ntfy"
NTFY_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/ntfy"
NTFY_NOTIFY_ERROR="$NTFY_STATE_DIR/notify-error"
# The topics both machines show as notifications
NTFY_TOPICS=(alerts agenda)

# Where ntfy's client reads its config: Go's os.UserConfigDir, as ntfy publish would find it
ntfy_client_config() {
    if is_macos; then
        echo "$HOME/Library/Application Support/ntfy/client.yml"
    else
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/ntfy/client.yml"
    fi
}

ntfy_notifier_files() {
    local status=0
    "$1" "$DOTFILES_DIR/ntfy/subscribe.sh" "$NTFY_NOTIFIER_DIR/subscribe.sh" || status=1
    "$1" "$DOTFILES_DIR/ntfy/notify.sh" "$NTFY_NOTIFIER_DIR/notify.sh" || status=1
    return "$status"
}

# ntfy_client_yaml <server url> <token>: a subscription per NTFY_TOPICS topic on that server, with
# the token as default-token, which publish and the subscriptions both use. ntfy runs
# default-command through sh -c, so $HOME stays for it to expand.
ntfy_client_yaml() {
    local topic
    printf '%s\n' "# From the dotfiles ntfy step's setup script. It holds a token, so keep it mode 600." \
        "default-host: $1" "default-token: $2" \
        "# Runs once per message: notify.sh skips repeats and records where to resume" \
        "default-command: '/bin/bash \"\$HOME/.local/share/dotfiles/ntfy/notify.sh\"'" "subscribe:"
    for topic in "${NTFY_TOPICS[@]}"; do
        printf '  - topic: %s\n' "$1/$topic"
    done
}

# ntfy_client_token [file]: the default-token line's token, or nothing
ntfy_client_token() {
    local file="${1:-$(ntfy_client_config)}"
    [ -r "$file" ] || return 0
    sed -nE "s/^default-token: *($NTFY_TOKEN_RE) *$/\1/p" "$file" | head -n 1
}

ntfy_client_host() {
    local file="${1:-$(ntfy_client_config)}"
    [ -r "$file" ] || return 0
    sed -nE 's/^default-host: *([^ ]+) *$/\1/p' "$file" | head -n 1
}

# ntfy_client_ready [file]: mode 600, with a token
ntfy_client_ready() {
    local file="${1:-$(ntfy_client_config)}"
    [ -f "$file" ] && [ "$(file_mode "$file")" == 600 ] && [ -n "$(ntfy_client_token "$file")" ]
}

# write_client_config <file> <content>: mode 600 from the start, so the token is never readable by
# others, even briefly. Sets COPIED=true when it wrote.
write_client_config() {
    local file="$1" dir tmp
    if file_is "$file" "$2" && [ "$(file_mode "$file")" == 600 ]; then
        return 0
    fi
    parent_dir dir "$file"
    mkdir -p "$dir" || return 1
    tmp="$(umask 077 && mktemp "$dir/.client.yml.XXXXXX")" || return 1
    if printf '%s\n' "$2" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file"; then
        # shellcheck disable=SC2034 # the caller reads it
        COPIED=true
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Set by notify.sh when macOS refused a notification; removed after the next one shows
status_notify_error() {
    local error
    [ -e "$NTFY_NOTIFY_ERROR" ] || return 0
    error="$(head -n 1 "$NTFY_NOTIFY_ERROR" 2>/dev/null)" || error=""
    status_item missing "ntfy's desktop notifications showing: ${error:-the last one failed}"
}
