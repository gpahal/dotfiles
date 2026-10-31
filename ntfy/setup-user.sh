#!/bin/bash
set -euo pipefail

# Create ntfy's users and tokens, save this machine's token, and send the alerts to ntfy.
# Your user, named for your login, signs in with a password on the phone and the web app. machine
# reads and sends on every topic, with a token for each place that uses it: desktop, macbook, and
# web-service. ntfy keeps tokens readable, so a second run prints them again and changes nothing.
# Passwords go to ntfy on its terminal prompt or a pipe, never as an argument or in the environment.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=../lib/systemd.sh
source "$DOTFILES_DIR/lib/systemd.sh"
# shellcheck source=../ubuntu/lib/paths.sh
source "$DOTFILES_DIR/ubuntu/lib/paths.sh"
# shellcheck source=lib/server.sh
source "$DOTFILES_DIR/ntfy/lib/server.sh"
# shellcheck source=lib/client.sh
source "$DOTFILES_DIR/ntfy/lib/client.sh"

NTFY_ADMIN="$CURRENT_USER"
NTFY_NOTIFIER_UNIT_NAME=dotfiles-ntfy-notify.service
SETUP_ALERTS="$DOTFILES_DIR/ubuntu/setup-alerts.sh"
# ensure_tokens sets them
TOKEN_desktop="" TOKEN_macbook="" TOKEN_web_service=""

usage() {
    echo "Usage: bash ntfy/setup-user.sh [--rotate <label> | --change-pass] (or: just ntfy-user ...)"
    echo "Creates ntfy's users: $NTFY_ADMIN, who signs in with a password on the phone and web app,"
    echo "and $NTFY_MACHINE_USER, who reads and sends on every topic with a token per place:"
    echo "${NTFY_TOKEN_LABELS[*]}. Saves this machine's token in $(ntfy_client_config), sends the"
    echo "alerts to the server (just alerts), and prints the macbook and web-service tokens. A second"
    echo "run changes nothing and prints them again."
    echo "  --rotate <label>  Replace one of machine's tokens; the old one stops working."
    echo "  --change-pass     Change $NTFY_ADMIN's password, and sign out the web app's sessions."
    echo "Ubuntu only, on the machine running the ntfy step's server."
}

# As the ntfy user, who owns the user database. --config goes before the subcommand, so a missing
# server.yml fails rather than running without its auth-file. Either variable would override the
# password ntfy reads, so neither reaches it.
ntfy_cli() {
    local command="$1"
    shift
    sudo -u ntfy env -u NTFY_PASSWORD -u NTFY_PASSWORD_HASH ntfy "$command" --config "$NTFY_CONFIG" "$@"
}

# ntfy_user_exists <name>: 0 when it exists, 1 when it doesn't, 2 when ntfy couldn't say
ntfy_user_exists() {
    local err
    err="$(ntfy_cli access "$1" 2>&1 > /dev/null)" && return 0
    case "$err" in
        *"does not exist"*) return 1 ;;
    esac
    echo "  Couldn't ask ntfy about the user $1: $err" >&2
    return 2
}

ensure_admin() {
    local status=0
    ntfy_user_exists "$NTFY_ADMIN" || status=$?
    case "$status" in
        0) return 0 ;;
        2) return 1 ;;
    esac
    echo "  Choose a password for $NTFY_ADMIN, which the Android app and the web app sign in with."
    echo "  Keep it in your password manager: ntfy keeps only its hash."
    ntfy_cli user add --role=admin "$NTFY_ADMIN" || return 1
}

# A password nobody uses, since machine signs in with tokens. Piped, so it's in no argument.
ensure_machine_user() {
    local status=0 password
    ntfy_user_exists "$NTFY_MACHINE_USER" || status=$?
    case "$status" in
        0) return 0 ;;
        2) return 1 ;;
    esac
    password="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')" || return 1
    printf '%s\n%s\n' "$password" "$password" | ntfy_cli user add "$NTFY_MACHINE_USER" > /dev/null || return 1
    echo "  Added the user $NTFY_MACHINE_USER."
}

# Granting is an upsert, but checking first keeps a second run from running anything
ensure_access() {
    local listing grant="- read-write access to topic *" others
    listing="$(ntfy_cli access "$NTFY_MACHINE_USER")" || return 1
    if ! grep -qxF -- "$grant" <<< "$listing"; then
        ntfy_cli access "$NTFY_MACHINE_USER" '*' read-write > /dev/null || return 1
        echo "  Let $NTFY_MACHINE_USER read and send on every topic."
    fi
    others="$(grep '^- ' <<< "$listing" | grep -vxF -e "$grant" -e "- no topic-specific permissions" || true)"
    [ -z "$others" ] || printf '  %s also has, from before:\n    %s\n' "$NTFY_MACHINE_USER" "${others//$'\n'/$'\n'    }"
}

# machine_token <label>: the token with that label, or nothing. token list prints
# "- tk_... (label), never expires, ..."; a label may hold commas, so this doesn't split on them.
machine_token() {
    local listing
    listing="$(ntfy_cli token list "$NTFY_MACHINE_USER")" || return 1
    sed -nE "s/^- ($NTFY_TOKEN_RE) \\($1\\),.*/\\1/p" <<< "$listing" | head -n 1
}

# token add prints "token tk_... created for user machine, never expires"
add_machine_token() {
    ntfy_cli token add --label="$1" "$NTFY_MACHINE_USER" | awk '$1 == "token" { print $2; exit }'
}

