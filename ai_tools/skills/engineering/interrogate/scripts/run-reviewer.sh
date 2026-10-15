#!/bin/bash
set -euo pipefail

# Run one reviewer through the Claude Code or Codex CLI, read-only, and save its final answer.
# Usage: run-reviewer.sh <claude|codex> <model> <effort> <prompt-file> <out-file>
#
# Run it from inside the repo under review: the reviewer works from the repo's root. Claude runs
# in restricted mode, which confines its file tools to the repo and the prompt file's directory
# (where the lead puts the diff file and any materialized head). It gets only the Read, Grep, and Glob tools, with no
# settings files or MCP servers loaded, since the user's allow rules would otherwise apply.
# Codex runs in its read-only sandbox, which blocks writes but not reads. It skips the user's
# config.toml and rules files, so no MCP servers, plugins, or auto-reviewer load, and it never
# asks for approval, so a command the sandbox blocks stays blocked.
# Both need network access to reach their model, so a sandboxed caller must run this outside the
# sandbox. The out-file goes outside the prompt file's directory, so Claude can't read
# another run's answer there. The CLI's own log goes to <out-file>.log. A run that takes longer
# than REVIEWER_TIMEOUT seconds (default 1800, or 3600 at high effort and above) is stopped and
# counts as failed.

if [[ $# -ne 5 ]]; then
    echo "usage: run-reviewer.sh <claude|codex> <model> <effort> <prompt-file> <out-file>" >&2
    exit 2
fi

family="$1"
model="$2"
effort="$3"
prompt="$4"
out="$5"

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
# Both CLIs run from the repo root, so a path relative to the caller's directory would miss.
# CDPATH could send cd elsewhere and make it print the path.
prompt_dir="$(CDPATH='' cd "$(dirname "$prompt")" && pwd)"
prompt="$prompt_dir/$(basename "$prompt")"
if ! out_dir="$(CDPATH='' cd "$(dirname "$out")" 2>/dev/null && pwd)"; then
    echo "run-reviewer.sh: the out-file's directory '$(dirname "$out")' doesn't exist" >&2
    exit 2
fi
out="$out_dir/$(basename "$out")"
log="$out.log"
# pwd -P, so a symlinked path to the same directory can't slip past
case "$(CDPATH='' cd "$out_dir" && pwd -P)/" in
    "$(CDPATH='' cd "$prompt_dir" && pwd -P)"/*)
        echo "run-reviewer.sh: the out-file '$out' is inside the prompt file's directory, which the reviewer can read. Put answers in a separate temp dir." >&2
        exit 2
        ;;
esac

# A retry reuses the same out-file, so clear the last attempt's answer first.
rm -f "$out" "$log"

fail() {
    echo "run-reviewer.sh: $1" >&2
    [[ -s "$log" ]] && tail -n 20 "$log" >&2
    exit 1
}

# Give the reviewer its own process group, so timeout and cancellation reach descendants even
# after their parent exits. This works in Bash 3.2 without Linux-only setsid.
set -m
case "$family" in
    claude)
        (cd "$root" && exec claude -p --model "$model" --effort "$effort" \
            --restricted --strict-mcp-config \
            --tools Read Grep Glob --permission-mode dontAsk --allowedTools Read Grep Glob \
            --add-dir "$prompt_dir" --no-session-persistence --output-format text \
            <"$prompt" >"$out" 2>"$log") &
        ;;
    codex)
        # multi_agent is off because --ephemeral sessions can't start sub-agents. Auth still
        # works without the user config: it lives in $CODEX_HOME/auth.json. The read-only
        # sandbox lets the reviewer read any file you can, so instructions planted in a reviewed
        # diff could get a secret quoted into its answer.
        codex exec --model "$model" -c "model_reasoning_effort=\"$effort\"" \
            -c 'approval_policy="never"' --ignore-user-config --ignore-rules \
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
set +m

# The watchdog drops this script's stdout and stderr, and kills its sleep when it's stopped, so
# no leftover process keeps a caller's pipe open until the timeout.
(
    exec >/dev/null 2>&1 </dev/null
    sleep "$timeout" &
    sleeper=$!
    trap 'kill "$sleeper"; exit 0' TERM
    if wait "$sleeper"; then
        kill -TERM -- "-$pid" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$pid" 2>/dev/null || true
    fi
) &
watchdog=$!

# A cancelled runner (the lead's tool call stopped, or its terminal closed) stops the reviewer and
# the watchdog too, instead of leaving them running until the timeout.
cleanup() {
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$pid" "$watchdog" 2>/dev/null || true
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT
trap 'trap - EXIT; cleanup; exit 143' TERM
trap 'trap - EXIT; cleanup; exit 129' HUP

status=0
wait "$pid" || status=$?
cleanup
trap - EXIT INT TERM HUP

if [[ $status -ne 0 ]]; then
    # claude -p prints some errors to stdout, which went to the out-file.
    [[ "$family" == claude && -s "$out" ]] && cat "$out" >>"$log"
    rm -f "$out"
    fail "$family exited with status $status (a status of 143 means it ran past ${timeout}s)"
fi
[[ -s "$out" ]] || fail "$family reviewer wrote no answer to '$out'"
