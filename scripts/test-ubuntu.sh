#!/bin/bash
set -uo pipefail

# Test a whole Ubuntu setup in a throwaway OrbStack machine: create it, install unattended-upgrades,
# run setup.sh and then ai_tools/setup.sh in it with DOTFILES_ASSUME_YES=1, DOTFILES_SSH_KEY_ONLY=1,
# and DOTFILES_ALLOW_WORKTREE=1, twice, so a second pass over a set-up machine must pass too. Then
# restart it, run both --status reports, and check sshd's effective settings (sshd -T), that ufw is
# active, that a key logs in over SSH from this Mac, that the health alert's timer is active, that
# the T3 Code service is active, and that docker ps works from the user manager the service runs
# under. Then check the service stays the one T3 Code server on its port: after t3 service restart,
# after a kill -9 of its server, and against a t3 serve started by hand while it's stopped, which it
# must wait out, retrying, while status flags the extra server. The machine is deleted at the end,
# even when the run fails or is interrupted. Needs OrbStack on macOS, and takes a while: Homebrew,
# apt packages, and the AI tools all install from scratch. The full output goes to a log file.

MACHINE=dotfiles-test
# arm64 by default: OrbStack runs amd64 through Rosetta on Apple Silicon, where T3 Code 0.0.45
# crashes when systemd starts it. The real Ubuntu machine is x86_64, so TEST_UBUNTU_ARCH=amd64
# tests its CPU.
ARCH="${TEST_UBUNTU_ARCH:-arm64}"
REPO="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Steps that can't work in an OrbStack machine, so they may fail, or need attention in --status,
# without failing the test. Any other step that does fails it.
# - ghostty: OrbStack machines have no snapd.
ALLOWED_SETUP=(ghostty)
ALLOWED_AI=()
# Status items no OrbStack machine can satisfy, as "<step>: <item>". A step whose --status report
# needs attention only for these doesn't fail the test.
# - ubuntu: the machine never logs in to a tailnet. The UPS and smartd items report themselves
#   skipped in a VM, and linger gives the health alert's units a user manager, so they need none.
# - git: gh auth login needs a browser and a person. The git step defers it without failing, so
#   a failed git step still fails the test.
# - claude-code, codex, t3-code: signing in to Claude Code and Codex, and linking T3 Connect, each
#   need a browser and a person.
# - t3-code: t3 browser setup needs root, and the step only prints it for you to run with sudo.
ALLOWED_ITEMS=(
    "ubuntu: Tailscale connected (run sudo tailscale up)"
    "git: Logged in to GitHub with gh"
    "claude-code: Signed in to Claude Code: run claude auth login"
    "codex: Signed in to Codex: run codex login --device-auth (see ai_tools/README.md → Manual steps)"
    "t3-code: T3 Connect linked and publishing agent activity: run t3 connect --headless, then t3 connect publish and t3 service restart (see ai_tools/README.md → Manual steps)"
    "t3-code: T3 Code's browser can run in Chrome's sandbox: run sudo ~/.local/bin/t3 browser setup"
)
# Items allowed only while another item of the same step is missing, as
# "<step>: <item pattern>|<item it waits for>"
# - ubuntu: Tailscale doesn't persist preferences set before the first login.
# - git: gh auth setup-git, which sets the credential helper, runs after the login, and the git
#   step rewrites GitHub's SSH remotes to HTTPS only once that helper is set.
ALLOWED_BEFORE=(
    "ubuntu: Tailscale auto-updates, with * as its operator|Tailscale connected (run sudo tailscale up)"
    "git: git uses gh for GitHub credentials|Logged in to GitHub with gh"
    "git: GitHub SSH remotes go over HTTPS, through gh's credential helper (*)|Logged in to GitHub with gh"
)
# t3-code's status line for a t3 serve started by hand, up to the command line it shows in
# parentheses. tests/test-smoke-patterns.sh checks it against the step's own formatter.
T3_MANUAL_SERVE_STATUS='^  missing +No T3 Code server outside t3code\.service: PID [0-9]+, a t3 serve started by hand \('

