#!/bin/bash
set -euo pipefail

# ubuntu/health-alert.sh's status and boot pushes, which the ubuntu step's user units run, and the
# step's status of their last runs. curl, sleep, systemctl, and the two runners are stubs.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox
export DOTFILES_NTFY_URL_FILE="$SANDBOX/ntfy-url" DOTFILES_BOOT_ID_FILE="$SANDBOX/boot_id"

# A copy of the script in a repo whose runners print $SANDBOX/out/<runner> and exit with
# $SANDBOX/exit/<runner>, 0 by default, logging how they were called
REPO="$SANDBOX/repo"
mkdir -p "$REPO/lib" "$REPO/ubuntu/lib" "$REPO/ai_tools" "$SANDBOX/out" "$SANDBOX/exit"
cp "$REPO_DIR/ubuntu/health-alert.sh" "$REPO/ubuntu/"
cp "$REPO_DIR/lib/common.sh" "$REPO/lib/"
cp "$REPO_DIR/ubuntu/lib/ntfy.sh" "$REPO_DIR/ubuntu/lib/paths.sh" "$REPO/ubuntu/lib/"
for runner in setup ai_tools; do
    script="$REPO/setup.sh"
    [ "$runner" == setup ] || script="$REPO/ai_tools/setup.sh"
    cat > "$script" << EOF
echo "$runner \$*" >> "\$STUB_LOG"
cat "$SANDBOX/out/$runner" 2> /dev/null
exit "\$(cat "$SANDBOX/exit/$runner" 2> /dev/null || echo 0)"
EOF
done
ALERT="$REPO/ubuntu/health-alert.sh"
STATE="$HOME/.local/state/dotfiles/health-alert"
# Move the last push's time back by $1 seconds
age_state() {
    local time hash
    read -r time hash < "$STATE"
    echo "$((time - $1)) $hash" > "$STATE"
}
# curl logs the config it reads from stdin with -K -, and the message it sends
stub curl 'case " $* " in *" -K - "*) sed "s/^/curl config: /" >> "$STUB_LOG" ;; esac
[ ! -e "'"$SANDBOX"'/curl-fails" ] || { echo "curl: (6) Could not resolve host: ntfy.sh" >&2; exit 6; }'
stub sleep

# A status report as run_steps prints it, with one step needing attention
cat > "$SANDBOX/out/setup" << 'EOF'
=== dotfiles status ===
git:
  ok         ~/.gitconfig
ubuntu:
  ok         Sleep masked
  missing    Tailscale connected (run sudo tailscale up)
  unknown    Free space on /: df couldn't read it
  missing    Free space on /home: 8.3 GiB of 100.0 GiB (8%)
  info       ntfy URL set
  unverified Disk health (SMART): reading it needs root; run sudo -v, then status, to check it

Needs attention: ubuntu. Run: bash setup.sh ubuntu
EOF
cat > "$SANDBOX/out/ai_tools" << 'EOF'
=== AI tools status ===
claude-code:
  ok         Claude Code
EOF

# No URL saved: nothing runs, nothing is pushed
echo 3 > "$SANDBOX/exit/setup"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_not_contains "$STUB_LOG" "curl"
assert_file_not_contains "$STUB_LOG" "setup"

# A URL saved, and setup.sh needing attention: both runners run with --status --quick, and the
# push lists the Needs attention line and the missing and unknown items, under their step
echo "https://ntfy.sh/secret-topic" > "$DOTFILES_NTFY_URL_FILE"
: > "$STUB_LOG"
before="$(date +%s)"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "setup --status --quick"
assert_file_contains "$STUB_LOG" "ai_tools --status --quick"
assert_file_contains "$STUB_LOG" 'curl config: url = "https://ntfy.sh/secret-topic"'
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
assert_file_contains "$STUB_LOG" "Needs attention: ubuntu. Run: bash setup.sh ubuntu"
assert_file_contains "$STUB_LOG" "ubuntu: Tailscale connected (run sudo tailscale up)"
assert_file_contains "$STUB_LOG" "ubuntu: Free space on /: df couldn't read it"
assert_file_not_contains "$STUB_LOG" "Sleep masked"
assert_file_not_contains "$STUB_LOG" "ntfy URL set"
assert_file_not_contains "$STUB_LOG" "Disk health"
assert_file_not_contains "$STUB_LOG" "Claude Code"
# An item only root could check comes back unverified, so the push says what wasn't checked
assert_file_contains "$STUB_LOG" "Not checked here, since they need root: ufw's rules, sshd's effective settings, SMART health, NUT's and Docker's config files, and unattended-upgrades' settings when only root can read them. Run sudo -v, then just status, to check them."
if grep '^curl -' "$STUB_LOG" | grep -q secret-topic; then
    fail "curl's arguments name the ntfy topic"
fi

# The push is recorded as "<time> <hash>"
[ -f "$STATE" ] || fail "the first push didn't write $STATE"
read -r first_time first_hash < "$STATE"
[ "$first_time" -ge "$before" ] && [ "$first_time" -le "$(date +%s)" ] ||
    fail "the first push recorded the time $first_time"
