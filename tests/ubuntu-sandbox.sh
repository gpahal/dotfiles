# Call ubuntu_sandbox_paths after setup_sandbox and after each load_script ubuntu/install.sh,
# which resets the paths. It fails the test when a step constant still names a system path.
# shellcheck shell=bash
# shellcheck disable=SC2034 # the step reads them

# Constants the step only writes into files' content, never opens
UBUNTU_CONTENT_PATHS="UPS_POWERDOWN_FLAG"

ubuntu_sandbox_paths() {
    SBIN_PATH="$STUB_DIR"
    SSHD_DROP_IN="$SANDBOX/sshd_config.d/10-dotfiles.conf"
    SSHD_CONFIG="$SANDBOX/sshd_config"
    SSHD_RUN_DIR="$SANDBOX/run-sshd"
    SSHD_BIN="$STUB_DIR/sshd"
    SLEEP_CONF="$SANDBOX/sleep.conf.d/10-dotfiles.conf"
    REBOOT_REQUIRED="$SANDBOX/reboot-required"
    LINGER_DIR="$SANDBOX/systemd-linger"
    SYSCTL_CONF="$SANDBOX/sysctl.d/90-dotfiles.conf"
    SYSCTL_SOURCES=("$SANDBOX/sysctl.d")
    SMARTD_HOOK="$SANDBOX/run.d/50dotfiles-notify"
    SMARTD_CONF="$SANDBOX/smartd.conf"
    NTFY_URL_FILE="$SANDBOX/etc-dotfiles/ntfy-url"
    NUT_DIR="$SANDBOX/nut"
    # No nut group in a test
    NUT_OWNER="$(id -un)"
    NUT_GROUP="$(id -gn)"
    UPOWER_HWDB="$SANDBOX/95-upower-hid.hwdb"
    UPS_RTC_HOOK="$SANDBOX/system-shutdown/dotfiles-rtc-wake"
    UPS_NOTIFY="$SANDBOX/libexec/dotfiles-ups-notify"
    NTFY_LIB="$SANDBOX/lib-dotfiles/ntfy.sh"
    FWUPD_METADATA_DIRS="$SANDBOX/fwupd-metadata"
    AUTO_UPGRADES_CONF="$SANDBOX/apt.conf.d/20auto-upgrades"
    KEEP_CONFFILES_CONF="$SANDBOX/apt.conf.d/50dotfiles-keep-conffiles"
    UFW_CONF="$SANDBOX/ufw/ufw.conf"
    UFW_DEFAULTS="$SANDBOX/default-ufw"
    TAILSCALE_KEYRING="$SANDBOX/keyrings/tailscale-archive-keyring.gpg"
    TAILSCALE_LIST="$APT_SOURCES_DIR/tailscale.list"
    CRYPTTAB="$SANDBOX/crypttab"
    _ubuntu_system_paths_left
}

_ubuntu_system_paths_left() {
    local name value left=""
    while IFS= read -r name; do
        case " $UBUNTU_CONTENT_PATHS " in *" $name "*) continue ;; esac
        eval "set -- \${${name}[@]+\"\${${name}[@]}\"}"
        for value; do
            case "$value" in
                # A checkout under /var, as mktemp's dirs are on macOS
                "$REPO_DIR"/*) ;;
                /etc* | /var* | /usr* | /run* | /dev*) left="$left $name=$value" ;;
            esac
        done
    done < <(sed -nE 's/^([A-Z][A-Z0-9_]*)=.*/\1/p' "$REPO_DIR/ubuntu/install.sh" "$REPO_DIR"/ubuntu/lib/*.sh | sort -u)
    [ -z "$left" ] || fail "ubuntu_sandbox_paths left these on the real machine:$left"
}

# `ufw status` output for the rules the ubuntu step adds, in its order; $1 is the SSH port
ufw_header() {
    printf '%s\n' "Status: active" "" "To                         Action      From" \
        "--                         ------      ----"
}
ufw_deny_rules() {
    local bridge
    for bridge in docker0 br-+; do
        printf '%-26s DENY        Anywhere\n' "${1:-22}/tcp on $bridge"
        printf '%-26s DENY        Anywhere (v6)\n' "${1:-22}/tcp (v6) on $bridge"
    done
}
ufw_range_rules() {
    local range
    for range in 10.0.0.0/8 192.168.0.0/16 fd00::/8 fe80::/10; do
        printf '%-26s ALLOW       %s\n' "${1:-22}/tcp" "$range"
    done
}
ufw_tailscale_rules() {
    printf '%s\n' "Anywhere on tailscale0     ALLOW       Anywhere" "41641/udp                  ALLOW       Anywhere"
}
ufw_status_listing() {
    ufw_header
    ufw_deny_rules
    ufw_range_rules
    ufw_tailscale_rules
}
