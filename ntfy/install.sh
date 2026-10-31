#!/bin/bash
set -euo pipefail

# Run a private ntfy server on Tailscale Funnel, and show its messages as notifications.
# On Ubuntu it installs and starts the server with sudo, and publishes it with tailscale funnel,
# whatever HOME is: test it in an Ubuntu VM with systemd. On macOS it sets up only the notifier, a
# LaunchAgent, which a temp HOME doesn't load. The users, tokens, and client configs come from
# just ntfy-user (ntfy/setup-user.sh) and just ntfy-device (ntfy/setup-device.sh).

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$DOTFILES_DIR/lib/system.sh"
# shellcheck source=../lib/systemd.sh
source "$DOTFILES_DIR/lib/systemd.sh"
# shellcheck source=../lib/gnome.sh
source "$DOTFILES_DIR/lib/gnome.sh"
# shellcheck source=../ubuntu/lib/paths.sh
source "$DOTFILES_DIR/ubuntu/lib/paths.sh"
# shellcheck source=lib/server.sh
source "$DOTFILES_DIR/ntfy/lib/server.sh"
# shellcheck source=lib/client.sh
source "$DOTFILES_DIR/ntfy/lib/client.sh"

# macOS needs homebrew (ntfy and terminal-notifier); Ubuntu needs the ubuntu step's Tailscale too
# shellcheck disable=SC2034 # run_steps reads it
STEP_NEEDS="homebrew ubuntu"

NTFY_REPO=https://archive.ntfy.sh/apt
NTFY_KEY_URL="$NTFY_REPO/keyring.gpg"
NTFY_KEYRING=/etc/apt/keyrings/ntfy.gpg
# Published in ntfy's install docs; the key's UID: "ntfy LLC <ntfy@heckel.io>"
NTFY_KEY_FPR=55BA774A6F5EE67431E4B6B7CFDB962D4F1EC4AF
NTFY_SOURCES=/etc/apt/sources.list.d/ntfy.sources
NTFY_PIN=/etc/apt/preferences.d/dotfiles-ntfy
# Ubuntu Pro pins its esm-apps repo, which carries Ubuntu's older ntfy, at 510, above every other
# repo. The pin matches the repo's host, since its Release file names no origin.
NTFY_PIN_CONTENT='Explanation: From the dotfiles ntfy step: take ntfy from ntfy'"'"'s repo, not Ubuntu'"'"'s older one
Package: ntfy
Pin: origin archive.ntfy.sh
Pin-Priority: 600'
# The Release file's origin and label are aptly's placeholders, so this matches the site
NTFY_UNATTENDED_CONF=/etc/apt/apt.conf.d/52dotfiles-ntfy
NTFY_UNATTENDED_CONTENT='// From the dotfiles ntfy step: install ntfy updates with the daily security updates
Unattended-Upgrade::Origins-Pattern { "site=archive.ntfy.sh"; };'
NTFY_DROP_IN=/etc/systemd/system/ntfy.service.d/dotfiles.conf
NTFY_NOTIFIER_UNIT_NAME=dotfiles-ntfy-notify.service
# Not XDG_CONFIG_HOME: the systemd user manager doesn't read the shell's
NTFY_NOTIFIER_UNIT="$HOME/.config/systemd/user/$NTFY_NOTIFIER_UNIT_NAME"
NTFY_AGENT_LABEL=dotfiles.ntfy-subscribe
NTFY_AGENT="$HOME/Library/LaunchAgents/$NTFY_AGENT_LABEL.plist"

# The repo serves one suite, stable, for every Ubuntu release
ntfy_sources() {
    printf '%s\n' "Types: deb" "URIs: $NTFY_REPO" "Suites: stable" "Components: main" \
        "Architectures: $(dpkg --print-architecture)" "Signed-By: $NTFY_KEYRING"
}

ntfy_source_ok() {
    file_is "$NTFY_SOURCES" "$(ntfy_sources)"
}

ntfy_pinned() {
    file_is "$NTFY_PIN" "$NTFY_PIN_CONTENT"
}