# Sets TOKEN_<label>, with - as _, for each label
ensure_tokens() {
    local label token
    for label in "${NTFY_TOKEN_LABELS[@]}"; do
        token="$(machine_token "$label")" || return 1
        if [ -z "$token" ]; then
            token="$(add_machine_token "$label")" || return 1
            [ -n "$token" ] || { echo "  ntfy didn't print the new $label token." >&2; return 1; }
            echo "  Made the $label token."
        fi
        printf -v "TOKEN_${label//-/_}" '%s' "$token"
    done
}

# This machine publishes and subscribes over loopback, so neither depends on Tailscale
save_client_config() {
    local COPIED=false
    write_client_config "$(ntfy_client_config)" "$(ntfy_client_yaml "$NTFY_LOCAL_URL" "$TOKEN_desktop")" || return 1
    if "$COPIED"; then
        echo "  Saved this machine's token in $(shown_path "$(ntfy_client_config)")."
        if unit_active --user "$NTFY_NOTIFIER_UNIT_NAME"; then
            systemctl --user restart "$NTFY_NOTIFIER_UNIT_NAME" || return 1
            echo "  Restarted ntfy's desktop notifier."
        fi
    fi
}

print_tokens() {
    local url
    url="$(ntfy_public_url)" || url="https://<this machine's tailnet name>:$NTFY_FUNNEL_PORT"
    echo
    echo "ntfy's server: $url"
    echo "  Android: in the ntfy app, add $NTFY_ADMIN and your password for $url (Settings → Manage"
    echo "  users), then add the alerts and agenda topics on that server; just alerts shows the steps."
    echo
    echo "  macbook token, for just ntfy-device on the Mac:"
    echo "    $TOKEN_macbook"
    echo "  web-service token, for your web service:"
    echo "    $TOKEN_web_service"
    echo "  Send:  curl -H \"Authorization: Bearer <token>\" -H \"Title: Standup\" -d \"In 10 minutes\" $url/agenda"
    echo "  Read:  curl -H \"Authorization: Bearer <token>\" \"$url/agenda/json?poll=1&since=72h\""
    echo
    echo "  Keep both tokens in your password manager. just ntfy-user prints them again."
}

# The desktop token also goes to the alerts, which just alerts asks to save
setup_all() {
    ensure_admin || return 1
    ensure_machine_user || return 1
    ensure_access || return 1
    ensure_tokens || return 1
    save_client_config || return 1
    bash "$SETUP_ALERTS" || return 1
    print_tokens
}

rotate() {
    local label="$1" old new found=false known
    for known in "${NTFY_TOKEN_LABELS[@]}"; do
        [ "$known" != "$label" ] || found=true
    done
    if ! "$found"; then
        echo "No token is labeled $label. The labels are: ${NTFY_TOKEN_LABELS[*]}." >&2
        return 2
    fi
    old="$(machine_token "$label")" || return 1
    new="$(add_machine_token "$label")" || return 1
    [ -n "$new" ] || { echo "  ntfy didn't print the new $label token." >&2; return 1; }
    if [ -n "$old" ]; then
        ntfy_cli token remove "$NTFY_MACHINE_USER" "$old" > /dev/null || return 1
    fi
    echo "  Replaced the $label token; the old one no longer works."
    case "$label" in
        desktop)
            ensure_tokens && save_client_config && bash "$SETUP_ALERTS"
            ;;
        macbook)
            echo "  Run just ntfy-device on the Mac and paste the new token:"
            echo "    $new"
            ;;
        web-service)
            echo "  Give your web service the new token:"
            echo "    $new"
            ;;
    esac
}

# A password change leaves the user's tokens valid, and each web app login is one, so they go too.
# Your user holds no others.
change_pass() {
    local listing token
    echo "  Choose a new password for $NTFY_ADMIN."
    ntfy_cli user change-pass "$NTFY_ADMIN" || return 1
    listing="$(ntfy_cli token list "$NTFY_ADMIN" 2> /dev/null)" || listing=""
    while IFS= read -r token; do
        [ -z "$token" ] || ntfy_cli token remove "$NTFY_ADMIN" "$token" < /dev/null > /dev/null || return 1
    done <<< "$(sed -nE "s/^- ($NTFY_TOKEN_RE)[ ,].*/\\1/p" <<< "$listing")"
    echo "  Changed it, and signed out the web app's sessions. Update the password in the Android app"
    echo "  (Settings → Manage users)."
}

main() {
    case "$#:${1:-}" in
        1:-h | 1:--help)
            usage
            return 0
            ;;
        0: | 1:--change-pass) ;;
        2:--rotate) ;;
        *)
            usage >&2
            return 2
            ;;
    esac
    if ! is_ubuntu; then
        echo "ntfy's server runs on the Ubuntu machine; run just ntfy-user there. On a Mac, run just ntfy-device." >&2
        return 1
    fi
    require_cmd ntfy || return 1
    require_cmd jq || return 1
    require_cmd curl || return 1
    if [ ! -e "$NTFY_CONFIG" ] || ! ntfy_healthy; then
        echo "ntfy's server isn't running here. Run bash setup.sh ntfy first." >&2
        return 1
    fi
    if ! is_interactive; then
        echo "Run just ntfy-user from a terminal: it asks for sudo, and the first time for a password." >&2
        return 1
    fi
    # One prompt up front, so sudo doesn't ask in the middle of ntfy's own prompts
    sudo -v || return 1
    case "${1:-}" in
        --rotate) rotate "$2" ;;
        --change-pass) change_pass ;;
        *) setup_all ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
