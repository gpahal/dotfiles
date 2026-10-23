# Helpers for tests of the ubuntu step and its hooks. Call ubuntu_sandbox_paths after setup_sandbox
# and after each load_script ubuntu/install.sh, which resets the paths. It fails the test when a
# step constant still names a system path.
# shellcheck shell=bash
# shellcheck disable=SC2034 # the step reads them

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
    WIFI_POWERSAVE_CONF="$SANDBOX/NetworkManager/conf.d/${WIFI_POWERSAVE_CONF##*/}"
    CLOUD_INIT_DISABLED="$SANDBOX/cloud/cloud-init.disabled"
    _ubuntu_system_paths_left
}

_ubuntu_system_paths_left() {
    local name value left=""
    while IFS= read -r name; do
        # Only written into NUT's config, never opened
        [ "$name" != UPS_POWERDOWN_FLAG ] || continue
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

# `ufw status` output for the rules the ubuntu step adds, in its order. The rules functions take the
# SSH port, by default 22.
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

# install_health_alert <dir>: health-alert.sh and its libraries, laid out as the ubuntu step copies them
install_health_alert() {
    mkdir -p "$1"
    cp "$REPO_DIR/ubuntu/health-alert.sh" "$REPO_DIR/ubuntu/lib/ntfy.sh" "$REPO_DIR/ubuntu/lib/paths.sh" \
        "$REPO_DIR/lib/status-format.sh" "$1/"
}

# Usage: ntfy_hook_copy <hook> <url-file> <lib> <dest>. Root's hooks hard-code their paths and
# PATH, so the copy points them at the sandbox.
ntfy_hook_copy() {
    sed -e "s|^NTFY_URL_FILE=.*|NTFY_URL_FILE=\"$2\"|" -e "s|^NTFY_LIB=.*|NTFY_LIB=\"$3\"|" \
        -e "s|^PATH=.*|PATH=\"$PATH\"|" "$REPO_DIR/$1" > "$4"
    if ! grep -qxF "NTFY_URL_FILE=\"$2\"" "$4" || ! grep -qxF "NTFY_LIB=\"$3\"" "$4" ||
        ! grep -qxF "PATH=\"$PATH\"" "$4"; then
        fail "$1 has no NTFY_URL_FILE=, NTFY_LIB=, or PATH= line to point at the sandbox"
    fi
}

# A curl for ntfy pushes. It logs the config it reads on stdin (-K -), which holds the topic, as
# "curl config: <line>", and fails while $SANDBOX/curl-fails exists.
stub_ntfy_curl() {
    stub curl 'case " $* " in *" -K - "*) sed "s/^/curl config: /" >> "$STUB_LOG" ;; esac
[ ! -e "'"$SANDBOX"'/curl-fails" ] || { echo "curl: (6) Could not resolve host: ntfy.sh" >&2; exit 6; }'
}