# apt-cache policy marks the installed version with ***, and lists the repos that carry it below it
ntfy_from_repo() {
    apt-cache policy ntfy 2>/dev/null | awk -v repo="$NTFY_REPO" '
        $1 == "***" { installed = 1; next }
        NF == 2 && $2 ~ /^-?[0-9]+$/ { installed = 0; next }
        installed && $2 == repo { found = 1 }
        END { exit !found }'
}

ntfy_installed() {
    apt_installed ntfy && ntfy_source_ok && ntfy_from_repo
}

# The pin makes apt replace Ubuntu's ntfy with this repo's. Runs where set -e is off: each command
# checks its own failure.
install_ntfy() {
    add_apt_repo ntfy "$NTFY_SOURCES" "$(ntfy_sources)" "$NTFY_KEY_URL" "$NTFY_KEYRING" "$NTFY_KEY_FPR" ||
        return 1
    if ! apt_get_update; then
        echo "  apt-get update failed; it may not be ntfy's source. Fix the error above and re-run." >&2
        return 1
    fi
    apt_get install -y ntfy
}

ntfy_config_current() {
    cmp -s "$DOTFILES_DIR/ntfy/server.yml" "$NTFY_CONFIG"
}

# Nothing in it is secret, so it stays readable for status
install_ntfy_config() {
    install_root_file "$DOTFILES_DIR/ntfy/server.yml" "$NTFY_CONFIG" 0644 && NTFY_RESTART=true
}

# ProtectSystem and PrivateTmp are what ntfy's unit leaves for later; the server writes only its
# cache and user database. systemd creates those directories if the package didn't, and keeps them
# private, since the user database holds the tokens.
ntfy_drop_in() {
    local url
    url="$(ntfy_public_url)" || return 1
    printf '%s\n' "# From the dotfiles ntfy step: this machine's public URL, and sandboxing ntfy's unit leaves out" \
        "[Service]" "Environment=NTFY_BASE_URL=$url" "ProtectSystem=strict" \
        "StateDirectory=ntfy" "StateDirectoryMode=0700" "CacheDirectory=ntfy" "CacheDirectoryMode=0700" "PrivateTmp=true" "NoNewPrivileges=true"
}

ntfy_drop_in_current() {
    local content
    content="$(ntfy_drop_in)" && file_is "$NTFY_DROP_IN" "$content"
}

install_ntfy_drop_in() {
    local content
    content="$(ntfy_drop_in)" || return 1
    write_root_file "$NTFY_DROP_IN" "$content" 0644 && sudo systemctl daemon-reload && NTFY_RESTART=true
}

ntfy_on() {
    unit_on "$NTFY_UNIT"
}

ntfy_auto_updates_configured() {
    file_is "$NTFY_UNATTENDED_CONF" "$NTFY_UNATTENDED_CONTENT"
}

# The serve config proxies <name>:8443 to ntfy, and Funnel publishes it. tailscale stores the target
# as given, so it's always passed as $NTFY_LOCAL_URL.
ntfy_funnel_on() {
    local host config
    host="$(ntfy_host)" || return 1
    config="$(tailscale funnel status --json 2>/dev/null)" || return 1
    jq -e --arg hp "$host:$NTFY_FUNNEL_PORT" --arg target "$NTFY_LOCAL_URL" \
        '.AllowFunnel[$hp] == true and .Web[$hp].Handlers["/"].Proxy == $target' <<< "$config" &>/dev/null
}

# Only once the server runs, so the public port never answers with an error page. Never reset:
# that would also drop other serve entries, such as T3 Code's.
publish_ntfy_funnel() {
    if ! unit_active "$NTFY_UNIT"; then
        echo "  ntfy isn't running, so it isn't published on Tailscale Funnel yet."
        return 0
    fi
    tailscale funnel --bg --yes --https="$NTFY_FUNNEL_PORT" "$NTFY_LOCAL_URL" > /dev/null
}

ntfy_capabilities() {
    tailscale_cap https && tailscale_cap funnel
}