[ -n "$first_hash" ] || fail "the first push recorded no hash"
first_state="$(cat "$STATE")"

# The same message a day later isn't pushed again, and says until when. Numbers that moved, such as
# free space, don't make it a new message.
age_state 86400
sed -i.orig 's/8\.3 GiB/8.1 GiB/' "$SANDBOX/out/setup"
rm "$SANDBOX/out/setup.orig"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "Unchanged since the last push on "
assert_contains "$RUN_OUTPUT" "; not pushing again until "
assert_file_not_contains "$STUB_LOG" "curl"

# ...but is a week later
age_state 604800
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
read -r time hash < "$STATE"
assert_eq "$first_hash" "$hash" "the hash after the weekly push"
[ "$time" -ge "$first_time" ] || fail "the weekly push didn't record its time"

# Exit 1, a failed step, pushes too, with the failed steps
echo 0 > "$SANDBOX/exit/setup"
echo 1 > "$SANDBOX/exit/ai_tools"
printf '%s\n' "=== AI tools status ===" "codex:" "  missing    Codex" "" "Failed steps: t3-code" > "$SANDBOX/out/ai_tools"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "Failed steps: t3-code"
assert_file_contains "$STUB_LOG" "codex: Codex"
assert_file_not_contains "$STUB_LOG" "Tailscale"

# All set up after a push: one all-clear, then nothing. Any other exit code: no push. A runner
# that couldn't run is reported, and fails the service, so systemctl --user status shows it.
echo 0 > "$SANDBOX/exit/ai_tools"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "-H Title: All clear on $(hostname)"
assert_file_contains "$STUB_LOG" "-H Tags: white_check_mark"
assert_file_contains "$STUB_LOG" "--data-raw Nothing needs attention any more."
assert_contains "$(cat "$STATE")" " clear"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "Nothing needs attention."
assert_file_not_contains "$STUB_LOG" "curl"
# Never pushed: nothing to clear
rm "$STATE"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_not_contains "$STUB_LOG" "curl"
echo "$first_state" > "$STATE"
# A runner that crashes checks nothing, so it's pushed, and the unit still fails
cp "$SANDBOX/out/setup" "$SANDBOX/out/setup.report"
printf '%s\n' "lib/common.sh: line 12: syntax error near unexpected token \`<<<'" "" > "$SANDBOX/out/setup"
echo 2 > "$SANDBOX/exit/setup"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "setup.sh --status --quick exited 2"
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
assert_file_contains "$STUB_LOG" "Health check couldn't run: setup.sh exited 2"
assert_file_contains "$STUB_LOG" "setup.sh's last output: lib/common.sh: line 12: syntax error near unexpected token \`<<<'"
# Its last line stays out of the hash, so a line that changes each run, such as one naming a temp
# file, isn't pushed again
printf '%s\n' "mktemp: /tmp/tmp.Xyz: something else" > "$SANDBOX/out/setup"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "Unchanged since the last push"
assert_file_not_contains "$STUB_LOG" "curl"
# A runner killed with no output, as by the OOM killer, still gets its push
echo "$first_state" > "$STATE"
: > "$SANDBOX/out/setup"
echo 137 > "$SANDBOX/exit/setup"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "Health check couldn't run: setup.sh exited 137"
assert_file_not_contains "$STUB_LOG" "last output"
echo 0 > "$SANDBOX/exit/setup"
mv "$SANDBOX/out/setup.report" "$SANDBOX/out/setup"

# A syntax error in lib/common.sh, which the script sources, is pushed as one the runners hit, and
# fails the service
cp "$REPO/lib/common.sh" "$SANDBOX/common.sh"
echo 'if then' >> "$REPO/lib/common.sh"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "lib/common.sh has a syntax error"
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
assert_file_contains "$STUB_LOG" "Health check couldn't run: lib/common.sh has a syntax error"
assert_file_contains "$STUB_LOG" "bash -n's last output: "
assert_file_not_contains "$STUB_LOG" "setup --status"
cp "$SANDBOX/common.sh" "$REPO/lib/common.sh"

# A failed push fails the service, the output leaves the topic out, and the state stays as it was.
# A changed message is pushed though the last push was recent.
echo 3 > "$SANDBOX/exit/setup"
touch "$SANDBOX/curl-fails"
recent="$(date +%s) 12345"
echo "$recent" > "$STATE"
assert_exit 1 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "Couldn't push"
assert_not_contains "$RUN_OUTPUT" "secret-topic"
assert_eq "$recent" "$(cat "$STATE")" "the state after a failed push"
rm "$SANDBOX/curl-fails"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
assert_not_contains "$(cat "$STATE")" " 12345"

# A state file that can't be read counts as never pushed, and one that can't be written only warns
rm "$STATE"
mkdir "$STATE"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
assert_contains "$RUN_OUTPUT" "Couldn't save the last push to $STATE."
rmdir "$STATE"
echo 0 > "$SANDBOX/exit/setup"

