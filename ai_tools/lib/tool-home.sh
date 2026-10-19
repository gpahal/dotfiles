# shellcheck shell=bash
# The check that an AI tool's home is the default, shared by the claude-code and codex steps, which
# source this file after lib/common.sh. It only defines functions.

# tool_home_guard [--status <what>] <tool> <variable> <default home>
# Succeed when the tool's home variable is unset or names the default (tool_home_is). The steps'
# paths and the docs all assume the default, so otherwise the step fails rather than leave the tool
# reading files setup never wrote: this prints why, as an error, or under --status as an unknown
# item for <what>, and fails.
# e.g. tool_home_guard --status "Codex settings and instructions" Codex CODEX_HOME "$HOME/.codex"
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