ntfy_items() {
    items_reset
    item --sudo "ntfy taken from ntfy's apt repo ($NTFY_PIN)" "Let apt take ntfy from ntfy's apt repo: write $NTFY_PIN" \
        ntfy_pinned "write_root_content NTFY_PIN NTFY_PIN_CONTENT 0644"
    item --sudo "ntfy from ntfy's apt repo" "Install ntfy from ntfy's apt repo ($NTFY_REPO)" \
        ntfy_installed install_ntfy
    item --sudo "ntfy's server config ($NTFY_CONFIG)" "Write ntfy's server config, private and on loopback only: $NTFY_CONFIG" \
        ntfy_config_current install_ntfy_config
    item --sudo "ntfy's systemd drop-in, with the public URL and sandboxing ($NTFY_DROP_IN)" \
        "Give ntfy its public URL and sandbox it: write $NTFY_DROP_IN" ntfy_drop_in_current install_ntfy_drop_in
    item --sudo "ntfy starts at boot and is running (ntfy.service)" "Start ntfy now and at boot: enable --now ntfy.service" \
        ntfy_on "enable_units_now $NTFY_UNIT"
    item --sudo "ntfy origins allowed in unattended-upgrades ($NTFY_UNATTENDED_CONF)" \
        "Let unattended-upgrades install ntfy updates: write $NTFY_UNATTENDED_CONF" \
        ntfy_auto_updates_configured "write_root_content NTFY_UNATTENDED_CONF NTFY_UNATTENDED_CONTENT"
    if ntfy_capabilities; then
        item "ntfy published on Tailscale Funnel ($(ntfy_public_url))" \
            "Publish ntfy on Tailscale Funnel: tailscale funnel --bg --https=$NTFY_FUNNEL_PORT $NTFY_LOCAL_URL" \
            ntfy_funnel_on publish_ntfy_funnel
    fi
}

# The user unit runs the copy of subscribe.sh. It needs a desktop session for notify-send.
ntfy_notifier_unit() {
    printf '%s\n' "# From the dotfiles ntfy step: show ntfy's alerts and agenda as desktop notifications" \
        "[Unit]" "Description=Show ntfy's messages as desktop notifications" \
        "PartOf=graphical-session.target" "After=graphical-session.target" "" \
        "[Service]" "ExecStart=/bin/bash $(systemd_quote "$NTFY_NOTIFIER_DIR/subscribe.sh")" \
        "Restart=always" "RestartSec=10" "" \
        "[Install]" "WantedBy=graphical-session.target"
}

ntfy_agent_files() {
    is_macos || return 0
    "$1" "$DOTFILES_DIR/ntfy/$NTFY_AGENT_LABEL.plist" "$NTFY_AGENT"
}

setup_ubuntu_notifier() {
    local COPIED=false changed=false
    ntfy_notifier_files copy_file || return 1
    "$COPIED" && changed=true
    user_manager_reachable "ntfy's desktop notifier isn't on" || return 0
    if ! file_is "$NTFY_NOTIFIER_UNIT" "$(ntfy_notifier_unit)"; then
        mkdir -p "$(dirname "$NTFY_NOTIFIER_UNIT")" && write_content "$NTFY_NOTIFIER_UNIT" "$(ntfy_notifier_unit)" ||
            return 1
        changed=true
    fi
    start_user_service "$NTFY_NOTIFIER_UNIT_NAME" "ntfy's desktop notifier" "$changed"
}

ntfy_agent_loaded() {
    launchctl print "gui/$(id -u)/$NTFY_AGENT_LABEL" &>/dev/null
}

setup_macos_notifier() {
    local COPIED=false changed=false
    ntfy_notifier_files copy_file || return 1
    ntfy_agent_files copy_file || return 1
    "$COPIED" && changed=true
    if ntfy_agent_loaded; then
        if "$changed"; then
            launchctl kickstart -k "gui/$(id -u)/$NTFY_AGENT_LABEL" || return 1
            echo "  Restarted the $NTFY_AGENT_LABEL LaunchAgent."
        else
            echo "  The $NTFY_AGENT_LABEL LaunchAgent is already loaded."
        fi
    elif ! home_is_real; then
        echo "  HOME isn't your home directory, so the $NTFY_AGENT_LABEL LaunchAgent isn't loaded. Load it with:"
        echo "    launchctl bootstrap gui/$(id -u) $NTFY_AGENT"
    elif launchctl bootstrap "gui/$(id -u)" "$NTFY_AGENT"; then
        echo "  Loaded the $NTFY_AGENT_LABEL LaunchAgent, which shows ntfy's messages as notifications."
    else
        echo "  Couldn't load the $NTFY_AGENT_LABEL LaunchAgent." >&2
        return 1
    fi
    ntfy_client_ready || echo "  It shows notifications once just ntfy-device saves this Mac's token."
}

