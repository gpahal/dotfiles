# The runners' code: setup.sh and ai_tools/setup.sh source it after lib/common.sh, as do scripts
# that read step headers. Source it; don't run it.
# shellcheck shell=bash

warn_untested_platform() {
    local arch
    is_macos && return 0
    arch="$(uname -m)"
    [ "$arch" == x86_64 ] && return 0
    echo "Warning: setup is tested on x86_64 Ubuntu, not $arch. Carrying on. A package with no $arch build fails its step." >&2
}

# Prints the first STEP_NEEDS entry among the failed steps
_failed_need() {
    local script="$1" need
    shift
    [ $# -gt 0 ] || return 1
    for need in $(step_header_value "$script" STEP_NEEDS); do
        if has_arg "$need" "$@"; then
            echo "$need"
            return 0
        fi
    done
    return 1
}

# step_header_value <script> <var>: reads a literal on its own line, such as STEP_NEEDS, without
# sourcing
step_header_value() {
    sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$1" 2>/dev/null | head -n 1
}

step_header_line() {
    awk 'NR > 1 && /^# / && !/^# shellcheck/ { sub(/^# /, ""); print; exit }' "$1"
}

# Succeeds when an item needs attention. The exit code can't tell: set -e can cut a report short
# at a command that itself exited 3.
_status_relay() {
    local line attention=1 first=true
    while IFS= read -r line || [ -n "$line" ]; do
        if "$first"; then
            printf '%s\n' "$1"
            first=false
        fi
        printf '%s\n' "$line"
        if status_parse_line "$line" && status_state_needs_attention "$STATUS_LINE_STATE"; then
            attention=0
        fi
    done
    return "$attention"
}

# Either OS's steps resolve, so a step for the other OS reaches its own skip message
step_script() {
    case "$1" in
        '' | *[[:space:]/]*) return 1 ;;
    esac
    case " ${MACOS_STEPS[*]-} ${UBUNTU_STEPS[*]-} " in
        *" $1 "*) ;;
        *) return 1 ;;
    esac
    # shellcheck disable=SC2154 # STEPS_DIR is set by the caller
    echo "$STEPS_DIR/$1/install.sh"
}

# Callers set MACOS_STEPS, UBUNTU_STEPS, and STEPS_DIR. Returns only after a setup run succeeds;
# otherwise exits.
runner_main() {
    local name="$1" for_alerts="$2" script status=0
    shift 2
    script="$(_repo_path "${BASH_SOURCE[1]}")"
    if is_macos; then
        STEPS=("${MACOS_STEPS[@]}")
    else
        STEPS=("${UBUNTU_STEPS[@]}")
    fi
    check_args _runner_usage words "$@"
    RUNNER_STEPS=(${ARG_WORDS[@]+"${ARG_WORDS[@]}"})
    if status_requested "$@"; then
        echo "=== $name status ==="
        run_steps --status ${RUNNER_STEPS[@]+"${RUNNER_STEPS[@]}"} || status=$?
        reraise_interrupt "$status"
        exit "$status"
    fi
    echo "=== $name setup ==="
    run_steps "" ${RUNNER_STEPS[@]+"${RUNNER_STEPS[@]}"} || status=$?
    reraise_interrupt "$status"
    [ "$status" -eq 0 ] || exit "$status"
    echo ""
    echo "=== $name setup complete! ==="
}

_runner_usage() {
    local step
    echo "Usage: bash $script [--status [--for-alerts]] [--backup | --no-backup] [step...]"
    echo "Steps, run in this order by default: ${STEPS[*]}"
    for step in "${STEPS[@]}"; do
        printf '  %-15s %s\n' "$step" "$(step_header_line "$(step_script "$step")")"
    done
    echo "--status reports what each step has set up, changing nothing. It exits 3 for missing or"
    echo "unknown items."
    echo "--for-alerts, with --status, is what the daily health alert runs: it skips"
    echo "$for_alerts."
    echo "A config file that differs from the repo's is replaced. Settings merged into files other"
    echo "tools also edit ask whether to back up the file first. --backup or --no-backup answers"
    echo "every backup question yes or no."
    echo "Flags may come before or after the step names."
}

# Re-raise so callers stop too: bash carries on after exit 130, not after death by SIGINT
reraise_interrupt() {
    local sig
    case "$1" in
        129) sig=HUP ;;
        130) sig=INT ;;
        143) sig=TERM ;;
        *) return 0 ;;
    esac
    trap - INT TERM HUP
    kill -s "$sig" $$
    exit "$1"
}

