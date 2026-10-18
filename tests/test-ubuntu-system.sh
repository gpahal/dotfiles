#!/bin/bash
# The step's functions call the ones this test replaces
# shellcheck disable=SC2329
set -euo pipefail
# os: ubuntu

# The ubuntu step on a set-up machine (tests/ubuntu-step-fixture.sh): Tailscale waiting for its
# first login, its apt source for an older release or a release it has no packages for, and its
# install; smartd enabled but failed; sysctl settings written but not in effect, raised further by
# another file, or lowered by one; the disk encryption warning; packages installed before they're
# used; and unattended-upgrades' keys merged into 20auto-upgrades.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

setup_sandbox
ubuntu_step_setup
ubuntu_step_set_up

# Before its first login, Tailscale's auto-update and operator wait, since tailscale up resets them:
# status reports them missing, and the step leaves them until it runs after the login
touch "$SANDBOX/tailscale-reset"
echo NeedsLogin > "$SANDBOX/tailscale-state"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Tailscale auto-updates, with $(id -un) as its operator"
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "Turn on Tailscale's auto-update"
assert_contains "$RUN_OUTPUT" "Run sudo tailscale up, then bash setup.sh ubuntu"
assert_file_not_contains "$STUB_LOG" "tailscale set"
echo Running > "$SANDBOX/tailscale-state"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Turn on Tailscale's auto-update and make $(id -un) its operator"
assert_file_contains "$STUB_LOG" "sudo tailscale set --auto-update --operator=$(id -un)"
rm "$SANDBOX/tailscale-reset"

# Tailscale's apt source for an older release, as a release upgrade leaves it: status says so, and
# a yes writes the key and the one-line tailscale.list for this release, and updates from it alone.
# test-apt-sources.sh covers the other states apt_source_state reports.
mkdir -p "$SANDBOX/keyrings"
fetch() {
    echo "fetch $1" >> "$STUB_LOG"
    echo key > "$2"
}
# The key has the fingerprint the step pins
stub gpg "printf 'pub:-\\nfpr:::::::::%s:\\n' $TAILSCALE_KEY_FPR"
# curl answers the HEAD request for Tailscale's Release file with $SANDBOX/http-status
stub curl 'cat "'"$SANDBOX"'/http-status"'
echo 200 > "$SANDBOX/http-status"
TAILSCALE_ENTRY="deb [signed-by=$TAILSCALE_KEYRING] https://pkgs.tailscale.com/stable/ubuntu resolute main"
echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Tailscale's apt source ($TAILSCALE_LIST)"
echo "${TAILSCALE_ENTRY/resolute/jammy}" > "$TAILSCALE_LIST"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Tailscale's apt source ($TAILSCALE_LIST): differs from what setup writes; re-run the ubuntu step"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Rewrite Tailscale's apt source for resolute"
assert_file_contains "$STUB_LOG" "fetch https://pkgs.tailscale.com/stable/ubuntu/resolute.noarmor.gpg"
assert_file_contains "$STUB_LOG" "update --error-on=any -o Dir::Etc::sourcelist=$TAILSCALE_LIST -o Dir::Etc::sourceparts=-"
assert_file_not_contains "$STUB_LOG" "install -y tailscale"
assert_eq key "$(cat "$TAILSCALE_KEYRING")" "Tailscale's key after repairing the source"
assert_eq "$TAILSCALE_ENTRY" "$(cat "$TAILSCALE_LIST")" "Tailscale's source after repairing it"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         Tailscale's apt source ($TAILSCALE_LIST)"

# Tailscale has no packages for this release yet: the step says so, and waits without failing,
# changing the source, or listing the rewrite. Status says what it waits for.
echo "${TAILSCALE_ENTRY/resolute/jammy}" > "$TAILSCALE_LIST"
echo 404 > "$SANDBOX/http-status"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Tailscale hasn't published packages for Ubuntu resolute yet; re-run this step later."
assert_not_contains "$RUN_OUTPUT" "Rewrite Tailscale's apt source"
run status
assert_contains "$RUN_OUTPUT" "missing    Tailscale's apt source ($TAILSCALE_LIST): differs from what setup writes; Tailscale hasn't published packages for Ubuntu resolute yet"
assert_eq "${TAILSCALE_ENTRY/resolute/jammy}" "$(cat "$TAILSCALE_LIST")" "Tailscale's source while it has no packages for resolute"
assert_file_not_contains "$STUB_LOG" "fetch"
assert_file_not_contains "$STUB_LOG" "update --error-on=any"
echo 200 > "$SANDBOX/http-status"
echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"

