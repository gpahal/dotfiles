#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions
set -euo pipefail

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-sandbox.sh
source "$TESTS_DIR/ubuntu-sandbox.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

setup_sandbox
ubuntu_step_setup
ubuntu_step_set_up

# tailscale up resets auto-update and operator, so the step waits for the first login
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

# Operator mode lets anything running as you publish a funnel or turn on Tailscale SSH
run status_tailscale_exposure
assert_contains "$RUN_OUTPUT" "ok         No Tailscale funnel publishing a port to the internet"
assert_contains "$RUN_OUTPUT" "ok         Tailscale SSH off"
echo '{"AllowFunnel": {"m.ts.net:443": true, "m.ts.net:10000": false}, "Foreground": {"s": {"AllowFunnel": {"m.ts.net:8443": true}}}}' \
    > "$SANDBOX/tailscale-serve"
touch "$SANDBOX/tailscale-ssh"
run status_tailscale_exposure
assert_contains "$RUN_OUTPUT" "missing    No Tailscale funnel publishing a port to the internet: m.ts.net:443, m.ts.net:8443 is published"
assert_contains "$RUN_OUTPUT" "missing    Tailscale SSH off"
rm "$SANDBOX/tailscale-serve" "$SANDBOX/tailscale-ssh"

# A release upgrade leaves Tailscale's source on the old release; test-apt-sources.sh covers other states
mkdir -p "$SANDBOX/keyrings"
replace_fn fetch 'echo "fetch $1" >> "$STUB_LOG"
echo key > "$2"'
stub gpg "printf 'pub:-\\nfpr:::::::::%s:\\n' $TAILSCALE_KEY_FPR"
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

# No Tailscale packages for this release yet: wait without failing or changing the source
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

# Subshell: hide changes PATH for the rest of the test
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

# enable --now doesn't start a failed smartd, so it restarts it
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

# A failed sysctl --system leaves the file written but not in effect
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
# sysctl --system fails on a key the kernel lacks after setting the rest, so the step succeeds
rm -f "$SYSCTL_CONF" "$SANDBOX/sysctl-live"
touch "$SANDBOX/sysctl-key-fails"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo sysctl --system"
rm "$SANDBOX/sysctl-key-fails"
assert_exit 0 status

# Another file raising an inotify limit further is fine
SYSCTL_ITEM="Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF)"
echo "fs.inotify.max_user_watches = 2097152" > "$SANDBOX/sysctl.d/99-idea.conf"
echo "fs.inotify.max_user_watches=2097152" >> "$SANDBOX/sysctl-live"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         $SYSCTL_ITEM"
: > "$STUB_LOG"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "sysctl --system"
rm "$SANDBOX/sysctl.d/99-idea.conf"
echo "fs.inotify.max_user_watches = 8192" > "$SANDBOX/sysctl.d/99-low.conf"
echo "fs.inotify.max_user_watches=8192" >> "$SANDBOX/sysctl-live"
assert_exit 3 status
assert_contains "$RUN_OUTPUT" "missing    $SYSCTL_ITEM: written but not in effect (fs.inotify.max_user_watches is 8192, set by $SANDBOX/sysctl.d/99-low.conf; change or remove them there, and re-run the ubuntu step)"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sysctl --system didn't put $SYSCTL_CONF in effect, since another file sets these:
    fs.inotify.max_user_watches is 8192, set by $SANDBOX/sysctl.d/99-low.conf"
# Only files read after the step's count: later names across the dirs, first of each name, then sysctl.conf
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

# sysctl is in /usr/sbin, which a user's PATH may lack
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

stub lsblk 'case "$2" in
    TYPE) cat "'"$SANDBOX"'/lsblk-types" ;;
    FSTYPE,LABEL) cat "'"$SANDBOX"'/lsblk-labels" ;;
esac'
disk() { printf '%s\n' disk part "$@" > "$SANDBOX/lsblk-types"; }
labels() { printf '%s\n' "vfat " "$@" > "$SANDBOX/lsblk-labels"; }
disk
labels "ext4 "
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption without encryption"
# A LUKS passphrase without TPM waits at the console on boot
disk crypt lvm
labels "crypto_LUKS " "LVM2_member "
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase. Every boot waits for it at the console"
assert_contains "$RUN_OUTPUT" "binding the disk to the TPM (systemd-cryptenroll)"
assert_not_contains "$RUN_OUTPUT" "Only a reinstall"
run status
assert_contains "$RUN_OUTPUT" "info       Disk encrypted with a passphrase"
# systemd-cryptenroll keeps the label, so crypttab shows the TPM binding
echo "dm_crypt-0 UUID=1234 none luks,tpm2-device=auto" > "$CRYPTTAB"
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption with a disk bound to the TPM"
echo "dm_crypt-0 UUID=1234 none luks" > "$CRYPTTAB"
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase"
# snapd labels TPM-backed partitions ubuntu-<role>-enc
disk crypt crypt
labels "crypto_LUKS ubuntu-save-enc" "crypto_LUKS ubuntu-data-enc"
run warn_disk_encryption
assert_eq "" "$RUN_OUTPUT" "warn_disk_encryption with TPM-backed encryption"
disk crypt crypt crypt
labels "crypto_LUKS ubuntu-save-enc" "crypto_LUKS ubuntu-data-enc" "crypto_LUKS "
run warn_disk_encryption
assert_contains "$RUN_OUTPUT" "The disk is encrypted with a passphrase"

