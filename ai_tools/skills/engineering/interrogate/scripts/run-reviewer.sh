#!/bin/bash
set -euo pipefail

# Run one reviewer through the Claude Code or Codex CLI, read-only, and save its final answer.
# Usage: run-reviewer.sh <claude|codex> <model> <effort> <prompt-file> <out-file>
#
# Run it from inside the repo under review: the reviewer works from the repo's root. Claude can
# read only the repo and the prompt file's directory (where the lead puts the diff file). It gets
# only the Read, Grep, and Glob tools, with no settings or MCP servers loaded, since the user's
# allow rules would otherwise apply. Codex runs in its read-only sandbox, which blocks writes but
# not reads.
# Both need network access to reach their model, so a sandboxed caller must run this outside the
# sandbox. The CLI's own log goes to <out-file>.log. A run that takes longer than
# REVIEWER_TIMEOUT seconds (default 1800, or 3600 at high effort and above) is stopped and counts
# as failed.

if [[ $# -ne 5 ]]; then
    echo "usage: run-reviewer.sh <claude|codex> <model> <effort> <prompt-file> <out-file>" >&2
    exit 2
fi

family="$1"
model="$2"
effort="$3"
prompt="$4"
out="$5"
log="$out.log"

# Both CLIs accept these five efforts, so one list covers both families.
case "$effort" in
    low | medium) default_timeout=1800 ;;
    high | xhigh | max) default_timeout=3600 ;;
    *)
        echo "run-reviewer.sh: unknown effort '$effort' (want low, medium, high, xhigh, or max)" >&2
        exit 2
        ;;
esac
timeout="${REVIEWER_TIMEOUT:-$default_timeout}"

if [[ ! -s "$prompt" ]]; then
    echo "run-reviewer.sh: prompt file '$prompt' is missing or empty" >&2
    exit 2
fi
if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "run-reviewer.sh: run this from inside the repo under review" >&2
    exit 2
fi
prompt_dir="$(cd "$(dirname "$prompt")" && pwd)"

# A retry reuses the same out-file, so clear the last attempt's answer first.
rm -f "$out" "$log"

fail() {
    echo "run-reviewer.sh: $1" >&2
    [[ -s "$log" ]] && tail -n 20 "$log" >&2
    exit 1
}

case "$family" in
    claude)
        (cd "$root" && exec claude -p --model "$model" --effort "$effort" \
            --setting-sources "" --strict-mcp-config \
            --tools Read Grep Glob --permission-mode dontAsk --allowedTools Read Grep Glob \
            --add-dir "$prompt_dir" --no-session-persistence --output-format text \
            <"$prompt" >"$out" 2>"$log") &
        ;;
    codex)
        # multi_agent is off because --ephemeral sessions can't start sub-agents.
        codex exec --model "$model" -c "model_reasoning_effort=\"$effort\"" \
            --sandbox read-only --disable multi_agent --ephemeral --cd "$root" \
            --output-last-message "$out" - \
            <"$prompt" >"$log" 2>&1 &
        ;;
    *)
        echo "run-reviewer.sh: unknown family '$family' (want claude or codex)" >&2
        exit 2
        ;;
esac
pid=$!

(sleep "$timeout" && kill "$pid" 2>/dev/null) &
watchdog=$!

status=0
wait "$pid" || status=$?
kill "$watchdog" 2>/dev/null || true

if [[ $status -ne 0 ]]; then
    # claude -p prints some errors to stdout, which went to the out-file.
    [[ "$family" == claude && -s "$out" ]] && cat "$out" >>"$log"
    rm -f "$out"
    fail "$family exited with status $status (a status of 143 means it ran past ${timeout}s)"
fi
[[ -s "$out" ]] || fail "$family reviewer wrote no answer to '$out'"
