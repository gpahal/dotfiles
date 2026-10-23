#!/bin/bash
# shellcheck disable=SC2329 # the step calls the replaced functions

# The ubuntu step on a set-up machine: Tailscale's login and apt source, smartd, sysctl, disk
# encryption, and installing missing packages.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=ubuntu-step-fixture.sh
source "$TESTS_DIR/ubuntu-step-fixture.sh"

ubuntu_step_setup
ubuntu_step_set_up

# tailscale up resets auto-update and operator, so the step waits for the first login
touch "$SANDBOX/tailscale-reset"
echo NeedsLogin > "$SANDBOX/tailscale-state"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Tailscale auto-updates, with $(id -un) as its operator"
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

# Tailscale's apt source; test-apt-sources.sh covers its states
mkdir -p "$(dirname "$TAILSCALE_KEYRING")"
stub_fetch
stub_gpg_fpr "$TAILSCALE_KEY_FPR"
stub_http_status

# Subshell: hide changes PATH for the rest of the test
failures="$TEST_FAILURES"
rm "$TAILSCALE_LIST"
(
    cp "$STUB_DIR/tailscale" "$SANDBOX/tailscale-stub"
    hide tailscale
    stub apt-get 'case "$*" in
        *"install -y tailscale") cp "$SANDBOX/tailscale-stub" "$STUB_DIR/tailscale" ;;
        *) cat "$SANDBOX/apt-upgrade" 2> /dev/null || true ;;
    esac'
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    Tailscale"
    assert_exit 0 main
    assert_contains "$RUN_OUTPUT" "Install Tailscale from its apt repo: write $TAILSCALE_LIST and its key"
    assert_eq "$TAILSCALE_ENTRY" "$(cat "$TAILSCALE_LIST")" "Tailscale's source after installing it"
    assert_eq "update --error-on=any
install -y tailscale" "$(grep -oE '^apt-get -o DPkg::Lock::Timeout=300 (update --error-on=any|install -y tailscale)' "$STUB_LOG" |
        sed 's/^apt-get -o DPkg::Lock::Timeout=300 //')" "apt-get's runs to install Tailscale"
    assert_exit 0 main --status
    assert_contains "$RUN_OUTPUT" "ok         Tailscale's apt source ($TAILSCALE_LIST)"
    [ "$TEST_FAILURES" -eq "$failures" ]
) || fail "installing Tailscale"
echo "$TAILSCALE_ENTRY" > "$TAILSCALE_LIST"
stub_apt_packages '*'

# enable --now doesn't start a failed smartd, so it restarts it
rm "$SANDBOX/units/smartmontools.service.active"
touch "$SANDBOX/units/smartmontools.service.failed"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "ok         smartmontools, with smartd enabled at boot"
assert_contains "$RUN_OUTPUT" "missing    smartd running"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Watch disk health: start smartd"
assert_file_contains "$STUB_LOG" "sudo systemctl enable --now smartmontools.service"
assert_file_contains "$STUB_LOG" "sudo systemctl restart smartmontools.service"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         smartd running"

# A failed sysctl --system leaves the file written but not in effect
rm -f "$SYSCTL_CONF" "$SANDBOX/sysctl-live"
touch "$SANDBOX/sysctl-fails"
assert_exit 1 main
assert_file_contains "$SYSCTL_CONF" "kernel.panic = 10"
rm "$SANDBOX/sysctl-fails"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF): written but not in effect"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Put $SYSCTL_CONF in effect"
assert_file_contains "$STUB_LOG" "sudo sysctl --system"
assert_file_not_contains "$STUB_LOG" "tee $SYSCTL_CONF"
assert_exit 0 main --status
assert_not_contains "$RUN_OUTPUT" "missing"
# sysctl --system fails on a key the kernel lacks after setting the rest, so the step succeeds
rm -f "$SYSCTL_CONF" "$SANDBOX/sysctl-live"
touch "$SANDBOX/sysctl-key-fails"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo sysctl --system"
rm "$SANDBOX/sysctl-key-fails"
assert_exit 0 main --status

# Another file raising an inotify limit further is fine
SYSCTL_ITEM="Reboot 10 s after a kernel panic, and more inotify instances and watches ($SYSCTL_CONF)"
echo "fs.inotify.max_user_watches = 2097152" > "$SANDBOX/etc/sysctl.d/99-idea.conf"
echo "fs.inotify.max_user_watches=2097152" >> "$SANDBOX/sysctl-live"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         $SYSCTL_ITEM"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "sysctl --system"
rm "$SANDBOX/etc/sysctl.d/99-idea.conf"
echo "fs.inotify.max_user_watches = 8192" > "$SANDBOX/etc/sysctl.d/99-low.conf"
echo "fs.inotify.max_user_watches=8192" >> "$SANDBOX/sysctl-live"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    $SYSCTL_ITEM: written but not in effect (fs.inotify.max_user_watches is 8192, set by $SANDBOX/etc/sysctl.d/99-low.conf; change or remove them there, and re-run the ubuntu step)"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "sysctl --system didn't put $SYSCTL_CONF in effect, since another file sets these:
    fs.inotify.max_user_watches is 8192, set by $SANDBOX/etc/sysctl.d/99-low.conf"
rm "$SANDBOX/etc/sysctl.d/99-low.conf"
assert_exit 0 main
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         $SYSCTL_ITEM"

# sysctl is in /usr/sbin, which a user's PATH may lack. Root's commands come only from SBIN_PATH,
# never a user dir on PATH, or sudo would run a planted one.
mkdir -p "$SANDBOX/sbin" "$HOME/.cargo/bin"
mv "$STUB_DIR/sysctl" "$SANDBOX/sbin/"
printf '#!/bin/bash\n' > "$HOME/.cargo/bin/sysctl"
chmod +x "$HOME/.cargo/bin/sysctl"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$SANDBOX/sbin"
user_path="$HOME/.cargo/bin:$(tr : '\n' <<< "$PATH" | grep -vxE '/usr/sbin|/sbin' | paste -sd: -)"
sysctl_without_sbin() { PATH="$user_path" sysctl_in_effect; }
assert_exit 0 sysctl_without_sbin
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$SANDBOX/no-such-dir"
PATH="$user_path" run sbin_cmd sysctl
assert_eq 1 "$RUN_STATUS" "sbin_cmd's exit status with sysctl only on PATH: $RUN_OUTPUT"
mv "$SANDBOX/sbin/sysctl" "$STUB_DIR/"
rm "$HOME/.cargo/bin/sysctl"
# shellcheck disable=SC2034 # sbin_cmd reads it
SBIN_PATH="$STUB_DIR"

stub lsblk 'case "$2" in
    TYPE) cat "$SANDBOX/lsblk-types" ;;
    FSTYPE,LABEL) cat "$SANDBOX/lsblk-labels" ;;
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
stub_apt_packages '*' '!smartmontools' '!unattended-upgrades' '!locales'
stub_systemctl
rm -f "$SANDBOX/units/smartmontools.service.enabled" "$SANDBOX/locale" "$AUTO_UPGRADES_CONF"
run main
assert_file_contains "$STUB_LOG" "apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends smartmontools"
assert_file_contains "$AUTO_UPGRADES_CONF" 'APT::Periodic::Unattended-Upgrade "1";'
# Only pending items run
assert_file_not_contains "$STUB_LOG" "sysctl --system"
test_done