# Tailscale not installed: a yes adds its repo, then installs it from there. In a subshell, since
# hide changes PATH for the rest of the test.
failures="$TEST_FAILURES"
rm "$TAILSCALE_LIST"
(
    cp "$STUB_DIR/tailscale" "$SANDBOX/tailscale-stub"
    hide tailscale
    stub apt-get 'case "$*" in
        *"install -y tailscale") cp "'"$SANDBOX"'/tailscale-stub" "$STUB_DIR/tailscale" ;;
        *) cat "'"$SANDBOX"'/apt-upgrade" 2> /dev/null || true ;;
    esac'
    assert_exit 3 status
    assert_contains "$RUN_OUTPUT" "missing    Tailscale"
    : > "$STUB_LOG"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Install Tailscale from its apt repo: write $TAILSCALE_LIST and its key"
    assert_eq "$TAILSCALE_ENTRY" "$(cat "$TAILSCALE_LIST")" "Tailscale's source after installing it"
    assert_eq "update --error-on=any
install -y tailscale" "$(grep -oE '^apt-get -o DPkg::Lock::Timeout=300 (update --error-on=any|install -y tailscale)' "$STUB_LOG" |
        sed 's/^apt-get -o DPkg::Lock::Timeout=300 //')" "apt-get's runs to install Tailscale"
    assert_exit 0 status
    assert_contains "$RUN_OUTPUT" "ok         Tailscale's apt source ($TAILSCALE_LIST)"
    [ "$TEST_FAILURES" -eq "$failures" ]
) || fail "installing Tailscale"
echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"
stub apt-get 'cat "'"$SANDBOX"'/apt-upgrade" 2> /dev/null || true'

# smartd enabled but failed: status says so, and a yes restarts it, since enable --now doesn't
# start a failed one
rm "$SANDBOX/smartd-active"
touch "$SANDBOX/smartd-failed"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "ok         smartmontools, with smartd enabled at boot"
assert_contains "$RUN_OUTPUT" "missing    smartd running"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Watch disk health: start smartd"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now smartmontools.service"
assert_file_contains "$STUB_LOG" "sudo systemctl restart smartmontools.service"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         smartd running"

# A failed sysctl --system leaves the file written but not in effect: status says so, and a re-run
# applies it without rewriting the file
rm -f "$SYSCTL_CONF" "$SANDBOX/sysctl-live"
touch "$SANDBOX/sysctl-fails"
assert_exit 1 main
assert_file_contains "$SYSCTL_CONF" "kernel.panic = 10"
rm "$SANDBOX/sysctl-fails"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF): written but not in effect"
: > "$STUB_LOG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Put $SYSCTL_CONF in effect"
assert_file_contains "$STUB_LOG" "sudo sysctl --system"
assert_file_not_contains "$STUB_LOG" "tee $SYSCTL_CONF"
assert_exit 0 status
assert_not_contains "$RUN_OUTPUT" "missing"

# Another file raising an inotify limit further, as an IDE's does, leaves it in effect: status is
# ok, and a run has nothing to apply
SYSCTL_ITEM="Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF)"
echo "fs.inotify.max_user_watches = 2097152" > "$SANDBOX/sysctl.d/99-idea.conf"
echo "fs.inotify.max_user_watches=2097152" >> "$SANDBOX/sysctl-live"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $SYSCTL_ITEM"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "sysctl --system"
rm "$SANDBOX/sysctl.d/99-idea.conf"
# One that lowers it wins: the step names the file and fails, and so does status
echo "fs.inotify.max_user_watches = 8192" > "$SANDBOX/sysctl.d/99-low.conf"
echo "fs.inotify.max_user_watches=8192" >> "$SANDBOX/sysctl-live"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $SYSCTL_ITEM: written but not in effect (fs.inotify.max_user_watches is 8192, set by $SANDBOX/sysctl.d/99-low.conf; change or remove them there, and re-run the ubuntu step)"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sysctl --system didn't put $SYSCTL_CONF in effect, since another file sets these:
    fs.inotify.max_user_watches is 8192, set by $SANDBOX/sysctl.d/99-low.conf"
# Only the files sysctl --system reads after the step's are named: those named after it, sorted by
# name across the dirs, each the first of its name in their order, then sysctl.conf, read last
mkdir -p "$SANDBOX/lib-sysctl.d"
SYSCTL_SOURCES=("$SANDBOX/sysctl.d" "$SANDBOX/lib-sysctl.d" "$SANDBOX/sysctl.conf")
echo "fs.inotify.max_user_watches = 4096" > "$SANDBOX/sysctl.d/10-early.conf"
echo "fs.inotify.max_user_watches = 4096" > "$SANDBOX/lib-sysctl.d/99-low.conf"
echo "fs.inotify.max_user_watches = 8192" > "$SANDBOX/lib-sysctl.d/95-lib.conf"
echo "fs.inotify.max_user_watches = 8192" > "$SANDBOX/sysctl.conf"
assert_eq "fs.inotify.max_user_watches is 8192, set by $SANDBOX/lib-sysctl.d/95-lib.conf, $SANDBOX/sysctl.d/99-low.conf, $SANDBOX/sysctl.conf" \
    "$(sysctl_overrides)" "the files that override the step's"