# _stop_steps <pid...>: background steps ignore SIGINT, so TERM each and everything it started,
# while the runner's traps keep bash from reporting the deaths
_stop_steps() {
    local tree
    tree="$(ps -A -o pid= -o ppid= | awk -v roots="$*" '
        BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) in_tree[r[i]] = 1 }
        { parent[$1] = $2 }
        END {
            do {
                grew = 0
                for (p in parent) if (!(p in in_tree) && (parent[p] in in_tree)) { in_tree[p] = 1; grew = 1 }
            } while (grew)
            for (p in in_tree) print p
        }')" || true
    # shellcheck disable=SC2086 # a list of pids
    kill -TERM $tree 2> /dev/null || true
    wait "$@" 2> /dev/null || true
}

# _relay_status <step> <pid> <out> <err>: waits for the step, prints its report, and sets
# run_steps' status. Exit 3 with no item needing attention means set -e cut the report short.
_relay_status() {
    local relay=0
    wait "$2" || status=$?
    # A trapped signal ends wait early, with the step still running
    [ -z "$interrupted" ] || return 0
    _status_relay "$1:" < "$3" || relay=$?
    cat "$4" >&2
    if [ "$status" -eq 3 ] && [ "$relay" -ne 0 ]; then
        status=1
    fi
}

# run_steps <''|--status> [step...]: a failed step doesn't stop the rest. --status returns 3 when
# an item needs attention, 1 when a step failed. Reports run at once, each printing in step order
# once it and those before it have ended; setup runs one step at a time, as it may ask questions
# and STEP_NEEDS skips steps after a failed one.
run_steps() {
    local mode="$1" step script status blocker interrupted="" failed=() attention=() dir="" i=0 \
        pids=()
    shift
    require_supported_os || return 1
    # step_script takes either OS's steps, so the error lists both
    for step in "$@"; do
        step_script "$step" > /dev/null || {
            echo "Unknown step: $step. Steps on macOS: ${MACOS_STEPS[*]}. On Ubuntu: ${UBUNTU_STEPS[*]}" >&2
            return 1
        }
    done
    warn_untested_platform
    # shellcheck disable=SC2154 # STEPS is set by the caller
    [ $# -gt 0 ] || set -- "${STEPS[@]}"
    # bash takes a step that exits normally after Ctrl-C to have handled it
    trap 'interrupted=130' INT
    trap 'interrupted=143' TERM
    trap 'interrupted=129' HUP
    if [ -n "$mode" ]; then
        dir="$(mktemp -d)" || {
            trap - INT TERM HUP
            return 1
        }
        for step in "$@"; do
            "$BASH" "$(step_script "$step")" --status < /dev/null > "$dir/$i.out" 2> "$dir/$i.err" &
            pids+=("$!")
            i=$((i + 1))
        done
        i=0
    fi
    for step in "$@"; do
        status=0
        if [ -n "$mode" ]; then
            [ -n "$interrupted" ] || _relay_status "$step" "${pids[$i]}" "$dir/$i.out" "$dir/$i.err"
            i=$((i + 1))
        else
            script="$(step_script "$step")"
            # A step for the other OS runs, and its main prints the skip
            if blocker="$(_failed_need "$script" ${failed[@]+"${failed[@]}"})"; then
                echo "$step: skipped, $blocker failed" >&2
                failed+=("$step")
                continue
            fi
            "$BASH" "$script" || status=$?
        fi
        [ -z "$interrupted" ] || status="$interrupted"
        if interrupted_status "$status"; then
            # From the current step on
            [ -z "$mode" ] || _stop_steps "${pids[@]:$((i - 1))}"
            echo "  The $step step was interrupted; stopping." >&2
            trap - INT TERM HUP
            [ -z "$dir" ] || rm -rf "$dir"
            return "$status"
        elif [ -n "$mode" ] && [ "$status" -eq 3 ]; then
            attention+=("$step")
        elif [ "$status" -ne 0 ]; then
            echo "  The $step step failed." >&2
            failed+=("$step")
        fi
    done
    trap - INT TERM HUP
    [ -z "$dir" ] || rm -rf "$dir"
    if [ ${#attention[@]} -gt 0 ]; then
        echo ""
        echo "$STATUS_SUMMARY_ATTENTION: ${attention[*]}. Run: bash $0 ${attention[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        echo "" >&2
        echo "$STATUS_SUMMARY_FAILED: ${failed[*]}" >&2
        echo "Fix the errors above, then re-run them with: bash $0 ${mode:+$mode }${failed[*]}" >&2
        return 1
    fi
    [ ${#attention[@]} -eq 0 ] || return 3
}
