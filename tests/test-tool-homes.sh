#!/bin/bash
set -euo pipefail

# Setup assumes Codex's and Claude Code's default homes. A CODEX_HOME or CLAUDE_CONFIG_DIR
# elsewhere fails the step before it changes anything, and status reports it as unknown.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
# status calls these; failing stubs stand in for tools that aren't set up, instead of tripping the
# sentinels
for cmd in brew curl claude codex; do
    stub "$cmd" 'exit 1'
done

# Codex
load_script ai_tools/codex/install.sh
export CODEX_HOME="$SANDBOX/codex-home"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "setup assumes Codex's default home (~/.codex); unset CODEX_HOME or move it"
[ ! -e "$HOME/.codex" ] || fail "the codex step wrote ~/.codex"
[ ! -e "$CODEX_HOME" ] || fail "the codex step wrote CODEX_HOME"
assert_eq "" "$(cat "$STUB_LOG")" "commands the codex step ran"
run main --status
assert_contains "$RUN_OUTPUT" "unknown    Codex settings and instructions: setup assumes Codex's default home"
assert_eq 3 "$RUN_STATUS" "codex status exit"

# The default home, however it's spelled, is fine
CODEX_HOME="$HOME/.codex/"
assert_exit 0 tool_home_is "$CODEX_HOME" "$HOME/.codex"
mkdir -p "$HOME/.codex"
ln -s "$HOME/.codex" "$HOME/codex-link"
assert_exit 0 tool_home_is "$HOME/codex-link" "$HOME/.codex"
assert_exit 1 tool_home_is "$SANDBOX/codex-home" "$HOME/.codex"
assert_exit 0 tool_home_is "" "$HOME/.codex"
unset CODEX_HOME

# Claude Code
load_script ai_tools/claude-code/install.sh
: > "$STUB_LOG"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude-home"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "setup assumes Claude Code's default home (~/.claude); unset CLAUDE_CONFIG_DIR or move it"
[ ! -e "$HOME/.claude" ] || fail "the claude-code step wrote ~/.claude"
[ ! -e "$CLAUDE_CONFIG_DIR" ] || fail "the claude-code step wrote CLAUDE_CONFIG_DIR"
assert_eq "" "$(cat "$STUB_LOG")" "commands the claude-code step ran"
run main --status
assert_contains "$RUN_OUTPUT" "unknown    Claude Code settings, status line, and instructions: setup assumes Claude Code's default home"
assert_eq 3 "$RUN_STATUS" "claude-code status exit"
test_done