# An unreadable URL file: the service fails, saying how to fix it
chmod 000 "$DOTFILES_NTFY_URL_FILE"
if [ ! -r "$DOTFILES_NTFY_URL_FILE" ]; then
    assert_exit 1 "$BASH" "$ALERT" status
    assert_contains "$RUN_OUTPUT" "Save the URL again with just alerts."
fi
chmod 644 "$DOTFILES_NTFY_URL_FILE"

# A long report is cut to fit one ntfy message, saying how many lines were left out
echo 3 > "$SANDBOX/exit/setup"
{
    echo "ubuntu:"
    for i in $(seq 1 200); do echo "  missing    Item number $i with some words after it"; done
} > "$SANDBOX/out/setup"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "ubuntu: Item number 1 with"
assert_file_not_contains "$STUB_LOG" "Item number 200 "
assert_file_contains "$STUB_LOG" "more lines; bash setup.sh --status lists them"
# Without such an item, the push doesn't say so
assert_file_not_contains "$STUB_LOG" "Not checked here"
echo 0 > "$SANDBOX/exit/setup"

# boot pushes that the machine started, retrying while the network comes up
echo boot-1 > "$DOTFILES_BOOT_ID_FILE"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_file_contains "$STUB_LOG" "-H Title: $(hostname) started"
assert_file_contains "$STUB_LOG" "--data-raw $(hostname) started at "
assert_file_not_contains "$STUB_LOG" "sleep"
# Once per boot: the user manager starting it again, as after a restart of user@<uid>, pushes
# nothing
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_contains "$RUN_OUTPUT" "Already pushed the boot notice for this boot."
assert_file_not_contains "$STUB_LOG" "curl"
# A new boot pushes again, as does every start when the boot's ID can't be read
echo boot-2 > "$DOTFILES_BOOT_ID_FILE"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_file_contains "$STUB_LOG" "-H Title: $(hostname) started"
rm "$DOTFILES_BOOT_ID_FILE"
for _ in 1 2; do
    : > "$STUB_LOG"
    assert_exit 0 "$BASH" "$ALERT" boot
    assert_file_contains "$STUB_LOG" "-H Title: $(hostname) started"
done
echo boot-3 > "$DOTFILES_BOOT_ID_FILE"
touch "$SANDBOX/curl-fails"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" boot
assert_contains "$RUN_OUTPUT" "Couldn't push the boot notice to ntfy after 20 tries"
assert_eq 20 "$(grep -c '^curl -' "$STUB_LOG")" "the boot notice's tries"
assert_eq 19 "$(grep -c '^sleep 10' "$STUB_LOG")" "the waits between them"
rm "$SANDBOX/curl-fails"
# A failed push isn't recorded, so the next start tries again
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_file_contains "$STUB_LOG" "-H Title: $(hostname) started"

# No URL saved: boot pushes nothing. No argument prints the usage and exits 2.
rm "$DOTFILES_NTFY_URL_FILE"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_file_not_contains "$STUB_LOG" "curl"
assert_exit 2 "$BASH" "$ALERT"

# --- the ubuntu step's status: a failed last run of an installed alert service ---
# systemctl --user show -p Result --value prints $SANDBOX/result/<unit>, empty when it's missing
load_script ubuntu/install.sh
ubuntu_sandbox_paths
HEALTH_UNIT_DIR="$SANDBOX/units"
mkdir -p "$HEALTH_UNIT_DIR" "$SANDBOX/result"
stub systemctl '[ "$*" != "--user show -p Result --value ${!#}" ] || cat "'"$SANDBOX"'/result/${!#}" 2> /dev/null || true'
last_runs() {
    status_last_run "Daily health alert's last run" dotfiles-health.service
    status_last_run "Boot notice's last run" dotfiles-boot-notice.service
}
# Not installed: not checked
echo exit-code > "$SANDBOX/result/dotfiles-health.service"
run last_runs
assert_eq "" "$RUN_OUTPUT" "the last runs of units that aren't installed"
assert_file_not_contains "$STUB_LOG" "systemctl"
touch "$HEALTH_UNIT_DIR/dotfiles-health.service" "$HEALTH_UNIT_DIR/dotfiles-boot-notice.service"
run last_runs
assert_contains "$RUN_OUTPUT" "missing    Daily health alert's last run: its last run failed (exit-code); journalctl --user -u dotfiles-health.service says why"
assert_not_contains "$RUN_OUTPUT" "Boot notice"
echo success > "$SANDBOX/result/dotfiles-health.service"
echo timeout > "$SANDBOX/result/dotfiles-boot-notice.service"
run last_runs
assert_not_contains "$RUN_OUTPUT" "Daily health alert"
assert_contains "$RUN_OUTPUT" "missing    Boot notice's last run: its last run failed (timeout); journalctl --user -u dotfiles-boot-notice.service says why"

test_done
