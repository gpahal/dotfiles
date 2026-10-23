# The --status format, which run_steps and ubuntu/health-alert.sh parse. lib/common.sh sources it;
# apart from status_needs_root, it needs nothing else, so it also works sourced on its own. Don't
# run it.
# shellcheck shell=bash

# Only missing and unknown need attention
STATUS_STATES="ok missing skipped unverified unknown info"
STATUS_STATE_WIDTH=10
STATUS_SUMMARY_ATTENTION="Needs attention"
STATUS_SUMMARY_FAILED="Failed steps"
# health-alert.sh finds root-only items by it
ROOT_ONLY_TEXT='run sudo -v, then status'

status_state_needs_attention() {
    case "$1" in
        missing | unknown) return 0 ;;
    esac
    return 1
}

# Sets STATUS_LINE_STATE and STATUS_LINE_TEXT; fails for lines that aren't items
status_parse_line() {
    local line="$1" state padded
    state="${line:2:$STATUS_STATE_WIDTH}"
    state="${state%% *}"
    case " $STATUS_STATES " in
        *" $state "*) ;;
        *) return 1 ;;
    esac
    printf -v padded "  %-${STATUS_STATE_WIDTH}s " "$state"
    [ "${line:0:${#padded}}" == "$padded" ] || return 1
    # shellcheck disable=SC2034 # callers read them
    STATUS_LINE_STATE="$state"
    # shellcheck disable=SC2034
    STATUS_LINE_TEXT="${line:${#padded}}"
}

status_summary_line() {
    case "$1" in
        "$STATUS_SUMMARY_ATTENTION: "* | "$STATUS_SUMMARY_FAILED: "*) return 0 ;;
    esac
    return 1
}

# status_needs_root <label> <reason> [it | them]: an unverified item that only root can check. A
# label ending in a colon reads "<label> <reason>; run ...", any other "<label> (<reason>; run ...)".
# It needs status_item, from lib/common.sh.
status_needs_root() {
    local hint="$ROOT_ONLY_TEXT, to check ${3:-it}"
    case "$1" in
        *:) status_item unverified "$1 $2; $hint" ;;
        *) status_item unverified "$1 ($2; $hint)" ;;
    esac
}
