#!/bin/bash
set -euo pipefail

# scripts/test-ubuntu.sh creates an arm64 machine, unless TEST_UBUNTU_ARCH picks another
# architecture such as amd64, the real Ubuntu machine's, and installs unattended-upgrades in it
# before setup. A --status report that needs attention only for an item no machine can satisfy,
# such as a Tailscale or GitHub login, passes; any other item fails the test, as does a failed git
# step. It runs setup twice, then after the restart makes /run/sshd for --status and checks
# sshd -T, ufw, a real SSH login with a test key, the health alert's timer, docker ps under the
# user manager, and that the T3 Code service stays the one server. orb and ssh are stubbed, so no
# machine is created.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
# setup.sh --status prints $SANDBOX/report and exits 3 when it exists. setup.sh prints
# $SANDBOX/setup-report and exits 1 when that exists. sshd -T prints $SANDBOX/sshd, and ufw status
# prints $SANDBOX/ufw. id -un prints tester. ssh logs in unless $SANDBOX/ssh-fails exists, and the
# health timer is active unless $SANDBOX/timer-inactive exists.
printf '%s\n' 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no' \
    'clientaliveinterval 60' 'exposeauthinfo yes' 'allowusers tester' > "$SANDBOX/sshd"
printf '%s\n' 'Status: active' > "$SANDBOX/ufw"
stub orb 'case "$*" in
    *"sshd -T"*) cat "'"$SANDBOX"'/sshd" ;;
    *"ufw status") cat "'"$SANDBOX"'/ufw" ;;
    *" id -un") echo tester ;;
    *"is-active dotfiles-health.timer") [ ! -e "'"$SANDBOX"'/timer-inactive" ] ;;
    # The service'"'"'s MainPID, which the one-server checks kill -9
    *"t3_unit MainPID") echo 4242 ;;
    *"bash setup.sh --status")
        [ -e "'"$SANDBOX"'/report" ] || exit 0
        cat "'"$SANDBOX"'/report"
        exit 3
        ;;
    *"bash setup.sh")
        [ -e "'"$SANDBOX"'/setup-report" ] || exit 0
        cat "'"$SANDBOX"'/setup-report"
        exit 1
        ;;
esac'
stub ssh '[ ! -e "'"$SANDBOX"'/ssh-fails" ]'

# Run the script and remove the log it leaves in /tmp
# e.g. run_test_ubuntu 0 TEST_UBUNTU_ARCH=amd64
run_test_ubuntu() {
    local log expected="$1"
    shift
    assert_exit "$expected" env "$@" bash "$REPO_DIR/scripts/test-ubuntu.sh"
    log="$(printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^Logging to //p')"
    case "$log" in /tmp/dotfiles-test-ubuntu.*) rm -f "$log" ;; esac
}

run_test_ubuntu 0
assert_file_contains "$STUB_LOG" "orb create --arch arm64 ubuntu:resolute dotfiles-test"
assert_file_contains "$STUB_LOG" "apt-get install -y unattended-upgrades"
# Setup runs twice before the restart, then sshd, ufw, the health timer, and Docker under the user
# manager are checked
assert_eq 2 "$(grep -c 'DOTFILES_ALLOW_WORKTREE=1 bash setup.sh$' "$STUB_LOG")" "setup.sh runs"
assert_eq 2 "$(grep -c 'DOTFILES_ALLOW_WORKTREE=1 bash ai_tools/setup.sh$' "$STUB_LOG")" "ai_tools/setup.sh runs"
assert_file_contains "$STUB_LOG" "sshd -T -C"
assert_file_contains "$STUB_LOG" "sudo ufw status"
assert_file_contains "$STUB_LOG" "systemd-run --user --wait --pipe --quiet docker ps"
assert_file_contains "$STUB_LOG" "systemctl --user is-active dotfiles-health.timer"
# The test key goes into the machine's authorized_keys, and ssh logs in with it alone, never asking
assert_file_contains "$STUB_LOG" "authorized_keys"
assert_file_contains "$STUB_LOG" "ssh-ed25519 "
assert_file_contains "$STUB_LOG" "-o BatchMode=yes"
assert_file_contains "$STUB_LOG" "-o IdentitiesOnly=yes"
assert_file_contains "$STUB_LOG" "tester@dotfiles-test.orb.local true"
key="$(sed -n 's/^ssh .* -i \([^ ]*\) .*/\1/p' "$STUB_LOG" | head -n 1)"
[ -n "$key" ] || fail "ssh got no -i <key>"
[ ! -e "$key" ] || fail "the test key $key is left behind"
# The one-server checks restart the service, kill -9 its server, and start a t3 serve by hand
assert_file_contains "$STUB_LOG" "service restart"
assert_file_contains "$STUB_LOG" "kill -9 4242"
assert_file_contains "$STUB_LOG" "setsid -f"
# The restart clears /run/sshd, which sshd -T needs, so it's made again before --status, whose
# sshd and ufw checks read sshd's ports
mkdir_line="$(grep -n 'sudo mkdir -p /run/sshd$' "$STUB_LOG" | head -n 1 | cut -d: -f1)"
status_line="$(grep -n 'bash setup.sh --status$' "$STUB_LOG" | head -n 1 | cut -d: -f1)"
[ -n "$mkdir_line" ] && [ -n "$status_line" ] && [ "$mkdir_line" -lt "$status_line" ] ||
    fail "/run/sshd wasn't made before setup.sh --status"

