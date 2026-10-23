#!/bin/bash

# A CODEX_HOME or CLAUDE_CONFIG_DIR away from the default fails its step before any change.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for cmd in brew curl claude codex bwrap; do
    stub "$cmd" 'exit 1'
done

# <step>|<variable>|<default home>|<app>|<status item>
for tool in "codex|CODEX_HOME|.codex|Codex|Codex settings and instructions" \
    "claude-code|CLAUDE_CONFIG_DIR|.claude|Claude Code|Claude Code settings, status line, and instructions"; do
    IFS='|' read -r step var home app item <<< "$tool"
    load_script "ai_tools/$step/install.sh"
    export "$var=$SANDBOX/$var"
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "setup assumes $app's default home (~/$home); unset $var or move it"
    [ ! -e "$HOME/$home" ] || fail "the $step step wrote ~/$home"
    [ ! -e "$SANDBOX/$var" ] || fail "the $step step wrote $var"
    assert_eq "" "$(cat "$STUB_LOG")" "commands the $step step ran"
    run main --status
    assert_contains "$RUN_OUTPUT" "unknown    $item: setup assumes $app's default home"
    assert_eq 3 "$RUN_STATUS" "$step status exit"
    unset "$var"
done

assert_exit 0 tool_home_is "$HOME/.codex/" "$HOME/.codex"
mkdir -p "$HOME/.codex"
ln -s "$HOME/.codex" "$HOME/codex-link"
assert_exit 0 tool_home_is "$HOME/codex-link" "$HOME/.codex"
assert_exit 1 tool_home_is "$SANDBOX/codex-home" "$HOME/.codex"
assert_exit 0 tool_home_is "" "$HOME/.codex"
test_done
