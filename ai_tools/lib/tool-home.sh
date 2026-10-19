# shellcheck shell=bash

# tool_home_guard [--status <what>] <tool> <variable> <default home>
# Fails unless the home variable is unset or the default, since setup writes only to the default.
tool_home_guard() {
    local what=""
    if [ "$1" == --status ]; then
        what="$2"
        shift 2
    fi
    local tool="$1" var="$2" home="$3" policy
    tool_home_is "${!var:-}" "$home" && return 0
    policy="setup assumes $tool's default home (~/${home#"$HOME"/}); unset $var or move it"
    if [ -n "$what" ]; then
        status_item unknown "$what: $policy"
    else
        echo "  $var is ${!var}, but $policy" >&2
    fi
    return 1
}
