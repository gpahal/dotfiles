# shellcheck shell=bash
# ubuntu/install.sh sets the constants, except TAILSCALE_KEY_FPR.

# unattended-upgrades doesn't cover Tailscale's repo, so it updates itself. Operator lets
# `t3 pair --tailscale` run `tailscale serve` without sudo; anything running as you can then also
# run funnel or `set --ssh`, which bypasses sshd.
tailscale_configured() {
    local prefs
    prefs="$(tailscale debug prefs 2>/dev/null)" || return 1
    jq -e --arg user "$(id -un)" '.AutoUpdate.Apply == true and .OperatorUser == $user' \
        <<< "$prefs" &>/dev/null
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

# 404 until Tailscale publishes packages for this release
tailscale_release_url() {
    echo "$TAILSCALE_REPO/dists/$(ubuntu_codename)/Release"
}

# Not published by Tailscale; the key pkgs.tailscale.com served in October 2026
TAILSCALE_KEY_FPR=2596A99EAAB33821893C0A79458CA832957F5868

# Only once apt_repo_published says Tailscale has packages for this release
add_tailscale_repo() {
    add_apt_repo Tailscale "$TAILSCALE_LIST" "$(tailscale_list_line)" \
        "$TAILSCALE_REPO/$(ubuntu_codename).noarmor.gpg" "$TAILSCALE_KEYRING" "$TAILSCALE_KEY_FPR"
}
