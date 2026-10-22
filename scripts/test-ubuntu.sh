#!/bin/bash
set -uo pipefail

# Run both setups twice in a throwaway OrbStack Ubuntu machine, restart, and check status and services.

MACHINE=dotfiles-test
# x86_64, as the real machine is: through Rosetta on Apple Silicon
ARCH="${TEST_UBUNTU_ARCH:-amd64}"
REPO="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Steps that can't work in OrbStack (ghostty: no snapd). The image has no GNOME desktop, so the
# desktop steps skip their GNOME parts.
ALLOWED_SETUP=(ghostty)
ALLOWED_AI=()
# Status items that need a person, a tailnet, or root
ALLOWED_ITEMS=(
    "ubuntu: Tailscale connected (run sudo tailscale up)"
    "git: Logged in to GitHub with gh"
    "claude-code: Signed in to Claude Code: run claude auth login"
    "codex: Signed in to Codex: run codex login --device-auth (see ai_tools/README.md → Manual steps)"
    "t3-code: T3 Connect linked and publishing agent activity: run t3 connect --headless, then t3 connect publish and t3 service restart (see ai_tools/README.md → Manual steps)"
    "t3-code: T3 Code's browser can run in Chrome's sandbox: run sudo ~/.local/bin/t3 browser setup"
)
# "<step>: <item pattern>|<item it waits for>": allowed only while the other item is missing
ALLOWED_BEFORE=(
    "ubuntu: Tailscale auto-updates, with * as its operator|Tailscale connected (run sudo tailscale up)"
    "git: git uses gh for GitHub credentials|Logged in to GitHub with gh"
    "git: GitHub SSH remotes go over HTTPS, through gh's credential helper (*)|Logged in to GitHub with gh"
)
# t3-code's status lines for a t3 serve started by hand, and for the service once it's gone
T3_MANUAL_SERVE_STATUS='^  missing +No T3 Code server outside t3code\.service: PID [0-9]+, a t3 serve started by hand \('
T3_IDLE_SERVICE_STATUS='^  missing +T3 Code service running a server: it runs none'

if ! command -v orb &>/dev/null; then
    echo "OrbStack's orb command isn't installed. Install OrbStack (brew install --cask orbstack)." >&2
    exit 1
fi
if orb list -q | grep -x "$MACHINE" > /dev/null; then
    echo "An OrbStack machine named $MACHINE already exists. Delete it with: orb delete -f $MACHINE" >&2
    exit 1
fi

# Private dir, so another user can't plant a link in a shared /tmp
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test-ubuntu.XXXXXX")"
LOG="$LOG_DIR/log"
VM_OUT_FILE="$LOG_DIR/step"
KEY_DIR=""
echo "Logging to $LOG"

# Set before orb create so an interrupted create cleans up; cleared if create fails (another run's machine).
OWN_MACHINE=false