# --- packages missing ---
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
# Only pending items run
assert_file_not_contains "$STUB_LOG" "sysctl --system"

stub dpkg-query 'echo "install ok installed"'
echo 'APT::Periodic::Unattended-Upgrade "0";' > "$SANDBOX/apt.conf.d/99off"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "effective periodic settings still disable daily updates"
rm "$SANDBOX/apt.conf.d/99off"

# Software & Updates writes other APT::Periodic keys into 20auto-upgrades; keep them
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

# APT takes several statements on a line; only ours are replaced, the rest kept in order
assert_eq 'APT::Periodic::Enable "1"; APT::Periodic::AutocleanInterval "7";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' \
    "$(merged_auto_upgrades 'APT::Periodic::Enable "0"; APT::Periodic::AutocleanInterval "7";')" \
    "a line with our key first"
assert_eq '  APT::Periodic::AutocleanInterval "7";  APT::Periodic::Update-Package-Lists "1"; // ours
Foo::Note "a; b"; APT::Periodic::Unattended-Upgrade "1";
Foo::One "1"; Foo::Two "2";
APT::Periodic::Enable "1";' \
    "$(merged_auto_upgrades '  APT::Periodic::AutocleanInterval "7";  apt::periodic::update-package-lists "0"; // ours
Foo::Note "a; b"; APT::Periodic::Unattended-Upgrade "0";
Foo::One "1"; Foo::Two "2";')" \
    "lines with our key second, a ; in quotes, and no key of ours"
# A line it can't split stays, and ours follow it, since it could set or clear them
assert_eq 'APT::Periodic::Enable "1";
APT::Periodic { Enable "0"; };
/* APT::Periodic::Update-Package-Lists "0"; */
# APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' \
    "$(merged_auto_upgrades 'APT::Periodic::Enable "0";
APT::Periodic { Enable "0"; };
/* APT::Periodic::Update-Package-Lists "0"; */
# APT::Periodic::Unattended-Upgrade "0";')" \
    "a scope and comments"
assert_eq 'APT::Periodic::Enable
    "0";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";' \
    "$(merged_auto_upgrades 'APT::Periodic::Enable
    "0";
APT::Periodic::Unattended-Upgrade "0";')" \
    "a statement over two lines"

# Only root can read 20auto-upgrades, so apt-config skips it. The sudo stub makes it readable while it runs.
stub sudo '[ "${1:-}" != -n ] || { [ -e "'"$SANDBOX"'/cached" ] || exit 1; shift; }
f="'"$AUTO_UPGRADES_CONF"'"
[ ! -e "'"$SANDBOX"'/sudo-cat-fails" ] || [ "$*" != "cat $f" ] || exit 1
hidden=false
if [ -e "$f" ] && [ ! -r "$f" ]; then chmod u+r "$f"; hidden=true; fi
status=0
env "$@" || status=$?
! "$hidden" || chmod u-r "$f"
exit "$status"'
printf '%s\n' 'APT::Periodic::AutocleanInterval "7";' 'APT::Periodic::Unattended-Upgrade "0";' > "$AUTO_UPGRADES_CONF"
chmod 200 "$AUTO_UPGRADES_CONF"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "unverified unattended-upgrades runs daily (only root can read $AUTO_UPGRADES_CONF; run sudo -v, then status, to check it)"
# A re-run with nothing else to change doesn't ask for sudo only to read it
: > "$STUB_LOG"
assert_exit 0 main
assert_not_contains "$RUN_OUTPUT" "These need sudo"
assert_contains "$RUN_OUTPUT" "Only root can read $AUTO_UPGRADES_CONF; run sudo -v and re-run this step to check unattended-upgrades."
assert_file_not_contains "$STUB_LOG" "sudo cat"
# With another change pending, reading it joins the sudo list; a failed read writes nothing
rm "$SANDBOX/locale"
touch "$SANDBOX/sudo-cat-fails"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Check unattended-upgrades' settings in $AUTO_UPGRADES_CONF, which only root can read, and turn it on there if it's off"
assert_contains "$RUN_OUTPUT" "Couldn't read $AUTO_UPGRADES_CONF, so it was left as it is."
rm "$SANDBOX/sudo-cat-fails"
chmod 600 "$AUTO_UPGRADES_CONF"
assert_eq 'APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "0";' "$(cat "$AUTO_UPGRADES_CONF")" "the unreadable 20auto-upgrades after a failed read"
chmod 200 "$AUTO_UPGRADES_CONF"
rm -f "$SANDBOX/locale"
assert_exit 0 main
chmod 600 "$AUTO_UPGRADES_CONF"
assert_eq 'APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";' "$(cat "$AUTO_UPGRADES_CONF")" "the unreadable 20auto-upgrades after the merge"
chmod 200 "$AUTO_UPGRADES_CONF"
touch "$SANDBOX/cached"
assert_exit 0 status
assert_contains "$RUN_OUTPUT" "ok         unattended-upgrades runs daily"
chmod 600 "$AUTO_UPGRADES_CONF"
test_done