# For just upgrade: ntfy subscribe keeps running the old ntfy until it restarts. The notifier
# resumes from the last message it showed, so a restart loses and repeats nothing.
restart_ntfy_notifier() {
    if is_macos; then
        ntfy_agent_loaded || return 0
        launchctl kickstart -k "gui/$(id -u)/$NTFY_AGENT_LABEL" || return 1
    else
        unit_active --user "$NTFY_NOTIFIER_UNIT_NAME" || return 0
        systemctl --user restart "$NTFY_NOTIFIER_UNIT_NAME" || return 1
    fi
    echo "Restarted ntfy's notifier, so it runs the upgraded ntfy."
}

apply_macos() {
    echo "Setting up ntfy's desktop notifications..."
    require_cmd ntfy || return 1
    require_cmd terminal-notifier || return 1
    setup_macos_notifier
}

apply_ubuntu() {
    local result=0 was_active=false NTFY_RESTART=false MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    echo "Setting up the ntfy server..."
    require_cmd tailscale || return 1
    require_cmd jq || return 1
    require_cmd curl || return 1
    # add_apt_repo needs it
    require_cmd gpg || return 1
    # Cached for the checks below, which ask inside $( )
    ntfy_tailscale_status > /dev/null || true
    if [ "$(ntfy_tailscale_status | jq -r '.BackendState // empty' 2>/dev/null)" != Running ]; then
        echo "  Tailscale isn't connected. Run sudo tailscale up, then bash setup.sh ntfy." >&2
        return 1
    fi
    if ! ntfy_host > /dev/null; then
        echo "  This machine has no MagicDNS name. Turn on MagicDNS in the Tailscale admin console's DNS" >&2
        echo "  page, then re-run bash setup.sh ntfy." >&2
        return 1
    fi
    unit_active "$NTFY_UNIT" && was_active=true
    ntfy_items
    items_apply_confirmed --done "  ntfy is already installed, configured, and published." || result=1
    if "$NTFY_RESTART" && "$was_active"; then
        sudo systemctl restart "$NTFY_UNIT" || result=1
        echo "  Restarted ntfy for its new config."
    fi
    if unit_active "$NTFY_UNIT" && ! ntfy_wait_healthy; then
        echo "  ntfy is running but doesn't answer on $NTFY_LOCAL_URL; journalctl -u ntfy says why." >&2
        result=1
    fi
    setup_ubuntu_notifier || result=1
    if ! ntfy_capabilities; then
        echo "  The tailnet doesn't let this machine use Tailscale Funnel yet, so ntfy isn't public. In the" >&2
        echo "  admin console, turn on HTTPS certificates (DNS page) and give it the funnel nodeAttr, then" >&2
        echo "  re-run bash setup.sh ntfy." >&2
        result=1
    elif unit_active "$NTFY_UNIT" && ! ntfy_client_ready; then
        echo "  Next: run just ntfy-user to create your user and the machines' tokens."
    fi
    return "$result"
}

apply() {
    if is_macos; then
        apply_macos
    else
        apply_ubuntu
    fi
}

# Status reads, and never posts: a POST to sign-up would create an account if sign-up were open
status_ntfy_access() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "$NTFY_LOCAL_URL/dotfiles-status-probe/json?poll=1" 2>/dev/null)" || code=""
    case "$code" in
        401 | 403) status_item ok "ntfy refuses anyone without a password or token (auth-default-access: deny-all)" ;;
        '' | 000) status_item unknown "ntfy refusing anyone without a password or token: no answer from $NTFY_LOCAL_URL" ;;
        *) status_item missing "ntfy refusing anyone without a password or token: an anonymous read got $code; check auth-default-access in $NTFY_CONFIG" ;;
    esac
    if curl -fsS --max-time 5 "$NTFY_LOCAL_URL/v1/config" 2>/dev/null | jq -e '.enable_signup == false' &>/dev/null; then
        status_item ok "ntfy's sign-up off"
    else
        status_item missing "ntfy's sign-up off: $NTFY_LOCAL_URL/v1/config doesn't say enable_signup is false; check $NTFY_CONFIG"
    fi
}