# shellcheck disable=SC2329 # the EXIT trap runs it
cleanup() {
    if "$OWN_MACHINE" && orb list -q | grep -x "$MACHINE" > /dev/null; then
        echo "Deleting the $MACHINE machine..."
        orb delete -f "$MACHINE" >> "$LOG" 2>&1 || echo "Couldn't delete it. Run: orb delete -f $MACHINE" >&2
    fi
    rm -f "$VM_OUT_FILE"
    [ -z "$KEY_DIR" ] || rm -rf "$KEY_DIR"
    echo "Log: $LOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# OrbStack mounts the repo at the same path. Output is kept in $VM_OUTPUT.
in_vm() {
    local status
    echo "+ $*" >> "$LOG"
    : > "$VM_OUT_FILE"
    orb run -m "$MACHINE" -w "$REPO" "$@" < /dev/null 2>&1 | tee -a "$LOG" "$VM_OUT_FILE"
    status=${PIPESTATUS[0]}
    VM_OUTPUT="$(cat "$VM_OUT_FILE")"
    return "$status"
}

# As the machine's user with its user manager, which systemctl --user needs: orb run starts no
# login session
in_vm_user() {
    # shellcheck disable=SC2016 # expanded in the machine
    in_vm bash -c 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; "$@"' bash "$@"
}

FAILED=0

fail() {
    echo "FAIL: $1" | tee -a "$LOG"
    FAILED=1
}

# Succeeds when the step's report has missing or unknown items, all of them allowed.
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

# A runner that exits non-zero without listing a failed step fails.
check_runner() {
    local what="$1" status="$2" step listed attention
    shift 2
    listed="$(printf '%s\n' "$VM_OUTPUT" | sed -nE 's/^(Failed steps|Needs attention): ([^.]*).*/\2/p')"
    attention="$(printf '%s\n' "$VM_OUTPUT" | sed -nE 's/^Needs attention: ([^.]*).*/\1/p')"
    if [ "$status" -ne 0 ] && [ -z "$listed" ]; then
        fail "$what exited $status"
    fi
    for step in $listed; do
        if [[ " $attention " == *" $step "* ]] && only_allowed_items "$step"; then
            continue
        fi
        if [[ " $* " != *" $step "* ]]; then
            fail "$what: the $step step failed or needs attention"
        fi
    done
}

run_runner() {
    local runner="$1" mode="$2" status=0
    shift 2
    echo "=== $runner $mode ==="
    if [ -n "$mode" ]; then
        # The health alerts were installed from a worktree
        in_vm env DOTFILES_ALLOW_WORKTREE=1 bash "$runner" "$mode" || status=$?
    else
        # orb run bypasses sshd, so no SSH session proves a key login; the opt-in turns password logins off.
        in_vm env DOTFILES_ASSUME_YES=1 DOTFILES_SSH_KEY_ONLY=1 DOTFILES_ALLOW_WORKTREE=1 bash "$runner" || status=$?
    fi
    check_runner "$runner $mode" "$status" "$@"
}

echo "Creating the $MACHINE machine (Ubuntu 26.04, $ARCH)..."
OWN_MACHINE=true
if ! orb create --arch "$ARCH" ubuntu:resolute "$MACHINE" >> "$LOG" 2>&1; then
    OWN_MACHINE=false
    echo "Couldn't create the machine. See $LOG." >&2
    exit 1
fi

# Ubuntu Desktop ships it; the image doesn't
echo "=== unattended-upgrades ==="
in_vm sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades ||
    fail "couldn't install unattended-upgrades"

for pass in 1 2; do
    echo "=== Setup, pass $pass ==="
    run_runner setup.sh "" ${ALLOWED_SETUP[@]+"${ALLOWED_SETUP[@]}"}
    run_runner ai_tools/setup.sh "" ${ALLOWED_AI[@]+"${ALLOWED_AI[@]}"}
done

echo "Restarting the $MACHINE machine..."
orb restart "$MACHINE" >> "$LOG" 2>&1 || fail "couldn't restart the machine"

# The restart clears /run/sshd and orb run doesn't recreate it; without it sshd -T fails.
in_vm sudo mkdir -p /run/sshd > /dev/null || fail "couldn't make /run/sshd"
run_runner setup.sh --status ${ALLOWED_SETUP[@]+"${ALLOWED_SETUP[@]}"}
run_runner ai_tools/setup.sh --status ${ALLOWED_AI[@]+"${ALLOWED_AI[@]}"}

echo "=== T3 Code service ==="
active=false
for _ in $(seq 1 12); do
    if in_vm_user systemctl --user is-active t3code.service; then
        active=true
        break
    fi
    sleep 5
done
if ! "$active"; then
    fail "the T3 Code service isn't active after a restart"
fi

# Uses the t3-code step's functions, so servers are counted as its status counts them.
# shellcheck disable=SC2016 # expanded in the machine
T3_VM_LIB='
source ai_tools/t3-code/install.sh
set +eu +o pipefail
t3_unit() { systemctl --user show -p "$1" --value t3code.service; }
port_pids() { ss -Htlnp "sport = :$T3_CODE_PORT" | grep -o "pid=[0-9]*" | cut -d= -f2 | sort -u; }
one_server() {
    local pids others
    pids="$(port_pids)"
    others="$(t3_code_other_servers)"
    echo "service $(t3_unit ActiveState)/$(t3_unit SubState), MainPID $(t3_unit MainPID); on $T3_CODE_PORT: $(echo ${pids:-nothing}); others: ${others:-none}"
    t3_code_service_active && [ -n "$pids" ] && [ "$(wc -l <<< "$pids")" -eq 1 ] &&
        t3_code_in_service_cgroup "$pids" && [ -z "$others" ]
}
# Holds 3 s, since a server that crashes on start shows active between restarts. $1: old MainPID.
one_server_stable() {
    local first
    one_server && first="$(port_pids)" && sleep 3 && one_server && [ "$(port_pids)" == "$first" ] &&
        [ "$(t3_unit MainPID)" != "${1:-}" ]
}
outside_listener() {
    local pids
    pids="$(port_pids)"
    echo "on $T3_CODE_PORT: $(echo ${pids:-nothing})"
    [ -n "$pids" ] && [ "$(wc -l <<< "$pids")" -eq 1 ] && ! t3_code_in_service_cgroup "$pids" &&
        echo "outside=$pids"
}
# T3 locks its data, so the service launcher stays up with no server while another holds it.
service_shut_out() {
    echo "service $(t3_unit ActiveState)/$(t3_unit SubState), MainPID $(t3_unit MainPID); on $T3_CODE_PORT: $(echo $(port_pids))"
    t3_code_service_serving_nothing && [ "$(port_pids)" == "$1" ]
}
'

in_vm_t3() {
    in_vm_user bash -c "$T3_VM_LIB"$'\n'"$1"
}

retry_t3() {
    local tries="$1" _
    for _ in $(seq 1 "$tries"); do
        in_vm_t3 "$2" > /dev/null && return 0
        sleep 5
    done
    return 1
}

t3_main_pid() {
    in_vm_t3 't3_unit MainPID' > /dev/null
    tail -n 1 <<< "$VM_OUTPUT"
}

echo "=== One T3 Code server ==="
# shellcheck disable=SC2016 # expanded in the machine
if ! in_vm_t3 'command -v ss && [ -x "$HOME/.local/bin/t3" ]' > /dev/null; then
    fail "the one-server checks need ss and ~/.local/bin/t3 in the machine"
else
    retry_t3 12 one_server_stable || fail "the T3 Code service isn't the one T3 Code server, on port 3773"

    # On failure, restart with systemctl so the later checks still run.
    old_pid="$(t3_main_pid)"
    # shellcheck disable=SC2016 # expanded in the machine
    if ! in_vm_t3 '"$HOME/.local/bin/t3" service restart'; then
        fail "t3 service restart failed"
        in_vm_t3 'systemctl --user restart t3code.service' || true
    fi
    retry_t3 12 "one_server_stable $old_pid" ||
        fail "after t3 service restart, the restarted service isn't the one T3 Code server, on port 3773"

    in_vm_t3 't3_unit Restart' > /dev/null
    if [ "$(tail -n 1 <<< "$VM_OUTPUT")" == no ]; then
        fail "t3code.service has Restart=no, so systemd won't restart a server that dies"
    fi
    old_pid="$(t3_main_pid)"
    # kill -9 0 would kill orb run's own process group
    if ! [[ "$old_pid" =~ ^[1-9][0-9]*$ ]]; then
        fail "the T3 Code service has no server to kill -9 (MainPID ${old_pid:-unset})"
    elif ! in_vm_t3 "kill -9 $old_pid"; then
        fail "couldn't kill -9 the T3 Code service's server (PID $old_pid)"
    else
        retry_t3 12 "one_server_stable $old_pid" ||
            fail "after a kill -9 of its server, the restarted service isn't the one T3 Code server, on port 3773"
    fi

    # setsid -f detaches it so orb run returns.
    outside=""
    # shellcheck disable=SC2016 # expanded in the machine
    if ! in_vm_t3 'systemctl --user stop t3code.service && ! t3_code_service_active'; then
        fail "couldn't stop the T3 Code service"
    elif ! in_vm_t3 'T3CODE_PORT=$T3_CODE_PORT T3CODE_TELEMETRY_ENABLED=false setsid -f "$HOME/.local/bin/t3" serve > /tmp/t3-manual-serve.log 2>&1 < /dev/null'; then
        fail "couldn't start t3 serve by hand"
    elif ! retry_t3 12 outside_listener; then
        fail "the t3 serve started by hand isn't listening on port 3773; see /tmp/t3-manual-serve.log in the machine"
    else
        in_vm_t3 outside_listener > /dev/null
        outside="$(sed -n 's/^outside=//p' <<< "$VM_OUTPUT")"
    fi
    if [ -n "$outside" ]; then
        in_vm_t3 'systemctl --user start t3code.service' || true
        retry_t3 8 "service_shut_out $outside" ||
            fail "the T3 Code service ran a server, or left port 3773, while a t3 serve started by hand had its data"
        in_vm_user bash ai_tools/setup.sh --status t3-code > /dev/null || true
        grep -qE "$T3_MANUAL_SERVE_STATUS" <<< "$VM_OUTPUT" ||
            fail "t3-code's status doesn't flag the t3 serve started by hand"
        # shellcheck disable=SC2016 # expanded in the machine
        in_vm_t3 "kill $outside"'; t3_code_other_servers | while read -r pid _; do kill "$pid"; done' || true
        # shellcheck disable=SC2016 # expanded in the machine
        retry_t3 12 '[ -z "$(t3_code_other_servers)" ]' ||
            fail "the t3 serve started by hand didn't stop"
        in_vm_user bash ai_tools/setup.sh --status t3-code > /dev/null || true
        grep -qE "$T3_IDLE_SERVICE_STATUS" <<< "$VM_OUTPUT" ||
            fail "once the t3 serve started by hand stopped, t3-code's status doesn't flag the service that runs no server"
        in_vm_user bash ai_tools/setup.sh t3-code > /dev/null ||
            fail "once the t3 serve started by hand stopped, the t3-code step failed"
        retry_t3 12 one_server_stable ||
            fail "once the t3 serve started by hand stopped and the t3-code step ran, the T3 Code service isn't the one T3 Code server, on port 3773"
    fi
fi

# Socket-activated sshd may have removed /run/sshd again.
echo "=== sshd settings ==="
# shellcheck disable=SC2016 # expanded in the machine
if in_vm bash -c 'sudo mkdir -p /run/sshd && sudo sshd -T -C "user=$(id -un),host=localhost,addr=127.0.0.1"' > /dev/null; then
    for setting in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no" \
        "clientaliveinterval 60" "exposeauthinfo yes"; do
        grep -qxF "$setting" <<< "$VM_OUTPUT" || fail "sshd -T doesn't show $setting"
    done
    grep -qE '^allowusers [^ ]+$' <<< "$VM_OUTPUT" ||
        fail "sshd -T doesn't limit logins to one user with AllowUsers"
else
    fail "sudo sshd -T failed"
fi

echo "=== ufw ==="
if ! in_vm sudo ufw status || ! grep -qx 'Status: active' <<< "$VM_OUTPUT"; then
    fail "ufw isn't active after a restart"
fi

# A real login through ufw and sshd, so a lockout fails here.
echo "=== SSH login ==="
KEY_DIR="$(mktemp -d /tmp/dotfiles-test-ubuntu-key.XXXXXX)"
vm_user=""
in_vm id -un > /dev/null && vm_user="$(tail -n 1 <<< "$VM_OUTPUT")"
# shellcheck disable=SC2016 # expanded in the machine
if [ -z "$vm_user" ]; then
    fail "couldn't read the machine's user name"
elif ! ssh-keygen -q -t ed25519 -N "" -C dotfiles-test-ubuntu -f "$KEY_DIR/id_ed25519" >> "$LOG" 2>&1; then
    fail "couldn't make a test key with ssh-keygen"
elif ! in_vm bash -c 'umask 077 && mkdir -p ~/.ssh && printf "%s\n" "$1" >> ~/.ssh/authorized_keys' _ \
    "$(cat "$KEY_DIR/id_ed25519.pub")"; then
    fail "couldn't add the test key to the machine's authorized_keys"
elif ! ssh -F /dev/null -i "$KEY_DIR/id_ed25519" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 "$vm_user@$MACHINE.orb.local" true < /dev/null >> "$LOG" 2>&1; then
    fail "couldn't log in over SSH with the test key as $vm_user@$MACHINE.orb.local"
fi
rm -rf "$KEY_DIR"

echo "=== Health alert timer ==="
if ! in_vm_user systemctl --user is-active dotfiles-health.timer; then
    fail "dotfiles-health.timer isn't active after a restart"
fi

# As an agent in a T3 Code thread would, under the user manager's groups
echo "=== Docker from the user manager ==="
if ! in_vm_user systemd-run --user --wait --pipe --quiet docker ps; then
    fail "docker ps doesn't work from the user manager the T3 Code service runs under"
fi

# Diagnostic only; never fails the test.
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
