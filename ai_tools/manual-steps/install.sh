#!/bin/bash
set -euo pipefail

# Print this OS's AI tool steps that scripts can't do and that aren't done yet.
# steps.sh lists them, with the checks below for those a script can tell are done, which --status
# reports. On macOS it offers to open the settings and pages for the steps it knows are left.

# shellcheck source=../../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
# shellcheck source=../../lib/manual.sh
source "$DOTFILES_DIR/lib/manual.sh"
# shellcheck source=steps.sh
source "$DOTFILES_DIR/ai_tools/manual-steps/steps.sh"

CLAUDE_CHROME_EXTENSION_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"
NOTIFYING_APPS=(com.anthropic.claudefordesktop com.openai.codex com.t3tools.t3code)
T3=("$HOME/.local/bin/t3")
# Set by the checks, for open_manual_steps
PENDING_NOTIFICATIONS=""

chrome_profile_dir() {
    if is_macos; then
        echo "$HOME/Library/Application Support/Google/Chrome"
    else
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome"
    fi
}

app_notifications() {
    PENDING_NOTIFICATIONS="$(notifications_pending "${NOTIFYING_APPS[@]}")" ||
        manual_unknown "$NOTIFICATIONS_UNREADABLE" || return
    [ -n "$PENDING_NOTIFICATIONS" ] || return 0
    MANUAL_DETAIL="not yet for $(join_lines ', ' <<< "$PENDING_NOTIFICATIONS")"
    return 1
}

claude_in_chrome() {
    claude_in_chrome_done "$(chrome_profile_dir)"
}

claude_signed_in() {
    step_check ai_tools/claude-code/install.sh claude_signed_in_now
}

# Runs inside the claude-code step
claude_signed_in_now() {
    local claude
    claude="$(claude_code_path)" && [ "$(claude_code_signed_in "$claude")" == true ]
}

codex_signed_in() {
    local codex="${HOMEBREW_PREFIX:+$HOMEBREW_PREFIX/bin/codex}"
    [ -n "$codex" ] && [ -x "$codex" ] && "$codex" login status &>/dev/null
}

# Your unarchived repositories, a page at a time
# shellcheck disable=SC2016 # GraphQL variables
GITHUB_REPOS_QUERY='query($endCursor: String) { viewer { repositories(first: 100, after: $endCursor, ownerAffiliations: OWNER, isArchived: false) { nodes { nameWithOwner squashMergeAllowed } pageInfo { hasNextPage endCursor } } } }'

# T3 Code's PRs squash-merge
github_squash_merge() {
    local repos
    command -v gh &>/dev/null || manual_unknown "gh isn't installed" || return
    repos="$(run_bounded 60 gh api graphql --paginate -f query="$GITHUB_REPOS_QUERY" \
        --jq '.data.viewer.repositories.nodes[] | select(.squashMergeAllowed | not) | .nameWithOwner' 2>/dev/null)" ||
        manual_unknown "couldn't list your GitHub repositories with gh" || return
    [ -n "$repos" ] || return 0
    MANUAL_DETAIL="off for $(join_lines ', ' <<< "$repos")"
    return 1
}

# The Ubuntu steps' sudo changes, which setup leaves undone without a terminal
ai_sudo_work_done() {
    manual_parts_start
    if has_gnome_desktop; then
        manual_part "the Claude desktop app" step_check ai_tools/claude-desktop/install.sh claude_apt_installed
        manual_part "the T3 Code desktop app" apt_installed t3code
    fi
    manual_part "bubblewrap" apt_installed bubblewrap
    manual_part "Codex's sandbox" step_check ai_tools/codex/install.sh bwrap_works
    [ -x "${T3[0]}" ] || manual_part "libatomic1" apt_installed libatomic1
    manual_parts_result
}

t3_connect_linked() {
    [ -x "${T3[0]}" ] || return 1
    run_bounded 30 "${T3[@]}" connect status --json 2>/dev/null |
        jq -e '.linked == true and .publishAgentActivity == true' &>/dev/null
}

# t3 auth session list --json, cached through a memo scope once called outside a $( )
t3_sessions() {
    memo T3_SESSIONS run_bounded 30 "${T3[@]}" auth session list --json 2>/dev/null
}

# t3_session_from <jq condition on .client>: a session for such a client. Sessions expire, so
# none proves nothing.
t3_session_from() {
    [ -x "${T3[0]}" ] || manual_unknown "the t3 CLI isn't installed" || return
    t3_sessions > /dev/null || manual_unknown "t3 auth session list failed" || return
    jq -e "any(.[]?; .client | $1)" <<< "$T3_SESSIONS" &>/dev/null ||
        manual_unknown "no current session from it, and an expired one can't be seen" || return
}

t3_phone_connected() {
    t3_session_from '.deviceType == "mobile"'
}

t3_mac_paired() {
    t3_session_from '.os == "macOS"'
}

t3_desktop_paired() {
    if ! has_gnome_desktop; then
        MANUAL_DETAIL="no desktop"
        return 0
    fi
    t3_session_from '.os == "Linux" and .browser == "Electron"'
}

# MagicDNS lists the tailnet's certificate domains once HTTPS certificates are on
tailscale_https_on() {
    command -v tailscale &>/dev/null || manual_unknown "Tailscale isn't installed" || return
    tailscale_status_json > /dev/null || manual_unknown "tailscale status failed" || return
    jq -e '(.CertDomains // []) | length > 0' <<< "$TAILSCALE_STATUS_JSON" &>/dev/null
}

# Without sudo, t3 browser setup changes nothing
t3_browser_ready() {
    local report
    [ -x "${T3[0]}" ] || return 1
    report="$(run_bounded 60 "${T3[@]}" browser setup 2>&1)" || manual_unknown "t3 browser setup failed" || return
    [[ "$report" != *"needs root"* ]]
}

# Opens what the checks found left: the notification settings of each app not set, and the Claude
# in Chrome extension's page while it isn't installed
open_manual_steps() {
    local bundle_id open_extension=false targets="" notifications=0
    if ! compgen -G "$(chrome_profile_dir)/*/Extensions/$CLAUDE_CHROME_EXTENSION_ID" > /dev/null &&
        [ -d "/Applications/Google Chrome.app" ]; then
        open_extension=true
    fi
    manual_result macos app-notifications || notifications=$?
    [ "$notifications" -ne 1 ] || targets="the notification settings"
    "$open_extension" && targets="${targets:+$targets and }the Chrome extension page"
    [ -n "$targets" ] || return 0
    echo ""
    # DOTFILES_ASSUME_YES means a test machine, where nobody is there to set anything.
    if [ "${DOTFILES_ASSUME_YES:-}" == 1 ] && on_test_machine; then
        echo "  Not opening $targets: DOTFILES_ASSUME_YES is set."
        return 0
    fi
    confirm "Open $targets now?" || return 0
    if [[ "$targets" == *notification* ]]; then
        for bundle_id in $PENDING_NOTIFICATIONS; do
            open "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=$bundle_id"
            read -r -p "  Set $bundle_id to Allow notifications + Persistent, then press Enter..." _
        done
        echo "  Test a notification from your terminal with: $DOTFILES_DIR/scripts/test-notification.sh"
    fi
    if "$open_extension"; then
        open -a "Google Chrome" "https://chromewebstore.google.com/detail/claude/$CLAUDE_CHROME_EXTENSION_ID"
    fi
}

status() {
    manual_steps
    status_manual "bash ai_tools/setup.sh manual-steps"
}

apply() {
    manual_steps
    manual_print "AI tool steps"
    ! is_macos || open_manual_steps
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