rm -r "$SANDBOX/lib-sysctl.d" "$SANDBOX/sysctl.d/10-early.conf" "$SANDBOX/sysctl.conf"
# shellcheck disable=SC2034 # sysctl_overrides reads it
SYSCTL_SOURCES=("$SANDBOX/sysctl.d")
rm "$SANDBOX/sysctl.d/99-low.conf"
assert_exit 0 main
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $SYSCTL_ITEM"

# sysctl is in /usr/sbin, which a user's PATH may lack: the check looks there too
mkdir -p "$SANDBOX/sbin"
mv "$STUB_DIR/sysctl" "$SANDBOX/sbin/"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$SANDBOX/sbin"
no_sbin_path="$(tr : '\n' <<< "$PATH" | grep -vxE '/usr/sbin|/sbin' | paste -sd: -)"
sysctl_without_sbin() { PATH="$no_sbin_path" sysctl_in_effect; }
assert_exit 0 sysctl_without_sbin
mv "$SANDBOX/sbin/sysctl" "$STUB_DIR/"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$STUB_DIR"

# --- disk encryption ---
# lsblk -rno TYPE lists the open mappings, and -rno FSTYPE,LABEL the partitions, from
# $SANDBOX/lsblk-types and $SANDBOX/lsblk-labels
stub lsblk 'case "$2" in
    TYPE) cat "'"$SANDBOX"'/lsblk-types" ;;
    FSTYPE,LABEL) cat "'"$SANDBOX"'/lsblk-labels" ;;
esac'
disk() { printf '%s\n' disk part "$@" > "$SANDBOX/lsblk-types"; }
labels() { printf '%s\n' "vfat " "$@" > "$SANDBOX/lsblk-labels"; }
# Not encrypted: nothing to say
disk
labels "ext4 "
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption without encryption"
# A LUKS passphrase, as the installer sets up without TPM: waits at the console, and says what
# avoids it
disk crypt lvm
labels "crypto_LUKS " "LVM2_member "
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase. Every boot waits for it at the console"
assert_contains "$RUN_OUTPUT" "binding the disk to the TPM (systemd-cryptenroll)"
assert_not_contains "$RUN_OUTPUT" "Only a reinstall"
# Bound to the TPM with systemd-cryptenroll, which keeps the label: nothing to say
echo "dm_crypt-0 UUID=1234 none luks,tpm2-device=auto" > "$CRYPTTAB"
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption with a disk bound to the TPM"
echo "dm_crypt-0 UUID=1234 none luks" > "$CRYPTTAB"
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase"
# TPM-backed encryption, which snapd labels ubuntu-<role>-enc: nothing to say
disk crypt crypt
labels "crypto_LUKS ubuntu-save-enc" "crypto_LUKS ubuntu-data-enc"
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption with TPM-backed encryption"
# TPM-backed encryption for the system, and a passphrase for another disk: waits at the console
disk crypt crypt crypt
labels "crypto_LUKS ubuntu-save-enc" "crypto_LUKS ubuntu-data-enc" "crypto_LUKS "
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase"

# --- packages missing: smartmontools without its recommends, which pull in a mail server, and
# unattended-upgrades and locales before they're used ---
stub dpkg-query 'case "$*" in *smartmontools* | *unattended-upgrades* | *locales*) ;; *) echo "install ok installed" ;; esac'
stub apt-get
stub_systemctl
rm -f "$SANDBOX/smartd" "$SANDBOX/locale" "$AUTO_UPGRADES_CONF"
: > "$STUB_LOG"
run main
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends smartmontools"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y unattended-upgrades"
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y locales"
assert_file_contains "$STUB_LOG" "sudo locale-gen en_US.UTF-8"
assert_file_contains "$AUTO_UPGRADES_CONF" 'APT::Periodic::Unattended-Upgrade "1";'
# Only the pending items run: sysctl is already set up
assert_file_not_contains "$STUB_LOG" "sysctl --system"

# Another file in apt.conf.d that turns unattended-upgrades off wins over the step's: it says so
# and fails
stub dpkg-query 'echo "install ok installed"'
echo 'APT::Periodic::Unattended-Upgrade "0";' > "$SANDBOX/apt.conf.d/99off"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "effective periodic settings still disable daily updates"
rm "$SANDBOX/apt.conf.d/99off"

# Software & Updates writes other APT::Periodic keys into 20auto-upgrades: turning
# unattended-upgrades on sets only the step's keys, keeps the rest, and a re-run writes nothing
printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Download-Upgradeable-Packages "1";' \
    'APT::Periodic::AutocleanInterval "7";' 'APT::Periodic::Unattended-Upgrade "0";' > "$AUTO_UPGRADES_CONF"
run main
assert_eq 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Enable "1";' "$(cat "$AUTO_UPGRADES_CONF")" "20auto-upgrades after the merge"
: > "$STUB_LOG"
run main
assert_file_not_contains "$STUB_LOG" "tee $AUTO_UPGRADES_CONF"
test_done
