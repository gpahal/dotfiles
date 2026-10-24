# run_bounded <seconds> <command...>, which lib/common.sh sources. It needs nothing else, so
# tests/run.sh sources it on its own too. Don't run it.
# shellcheck shell=bash

# Exits 124 on timeout. macOS lacks timeout(1), so perl's alarm stops only the command, not its
# children; without perl it runs unbounded.
run_bounded() {
    local seconds="$1" status=0 start=$SECONDS
    shift
    if command -v timeout &>/dev/null; then
        timeout -k 5 "$seconds" "$@" || status=$?
        # 137 means timeout had to SIGKILL
        if [ "$status" -eq 137 ] && [ $((SECONDS - start)) -ge "$seconds" ]; then
            status=124
        fi
        return "$status"
    fi
    if ! command -v perl &>/dev/null; then
        "$@"
        return
    fi
    # exec's block form skips the shell; the alarm survives exec
    perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or exit 127' "$seconds" "$@" || status=$?
    # 142 is SIGALRM
    if [ "$status" -eq 142 ] && [ $((SECONDS - start)) -ge "$seconds" ]; then
        status=124
    fi
    return "$status"
}