# Through Cloudflare's DNS-over-HTTPS, since MagicDNS answers this machine's name with its tailnet IP
status_ntfy_public_dns() {
    local label="ntfy's public name resolves on the internet" host answer
    if status_for_alerts; then
        status_item unverified "$label: skipped by --for-alerts"
        return 0
    fi
    host="$(ntfy_host)" || return 0
    answer="$(curl -fsS --max-time 10 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$host&type=A" 2>/dev/null)" || answer=""
    if [ -z "$answer" ]; then
        status_item unknown "$label: couldn't ask a public resolver"
    elif jq -e '(.Answer // []) | length > 0' <<< "$answer" &>/dev/null; then
        status_item ok "$label ($host)"
    else
        status_item missing "$label: $host has no public address yet; Funnel's DNS can take 10 minutes"
    fi
}

status_ubuntu() {
    local installed=false MEMO_SCOPE="${MEMO_SCOPE:-$((MEMO_SEQ += 1))}"
    status_require_cmd tailscale "Tailscale, which publishes ntfy" || return 0
    # Cached for the checks below, which ask inside $( )
    ntfy_tailscale_status > /dev/null || true
    if ! ntfy_host > /dev/null; then
        status_item missing "This machine's MagicDNS name: turn on MagicDNS in the Tailscale admin console, and connect with sudo tailscale up"
        return 0
    fi
    apt_installed ntfy && installed=true
    ntfy_items
    items_status
    ! "$installed" || status_apt_source ntfy "$NTFY_SOURCES" "$(ntfy_sources)" ntfy "$NTFY_REPO/dists/stable/Release"
    status_check "HTTPS certificates on for this machine (Tailscale admin console, DNS page)" tailscale_cap https
    status_check "The funnel nodeAttr granted to this machine (Tailscale access policy)" tailscale_cap funnel
    if unit_active "$NTFY_UNIT"; then
        status_check "ntfy answers on $NTFY_LOCAL_URL (journalctl -u ntfy says why not)" ntfy_healthy
        status_ntfy_access
        status_ntfy_public_dns
    fi
    if ntfy_client_ready && [ "$(ntfy_client_host)" == "$NTFY_LOCAL_URL" ]; then
        status_item ok "ntfy's users and this machine's token ($(shown_path "$(ntfy_client_config)"))"
        ntfy_notifier_files status_file
        status_file_content "$NTFY_NOTIFIER_UNIT" "$(ntfy_notifier_unit)"
        status_user_service "$NTFY_NOTIFIER_UNIT_NAME" "ntfy's desktop notifier"
    else
        status_item missing "ntfy's users and this machine's token: run just ntfy-user"
    fi
}

# status_file_content <file> <content>: like status_file, for a file the step generates
status_file_content() {
    if file_is "$1" "$2"; then
        status_item ok "$(shown_path "$1")"
    else
        status_item missing "$(shown_path "$1"): not as the step writes it; re-run bash setup.sh ntfy"
    fi
}

status_macos() {
    status_require_cmd ntfy "ntfy's client, from the Brewfile" || return 0
    status_require_cmd terminal-notifier "terminal-notifier, from the Brewfile" || return 0
    ntfy_notifier_files status_file
    ntfy_agent_files status_file
    if ntfy_agent_loaded; then
        status_item ok "The $NTFY_AGENT_LABEL LaunchAgent loaded, and it starts at login"
    else
        status_item missing "The $NTFY_AGENT_LABEL LaunchAgent loaded: re-run bash setup.sh ntfy, and check it's allowed under Allow in the Background in System Settings → General → Login Items & Extensions"
    fi
    if ntfy_client_ready; then
        status_item ok "This Mac's ntfy token ($(shown_path "$(ntfy_client_config)"))"
    else
        status_item missing "This Mac's ntfy token: run just ntfy-device with the macbook token from just ntfy-user"
    fi
    status_notify_error
}

status() {
    if is_macos; then
        status_macos
    else
        status_ubuntu
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
