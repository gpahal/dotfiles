# shellcheck shell=bash
# ubuntu/install.sh sets the constants, except TAILSCALE_KEY_FPR.

# unattended-upgrades doesn't cover Tailscale's repo, so it updates itself. Operator lets
# `t3 pair --tailscale` run `tailscale serve` without sudo; anything running as you can then also
# run funnel or `set --ssh`, which bypasses sshd, so status reports both.
tailscale_configured() {
    local prefs
    prefs="$(tailscale_prefs)" || return 1
    jq -e --arg user "$(id -un)" '.AutoUpdate.Apply == true and .OperatorUser == $user' \
        <<< "$prefs" &>/dev/null
}

# Cached through a memo scope, once called outside a $( )
tailscale_prefs() {
    memo TAILSCALE_PREFS tailscale debug prefs 2>/dev/null
}

tailscale_state() {
    tailscale status --json 2>/dev/null | jq -r '.BackendState // empty'
}

tailscale_running() {
    [ "$(tailscale_state)" == Running ]
}

# The first tailscale up resets auto-update and operator, so set them after it
tailscale_needs_login() {
    [ "$(tailscale_state)" == NeedsLogin ]
}

# Matches Tailscale's install script, since its updater rewrites this line
tailscale_list_line() {
    echo "deb [signed-by=$TAILSCALE_KEYRING] $TAILSCALE_REPO $(ubuntu_codename) main"
}

# Tailscale doesn't publish it. To re-verify, compare gpg --show-keys on
# $TAILSCALE_REPO/<codename>.noarmor.gpg, fetched over two networks, with the same on
# $TAILSCALE_KEYRING on a machine that installed Tailscale earlier.
TAILSCALE_KEY_FPR=2596A99EAAB33821893C0A79458CA832957F5868

# Only once apt_repo_published says Tailscale has packages for this release
install_tailscale() {
    add_apt_repo Tailscale "$TAILSCALE_LIST" "$(tailscale_list_line)" \
        "$TAILSCALE_REPO/$(ubuntu_codename).noarmor.gpg" "$TAILSCALE_KEYRING" "$TAILSCALE_KEY_FPR" || return 1
    command -v tailscale &>/dev/null || apt_get install -y tailscale
}

set_up_tailscale() {
    sudo tailscale set --auto-update --operator="$(id -un)"
}

# Prints the host:port of each funnel, including a foreground one, or fails when it can't ask
tailscale_funnels() {
    local config
    config="$(tailscale funnel status --json 2>/dev/null)" || return 1
    jq -r '[.. | objects | .AllowFunnel? // empty | to_entries[] | select(.value) | .key] | unique[]' \
        <<< "$config" 2>/dev/null
}

tailscale_ssh_off() {
    local prefs
    prefs="$(tailscale_prefs)" || return 1
    jq -e '.RunSSH == false' <<< "$prefs" &>/dev/null
}

status_tailscale_exposure() {
    local label="No Tailscale funnel publishing a port to the internet" funnels
    if ! funnels="$(tailscale_funnels)"; then
        status_item unknown "$label: tailscale funnel status --json failed"
    elif [ -z "$funnels" ]; then
        status_item ok "$label"
    else
        status_item missing "$label: $(join_lines ', ' <<< "$funnels") is published; turn each off with tailscale funnel --https=<port> off"
    fi
    status_check "Tailscale SSH off, so only sshd lets you in (tailscale set --ssh=false turns it off)" tailscale_ssh_off
}