# Password logins still on, ufw inactive, a failed SSH login, the health timer inactive, and docker
# failing under the user manager each fail it
sed -i.bak '/^passwordauthentication/d' "$SANDBOX/sshd"
echo 'Status: inactive' > "$SANDBOX/ufw"
touch "$SANDBOX/ssh-fails" "$SANDBOX/timer-inactive"
mv "$STUB_DIR/orb" "$STUB_DIR/orb-real"
stub orb 'case "$*" in *"docker ps"*) exit 1 ;; esac; exec "'"$STUB_DIR"'/orb-real" "$@"'
run_test_ubuntu 1
assert_contains "$RUN_OUTPUT" "sshd -T doesn't show passwordauthentication no"
assert_contains "$RUN_OUTPUT" "ufw isn't active after a restart"
assert_contains "$RUN_OUTPUT" "docker ps doesn't work from the user manager"
assert_contains "$RUN_OUTPUT" "couldn't log in over SSH with the test key"
assert_contains "$RUN_OUTPUT" "dotfiles-health.timer isn't active after a restart"
rm "$SANDBOX/ssh-fails" "$SANDBOX/timer-inactive"
assert_not_contains "$RUN_OUTPUT" "doesn't show permitrootlogin no"
mv "$SANDBOX/sshd.bak" "$SANDBOX/sshd"
echo 'Status: active' > "$SANDBOX/ufw"
mv "$STUB_DIR/orb-real" "$STUB_DIR/orb"

: > "$STUB_LOG"
run_test_ubuntu 0 TEST_UBUNTU_ARCH=amd64
assert_file_contains "$STUB_LOG" "orb create --arch amd64 ubuntu:resolute dotfiles-test"

# The ubuntu step needs attention only for the Tailscale login: the test passes
cat > "$SANDBOX/report" << 'EOF'
ubuntu:
  ok         Sleep masked
  missing    Tailscale connected (run sudo tailscale up)
docker:
  ok         Docker Engine from Docker's apt repo

Needs attention: ubuntu. Run: bash setup.sh ubuntu
EOF
run_test_ubuntu 0

# Tailscale's auto-update and operator missing before its first login, which they can't outlast: the
# test passes
cat > "$SANDBOX/report" << 'EOF'
ubuntu:
  missing    Tailscale auto-updates, with test-user as its operator
  missing    Tailscale connected (run sudo tailscale up)

Needs attention: ubuntu. Run: bash setup.sh ubuntu
EOF
run_test_ubuntu 0

# Missing preferences after login must still fail the integration test.
cat > "$SANDBOX/report" << 'EOF'
ubuntu:
  missing    Tailscale auto-updates, with test-user as its operator
  ok         Tailscale connected

Needs attention: ubuntu. Run: bash setup.sh ubuntu
EOF
run_test_ubuntu 1

# Another ubuntu item needs attention too: the test fails, naming the step
cat > "$SANDBOX/report" << 'EOF'
ubuntu:
  missing    Sleep masked
  missing    Tailscale connected (run sudo tailscale up)

Needs attention: ubuntu. Run: bash setup.sh ubuntu
EOF
run_test_ubuntu 1
assert_contains "$RUN_OUTPUT" "the ubuntu step failed or needs attention"

# The same item under another step isn't allowed
cat > "$SANDBOX/report" << 'EOF'
docker:
  missing    Tailscale connected (run sudo tailscale up)

Needs attention: docker. Run: bash setup.sh docker
EOF
run_test_ubuntu 1

# The git step needs attention only for the GitHub login, which needs a person, and for gh's
# credential helper, which gh auth setup-git sets up after it: the test passes
cat > "$SANDBOX/report" << 'EOF'
git:
  ok         ~/.config/git/config
  ok         A ~/.gitconfig for per-machine settings
  missing    Logged in to GitHub with gh
  missing    git uses gh for GitHub credentials
  ok         GitHub SSH remotes go over HTTPS, through gh's credential helper

Needs attention: git. Run: bash setup.sh git
EOF
run_test_ubuntu 0

# Missing git config fails the test, even with the login missing too
cat > "$SANDBOX/report" << 'EOF'
git:
  missing    ~/.config/git/config
  missing    Logged in to GitHub with gh
  missing    git uses gh for GitHub credentials

Needs attention: git. Run: bash setup.sh git
EOF
run_test_ubuntu 1
assert_contains "$RUN_OUTPUT" "the git step failed or needs attention"

# So does a missing credential helper after a login
cat > "$SANDBOX/report" << 'EOF'
git:
  ok         Logged in to GitHub with gh
  missing    git uses gh for GitHub credentials

Needs attention: git. Run: bash setup.sh git
EOF
run_test_ubuntu 1

# So does a gh that isn't installed, which the git step can't check the login without
cat > "$SANDBOX/report" << 'EOF'
git:
  unknown    GitHub login: gh isn't installed

Needs attention: git. Run: bash setup.sh git
EOF
run_test_ubuntu 1
rm "$SANDBOX/report"

# The git step defers the login without failing, so a failed git step, as from a failed install or
# config copy, fails the test. A failed ghostty step doesn't: OrbStack machines have no snapd.
echo "Failed steps: git" > "$SANDBOX/setup-report"
run_test_ubuntu 1
assert_contains "$RUN_OUTPUT" "setup.sh : the git step failed or needs attention"
echo "Failed steps: ghostty" > "$SANDBOX/setup-report"
run_test_ubuntu 0
test_done
