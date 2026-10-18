# shellcheck shell=bash
# Tailscale for the ubuntu step.
# ubuntu/install.sh sources this file and sets the constants it uses. It defines functions, and
# the fingerprint of Tailscale's key beside the one that adds it.

# Tailscale's apt repo isn't one unattended-upgrades updates, so Tailscale updates itself. As
# operator, you can run `tailscale serve` without sudo, which `t3 pair --tailscale` does. So can
# anything else running as you, and `tailscale funnel` too, which puts a port on the internet, when
# the tailnet policy grants the funnel attribute.
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

# Before the first tailscale up, which resets the auto-update and operator settings, so the step
# leaves them until after it
tailscale_needs_login() {
    [ "$(tailscale_state)" == NeedsLogin ]
}

# The one-line source Tailscale's install script writes, which its updater rewrites to change track
tailscale_list_line() {
    echo "deb [signed-by=$TAILSCALE_KEYRING] $TAILSCALE_REPO $(ubuntu_codename) main"
}

# Tailscale's Release file for this release, which is a 404 until Tailscale publishes packages for it
tailscale_release_url() {
    echo "$TAILSCALE_REPO/dists/$(ubuntu_codename)/Release"
}

# Tailscale's package signing key. Tailscale doesn't publish its fingerprint, so this one is the
# key pkgs.tailscale.com served in October 2026, the same for every Ubuntu release.
TAILSCALE_KEY_FPR=2596A99EAAB33821893C0A79458CA832957F5868

# Run it once apt_repo_published says Tailscale has packages for this release. The key's URL names
# the release, as in Tailscale's install script.
add_tailscale_repo() {
    add_apt_repo Tailscale "$TAILSCALE_LIST" "$(tailscale_list_line)" \
        "$TAILSCALE_REPO/$(ubuntu_codename).noarmor.gpg" "$TAILSCALE_KEYRING" "$TAILSCALE_KEY_FPR"
}