if ! command -v orb &>/dev/null; then
    echo "OrbStack's orb command isn't installed. Install OrbStack (brew install --cask orbstack)." >&2
    exit 1
fi
if orb list -q | grep -qx "$MACHINE"; then
    echo "An OrbStack machine named $MACHINE already exists. Delete it with: orb delete -f $MACHINE" >&2
    exit 1
fi

# Both files in a dir only you can open, since another user could put a link at a name derived
# from the log's in a shared /tmp
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test-ubuntu.XXXXXX")"
LOG="$LOG_DIR/log"
VM_OUT_FILE="$LOG_DIR/step"
KEY_DIR=""
echo "Logging to $LOG"

# shellcheck disable=SC2329 # the EXIT trap runs it
cleanup() {
    if orb list -q | grep -qx "$MACHINE"; then
        echo "Deleting the $MACHINE machine..."
        orb delete -f "$MACHINE" >> "$LOG" 2>&1 || echo "Couldn't delete it. Run: orb delete -f $MACHINE" >&2
    fi
    rm -f "$VM_OUT_FILE"
    [ -z "$KEY_DIR" ] || rm -rf "$KEY_DIR"
    echo "Log: $LOG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Run a command in the machine as the default user, from the repo, which OrbStack mounts at the
# same path. Its output goes to the terminal and the log as it comes, and is kept in $VM_OUTPUT.
in_vm() {
    local status
    echo "+ $*" >> "$LOG"
    : > "$VM_OUT_FILE"
    orb run -m "$MACHINE" -w "$REPO" "$@" < /dev/null 2>&1 | tee -a "$LOG" "$VM_OUT_FILE"
    status=${PIPESTATUS[0]}
    VM_OUTPUT="$(cat "$VM_OUT_FILE")"
    return "$status"
}

FAILED=0

# Succeeds when a step's --status report in $VM_OUTPUT has missing or unknown items, and all of
# them are in ALLOWED_ITEMS or ALLOWED_BEFORE. The report runs from its "<step>:" header to the
# next header.
only_allowed_items() {
    local step="$1" item allowed found=false ok items pattern
    items="$(printf '%s\n' "$VM_OUTPUT" | awk -v header="$step:" '
        /^[a-z0-9_-]+:$/ { inside = ($0 == header); next }
        inside && /^  (missing|unknown) / { sub(/^  [a-z]+ +/, ""); print }')"
    [ -n "$items" ] || return 1
    while IFS= read -r item; do
        found=true
        ok=false
        for allowed in ${ALLOWED_ITEMS[@]+"${ALLOWED_ITEMS[@]}"}; do
            [ "$allowed" != "$step: $item" ] || ok=true
        done
        for allowed in ${ALLOWED_BEFORE[@]+"${ALLOWED_BEFORE[@]}"}; do
            pattern="${allowed%%|*}"
            # shellcheck disable=SC2053 # the item is a pattern
            if [[ "$step: $item" == $pattern ]] && grep -qxF "${allowed#*|}" <<< "$items"; then
                ok=true
            fi
        done
        "$ok" || return 1
    done <<< "$items"
    "$found"
}

# Check a runner's exit status and the steps it lists as failed or needing attention against the
# allowed ones. A line such as "Failed steps: git ghostty" or "Needs attention: git. Run: ..." in
# $VM_OUTPUT gives the steps. A step that needs attention only for items only_allowed_items
# accepts, from ALLOWED_ITEMS or ALLOWED_BEFORE, passes. A runner that exits non-zero without
# listing a step fails too.
# e.g. check_runner "setup.sh" "$status" ghostty
check_runner() {
    local what="$1" status="$2" step listed attention
    shift 2
    listed="$(printf '%s\n' "$VM_OUTPUT" | sed -nE 's/^(Failed steps|Needs attention): ([^.]*).*/\2/p')"
    attention="$(printf '%s\n' "$VM_OUTPUT" | sed -nE 's/^Needs attention: ([^.]*).*/\1/p')"
    if [ "$status" -ne 0 ] && [ -z "$listed" ]; then
        echo "FAIL: $what exited $status" | tee -a "$LOG"
        FAILED=1
    fi
    for step in $listed; do
        if [[ " $attention " == *" $step "* ]] && only_allowed_items "$step"; then
            continue
        fi
        if [[ " $* " != *" $step "* ]]; then
            echo "FAIL: $what: the $step step failed or needs attention" | tee -a "$LOG"
            FAILED=1
        fi
    done
}

# Run a runner in the machine, with --status or to set up, and check it
# e.g. run_runner setup.sh "" ghostty
run_runner() {
    local runner="$1" mode="$2" status=0
    shift 2
    echo "=== $runner $mode ==="
    if [ -n "$mode" ]; then
        in_vm bash "$runner" "$mode" || status=$?
    else
        # orb run reaches the machine without sshd, so no SSH session proves a key logs in, and
        # the opt-in turns password logins off. The repo may be a git worktree, from which the
        # ubuntu step otherwise won't install the health alerts.
        in_vm env DOTFILES_ASSUME_YES=1 DOTFILES_SSH_KEY_ONLY=1 DOTFILES_ALLOW_WORKTREE=1 bash "$runner" || status=$?
    fi
    check_runner "$runner $mode" "$status" "$@"
}

echo "Creating the $MACHINE machine (Ubuntu 26.04, $ARCH)..."
if ! orb create --arch "$ARCH" ubuntu:resolute "$MACHINE" >> "$LOG" 2>&1; then
    echo "Couldn't create the machine. See $LOG." >&2
    exit 1
fi

# Ubuntu Desktop ships unattended-upgrades; the machine's image doesn't
echo "=== unattended-upgrades ==="
in_vm sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || {
    echo "FAIL: couldn't install unattended-upgrades" | tee -a "$LOG"
    FAILED=1
}

# The second pass finds everything set up, and must still pass
for pass in 1 2; do
    echo "=== Setup, pass $pass ==="
    run_runner setup.sh "" ${ALLOWED_SETUP[@]+"${ALLOWED_SETUP[@]}"}
    run_runner ai_tools/setup.sh "" ${ALLOWED_AI[@]+"${ALLOWED_AI[@]}"}
done

echo "Restarting the $MACHINE machine..."
orb restart "$MACHINE" >> "$LOG" 2>&1 || {
    echo "FAIL: couldn't restart the machine" | tee -a "$LOG"
    FAILED=1
}

# The restart clears /run/sshd, which only an SSH connection makes again, and orb run doesn't make
# one. Without it, sshd -T fails, so the ubuntu step's status would skip its checks of sshd's
# settings and the ufw rules for sshd's ports.
in_vm sudo mkdir -p /run/sshd > /dev/null || {
    echo "FAIL: couldn't make /run/sshd" | tee -a "$LOG"
    FAILED=1
}
run_runner setup.sh --status ${ALLOWED_SETUP[@]+"${ALLOWED_SETUP[@]}"}
run_runner ai_tools/setup.sh --status ${ALLOWED_AI[@]+"${ALLOWED_AI[@]}"}

# Linger starts the service at boot, without a login. orb run starts no login session, so point
# systemctl at the user manager's runtime directory. Give the service up to a minute to come up.
echo "=== T3 Code service ==="
active=false
for _ in $(seq 1 12); do
    # shellcheck disable=SC2016 # expanded in the machine
    if in_vm bash -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active t3code.service'; then
        active=true
        break
    fi
    sleep 5
done
if ! "$active"; then
    echo "FAIL: the T3 Code service isn't active after a restart" | tee -a "$LOG"
    FAILED=1
fi

# Functions for the one-server checks, run in the machine. They come from the t3-code step, so the
# servers are counted as its status counts them: t3_code_other_servers lists those outside the
# service, and a listener on the port in t3code.service's cgroup is the service's.
# shellcheck disable=SC2016 # expanded in the machine
T3_VM_LIB='
export XDG_RUNTIME_DIR=/run/user/$(id -u)
source ai_tools/t3-code/install.sh
set +eu +o pipefail
t3_unit() { systemctl --user show -p "$1" --value t3code.service; }
# The PIDs listening on the port, one per line
port_pids() { ss -Htlnp "sport = :$T3_CODE_PORT" | grep -o "pid=[0-9]*" | cut -d= -f2 | sort -u; }
# Succeeds when the service runs the only T3 Code server, and it listens on the port
one_server() {
    local pids others
    pids="$(port_pids)"
    others="$(t3_code_other_servers)"
    echo "service $(t3_unit ActiveState)/$(t3_unit SubState), MainPID $(t3_unit MainPID); on $T3_CODE_PORT: $(echo ${pids:-nothing}); others: ${others:-none}"
    t3_code_service_active && [ -n "$pids" ] && [ "$(wc -l <<< "$pids")" -eq 1 ] &&
        t3_code_in_service_cgroup "$pids" && [ -z "$others" ]
}
# one_server, holding for 3 s with the same listener, and a MainPID other than <old>, if given. A
# server that crashes on start shows as active between restarts.
one_server_stable() {
    local first
    one_server && first="$(port_pids)" && sleep 3 && one_server && [ "$(port_pids)" == "$first" ] &&
        [ "$(t3_unit MainPID)" != "${1:-}" ]
}
# Print the PID of a listener on the port outside the service, and succeed, when there is just one
outside_listener() {
    local pids
    pids="$(port_pids)"
    echo "on $T3_CODE_PORT: $(echo ${pids:-nothing})"
    [ -n "$pids" ] && [ "$(wc -l <<< "$pids")" -eq 1 ] && ! t3_code_in_service_cgroup "$pids" &&
        echo "outside=$pids"
}
# Succeeds while the service, started with a server outside it on the port, fails its bind and
# retries: systemd has restarted it, it is neither stopped nor failed, and <pid> still has the port
service_locked_out() {
    local state restarts
    state="$(t3_unit ActiveState)/$(t3_unit SubState)"
    restarts="$(t3_unit NRestarts)"
    echo "service $state, NRestarts $restarts; on $T3_CODE_PORT: $(echo $(port_pids))"
    case "$state" in inactive/* | failed/*) return 1 ;; esac
    [ "${restarts:-0}" -ge 1 ] && [ "$(port_pids)" == "$1" ]
}
'

# Run a command in the machine, in bash with T3_VM_LIB's functions
in_vm_t3() {
    in_vm bash -c "$T3_VM_LIB"$'\n'"$1"
}

# Run in_vm_t3 until the command succeeds, up to <tries> times 5 s apart
# e.g. retry_t3 12 one_server_stable
retry_t3() {
    local tries="$1" _
    for _ in $(seq 1 "$tries"); do
        in_vm_t3 "$2" > /dev/null && return 0
        sleep 5
    done
    return 1
}

# Print the service's MainPID
t3_main_pid() {
    in_vm_t3 't3_unit MainPID' > /dev/null
    tail -n 1 <<< "$VM_OUTPUT"
}

t3_fail() {
    echo "FAIL: $1" | tee -a "$LOG"
    FAILED=1
}

echo "=== One T3 Code server ==="
# shellcheck disable=SC2016 # expanded in the machine
if ! in_vm_t3 'command -v ss && [ -x "$HOME/.local/bin/t3" ]' > /dev/null; then
    t3_fail "the one-server checks need ss and ~/.local/bin/t3 in the machine"
else
    retry_t3 12 one_server_stable || t3_fail "the T3 Code service isn't the one T3 Code server, on port 3773"

    # The README's step after linking T3 Connect. When it fails, systemctl restarts the service, so
    # the checks after it still run.
    old_pid="$(t3_main_pid)"
    # shellcheck disable=SC2016 # expanded in the machine
    if ! in_vm_t3 '"$HOME/.local/bin/t3" service restart'; then
        t3_fail "t3 service restart failed"
        in_vm_t3 'systemctl --user restart t3code.service' || true
    fi
    retry_t3 12 "one_server_stable $old_pid" ||
        t3_fail "after t3 service restart, the restarted service isn't the one T3 Code server, on port 3773"

    # The unit t3 service install writes sets Restart=, so systemd starts a killed server again
    in_vm_t3 't3_unit Restart' > /dev/null
    if [ "$(tail -n 1 <<< "$VM_OUTPUT")" == no ]; then
        t3_fail "t3code.service has Restart=no, so systemd won't restart a server that dies"
    fi
    old_pid="$(t3_main_pid)"
    # MainPID is 0 when nothing runs, and kill -9 0 would kill orb run's own process group
    if ! [[ "$old_pid" =~ ^[1-9][0-9]*$ ]]; then
        t3_fail "the T3 Code service has no server to kill -9 (MainPID ${old_pid:-unset})"
    elif ! in_vm_t3 "kill -9 $old_pid"; then
        t3_fail "couldn't kill -9 the T3 Code service's server (PID $old_pid)"
    else
        retry_t3 12 "one_server_stable $old_pid" ||
            t3_fail "after a kill -9 of its server, the restarted service isn't the one T3 Code server, on port 3773"
    fi

    # A t3 serve started by hand while the service is stopped. setsid -f detaches it, so orb run
    # returns while it runs; T3CODE_PORT pins it to the service's port, as the drop-in does.
    outside=""
    # shellcheck disable=SC2016 # expanded in the machine
    if ! in_vm_t3 'systemctl --user stop t3code.service && ! t3_code_service_active'; then
        t3_fail "couldn't stop the T3 Code service"
    elif ! in_vm_t3 'T3CODE_PORT=$T3_CODE_PORT T3CODE_TELEMETRY_ENABLED=false setsid -f "$HOME/.local/bin/t3" serve > /tmp/t3-manual-serve.log 2>&1 < /dev/null'; then
        t3_fail "couldn't start t3 serve by hand"
    elif ! retry_t3 12 outside_listener; then
        t3_fail "the t3 serve started by hand isn't listening on port 3773; see /tmp/t3-manual-serve.log in the machine"
    else
        in_vm_t3 outside_listener > /dev/null
        outside="$(sed -n 's/^outside=//p' <<< "$VM_OUTPUT")"
    fi
    if [ -n "$outside" ]; then
        in_vm_t3 'systemctl --user start t3code.service' || true
        retry_t3 8 "service_locked_out $outside" ||
            t3_fail "the T3 Code service didn't fail its bind and retry while a t3 serve started by hand had port 3773"
        # A status report with items missing exits 3
        # shellcheck disable=SC2016 # expanded in the machine
        in_vm bash -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) bash ai_tools/setup.sh --status t3-code' > /dev/null || true
        grep -qE "$T3_MANUAL_SERVE_STATUS" <<< "$VM_OUTPUT" ||
            t3_fail "t3-code's status doesn't flag the t3 serve started by hand"
        # shellcheck disable=SC2016 # expanded in the machine
        in_vm_t3 "kill $outside"'; t3_code_other_servers | while read -r pid _; do kill "$pid"; done' || true
        # T3's unit stops retrying after 5 failed starts in 300 s, and refuses a start until then
        # unless its failure is reset
        in_vm_t3 'systemctl --user reset-failed t3code.service; systemctl --user start t3code.service' || true
        retry_t3 12 one_server_stable ||
            t3_fail "once the t3 serve started by hand stopped, the T3 Code service didn't become the one T3 Code server, on port 3773"
    fi
fi

# sshd's effective settings for a login by the default user, which the ubuntu step's drop-in sets.
# Made again, in case socket-activated sshd removed /run/sshd since
echo "=== sshd settings ==="
# shellcheck disable=SC2016 # expanded in the machine
if in_vm bash -c 'sudo mkdir -p /run/sshd && sudo sshd -T -C "user=$(id -un),host=localhost,addr=127.0.0.1"' > /dev/null; then
    for setting in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no" \
        "clientaliveinterval 60" "exposeauthinfo yes"; do
        grep -qxF "$setting" <<< "$VM_OUTPUT" || {
            echo "FAIL: sshd -T doesn't show $setting" | tee -a "$LOG"
            FAILED=1
        }
    done
    grep -qE '^allowusers [^ ]+$' <<< "$VM_OUTPUT" || {
        echo "FAIL: sshd -T doesn't limit logins to one user with AllowUsers" | tee -a "$LOG"
        FAILED=1
    }
else
    echo "FAIL: sudo sshd -T failed" | tee -a "$LOG"
    FAILED=1
fi

echo "=== ufw ==="
if ! in_vm sudo ufw status || ! grep -qx 'Status: active' <<< "$VM_OUTPUT"; then
    echo "FAIL: ufw isn't active after a restart" | tee -a "$LOG"
    FAILED=1
fi

# A real login from this Mac, through ufw and sshd's settings, so a change that locks you out fails
# here. orb run doesn't go through sshd. The key is made for the test, and ssh uses it alone, with
# no config or agent, and fails rather than ask for a password. OrbStack resolves
# <machine>.orb.local to the machine.
echo "=== SSH login ==="
KEY_DIR="$(mktemp -d /tmp/dotfiles-test-ubuntu-key.XXXXXX)"
vm_user=""
in_vm id -un > /dev/null && vm_user="$(tail -n 1 <<< "$VM_OUTPUT")"
# shellcheck disable=SC2016 # expanded in the machine
if [ -z "$vm_user" ]; then
    echo "FAIL: couldn't read the machine's user name" | tee -a "$LOG"
    FAILED=1
elif ! ssh-keygen -q -t ed25519 -N "" -C dotfiles-test-ubuntu -f "$KEY_DIR/id_ed25519" >> "$LOG" 2>&1; then
    echo "FAIL: couldn't make a test key with ssh-keygen" | tee -a "$LOG"
    FAILED=1
elif ! in_vm bash -c 'umask 077 && mkdir -p ~/.ssh && printf "%s\n" "$1" >> ~/.ssh/authorized_keys' _ \
    "$(cat "$KEY_DIR/id_ed25519.pub")"; then
    echo "FAIL: couldn't add the test key to the machine's authorized_keys" | tee -a "$LOG"
    FAILED=1
elif ! ssh -F /dev/null -i "$KEY_DIR/id_ed25519" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 "$vm_user@$MACHINE.orb.local" true < /dev/null >> "$LOG" 2>&1; then
    echo "FAIL: couldn't log in over SSH with the test key as $vm_user@$MACHINE.orb.local" | tee -a "$LOG"
    FAILED=1
fi
rm -rf "$KEY_DIR"

# Linger starts the health alert's timer at boot, as it does the T3 Code service
echo "=== Health alert timer ==="
# shellcheck disable=SC2016 # expanded in the machine
if ! in_vm bash -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active dotfiles-health.timer'; then
    echo "FAIL: dotfiles-health.timer isn't active after a restart" | tee -a "$LOG"
    FAILED=1
fi

# The T3 Code service runs under the user manager, with the groups it started with, so a
# transient unit of the same manager runs docker as an agent in a T3 Code thread would
echo "=== Docker from the user manager ==="
# shellcheck disable=SC2016 # expanded in the machine
if ! in_vm bash -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemd-run --user --wait --pipe --quiet docker ps'; then
    echo "FAIL: docker ps doesn't work from the user manager the T3 Code service runs under" | tee -a "$LOG"
    FAILED=1
fi

# Keep versions with the result before cleanup removes the machine. Missing tools are diagnostic
# here; the setup and status checks above already determine whether the test passes.
echo "=== Installed versions ==="
# shellcheck disable=SC2016 # expanded in the machine
in_vm bash -lc '
    cat /etc/os-release
    uname -m
    bash --version | head -n 1
    export PATH="$HOME/.cargo/bin:$PATH"
    for tool in git brew mise rustup node go claude codex t3; do
        command -v "$tool" >/dev/null || continue
        if [ "$tool" = go ]; then go version; else "$tool" --version; fi
    done
' || true

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "PASS: setup worked in a fresh Ubuntu machine, apart from the steps allowed to fail"
else
    echo "FAIL: see the lines above and $LOG"
fi
exit "$FAILED"
