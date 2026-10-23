#!/bin/bash
set -euo pipefail

# ubuntu/health-alert.sh: what status needs attention pushed to ntfy without repeats, a runner that
# couldn't run or a missing repo, the boot notice, and the ubuntu step's report of a failed last run.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"

setup_sandbox
export DOTFILES_NTFY_URL_FILE="$SANDBOX/ntfy-url" DOTFILES_BOOT_ID_FILE="$SANDBOX/boot_id"

# Runners print $SANDBOX/out/<runner> and exit with $SANDBOX/exit/<runner>
export DOTFILES_REPO="$SANDBOX/repo"
REPO="$DOTFILES_REPO"
mkdir -p "$REPO/ai_tools" "$SANDBOX/out" "$SANDBOX/exit"
install_health_alert "$SANDBOX/health-alert"
for runner in setup ai_tools; do
    script="$REPO/setup.sh"
    [ "$runner" == setup ] || script="$REPO/ai_tools/setup.sh"
    cat > "$script" << EOF
echo "$runner \$*" >> "\$STUB_LOG"
cat "$SANDBOX/out/$runner" 2> /dev/null
exit "\$(cat "$SANDBOX/exit/$runner" 2> /dev/null || echo 0)"
EOF
done
ALERT="$SANDBOX/health-alert/health-alert.sh"
STATE="$HOME/.local/state/dotfiles/health-alert"
age_state() {
    local time hash
    read -r time hash < "$STATE"
    echo "$((time - $1)) $hash" > "$STATE"
}
stub_ntfy_curl
stub sleep

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

echo 3 > "$SANDBOX/exit/setup"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_not_contains "$STUB_LOG" "curl"
assert_file_not_contains "$STUB_LOG" "setup"

echo "https://ntfy.sh/secret-topic" > "$DOTFILES_NTFY_URL_FILE"
: > "$STUB_LOG"
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
# Root-only items come back unverified, so the push says what wasn't checked
assert_file_contains "$STUB_LOG" "Not checked here, since they need root"
read -r first_time first_hash < "$STATE"
first_state="$(cat "$STATE")"

# Moved numbers, such as free space, don't make a new message
age_state 86400
sed -i.orig 's/8\.3 GiB/8.1 GiB/' "$SANDBOX/out/setup"
rm "$SANDBOX/out/setup.orig"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "Unchanged since the last push on "
assert_contains "$RUN_OUTPUT" "; not pushing again until "
assert_file_not_contains "$STUB_LOG" "curl"

age_state 604800
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
read -r time hash < "$STATE"
assert_eq "$first_hash" "$hash" "the hash after the weekly push"
[ "$time" -ge "$first_time" ] || fail "the weekly push didn't record its time"

echo 0 > "$SANDBOX/exit/setup"
echo 1 > "$SANDBOX/exit/ai_tools"
printf '%s\n' "=== AI tools status ===" "codex:" "  missing    Codex" "" "Failed steps: t3-code" > "$SANDBOX/out/ai_tools"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "Failed steps: t3-code"
assert_file_contains "$STUB_LOG" "codex: Codex"
assert_file_not_contains "$STUB_LOG" "Tailscale"

# After a push, one all-clear, then nothing
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
rm "$STATE"
assert_exit 0 "$BASH" "$ALERT" status
assert_file_not_contains "$STUB_LOG" "curl"
echo "$first_state" > "$STATE"
# A crashed runner checks nothing, so it's pushed and the unit fails
cp "$SANDBOX/out/setup" "$SANDBOX/out/setup.report"
printf '%s\n' "lib/common.sh: line 12: syntax error near unexpected token \`<<<'" "" > "$SANDBOX/out/setup"
echo 2 > "$SANDBOX/exit/setup"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "setup.sh --status --quick exited 2"
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
assert_file_contains "$STUB_LOG" "Health check couldn't run: setup.sh exited 2"
assert_file_contains "$STUB_LOG" "setup.sh's last output: lib/common.sh: line 12: syntax error near unexpected token \`<<<'"
# The last line stays out of the hash, since it may change each run, e.g. a temp file name
printf '%s\n' "mktemp: /tmp/tmp.Xyz: something else" > "$SANDBOX/out/setup"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" status
assert_contains "$RUN_OUTPUT" "Unchanged since the last push"
assert_file_not_contains "$STUB_LOG" "curl"
# A runner killed with no output, as by the OOM killer
echo "$first_state" > "$STATE"
: > "$SANDBOX/out/setup"
echo 137 > "$SANDBOX/exit/setup"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "Health check couldn't run: setup.sh exited 137"
assert_file_not_contains "$STUB_LOG" "last output"
echo 0 > "$SANDBOX/exit/setup"
mv "$SANDBOX/out/setup.report" "$SANDBOX/out/setup"

# No repo where the alert runs status
mv "$REPO" "$SANDBOX/repo.away"
: > "$STUB_LOG"
assert_exit 1 "$BASH" "$ALERT" status
assert_file_contains "$STUB_LOG" "-H Title: Needs attention on $(hostname)"
assert_file_contains "$STUB_LOG" "--data-raw Health check couldn't run: no repo at $REPO"
mv "$SANDBOX/repo.away" "$REPO"

# A failed push leaves the state alone; a changed message is pushed despite a recent push
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

echo 0 > "$SANDBOX/exit/setup"

chmod 000 "$DOTFILES_NTFY_URL_FILE"
if [ ! -r "$DOTFILES_NTFY_URL_FILE" ]; then
    assert_exit 1 "$BASH" "$ALERT" status
    assert_contains "$RUN_OUTPUT" "Save the URL again with just alerts."
fi
chmod 644 "$DOTFILES_NTFY_URL_FILE"


# boot retries while the network comes up
echo boot-1 > "$DOTFILES_BOOT_ID_FILE"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_file_contains "$STUB_LOG" "-H Title: $(hostname) started"
assert_file_contains "$STUB_LOG" "--data-raw $(hostname) started at "
assert_file_not_contains "$STUB_LOG" "sleep"
# Once per boot, even if the user manager restarts it
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_contains "$RUN_OUTPUT" "Already pushed the boot notice for this boot."
assert_file_not_contains "$STUB_LOG" "curl"
# A new boot, or an unreadable boot ID, pushes again
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
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_file_contains "$STUB_LOG" "-H Title: $(hostname) started"

rm "$DOTFILES_NTFY_URL_FILE"
: > "$STUB_LOG"
assert_exit 0 "$BASH" "$ALERT" boot
assert_file_not_contains "$STUB_LOG" "curl"

# --- the ubuntu step's status: a failed last run of an installed alert service ---
load_script ubuntu/install.sh
ubuntu_sandbox_paths
HEALTH_UNIT_DIR="$SANDBOX/units"
mkdir -p "$HEALTH_UNIT_DIR" "$SANDBOX/result"
stub systemctl '[ "$*" != "--user show -p Result --value ${!#}" ] || cat "'"$SANDBOX"'/result/${!#}" 2> /dev/null || true'
last_runs() {
    status_last_run "Daily health alert's last run" dotfiles-health.service
    status_last_run "Boot notice's last run" dotfiles-boot-notice.service
}
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
