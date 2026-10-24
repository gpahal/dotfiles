# Helpers for tests of the ubuntu step and its hooks. Call ubuntu_sandbox_paths after each
# load_script ubuntu/install.sh, which resets the paths.
# shellcheck shell=bash

# sandbox_paths for the ubuntu step, with sudo's PATH and sshd in the stubs, and no nut user.
# UPS_POWERDOWN_FLAG keeps its path: the step only writes it into NUT's config and the RTC hook.
ubuntu_sandbox_paths() {
    sandbox_paths SBIN_PATH="$STUB_DIR" SSHD_BIN="$STUB_DIR/sshd" NUT_OWNER="$(id -un)" NUT_GROUP="$(id -gn)" \
        UPS_POWERDOWN_FLAG="$UPS_POWERDOWN_FLAG" \
        FWUPD_METADATA_DIRS="$SANDBOX/var/lib/fwupd/metadata $SANDBOX/var/cache/fwupd/metadata" \
        ubuntu/install.sh 'ubuntu/lib/*.sh' lib/system.sh
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
[ ! -e "$SANDBOX/curl-fails" ] || { echo "curl: (6) Could not resolve host: ntfy.sh" >&2; exit 6; }'
}

ufw_on() { echo ENABLED=yes > "$UFW_CONF"; }
ufw_off() { echo ENABLED=no > "$UFW_CONF"; }
# ufw_defaults <IPV6 value>
ufw_defaults() { printf '%s\n' 'DEFAULT_INPUT_POLICY="DROP"' "IPV6=$1" > "$UFW_DEFAULTS"; }
rules_present() {
    ufw_status_listing > "$SANDBOX/ufw-status"
}
rules_missing() {
    { ufw_header; echo "Anywhere on tailscale0     ALLOW       Anywhere"; } > "$SANDBOX/ufw-status"
}

# ufw_step_setup: after ubuntu_step_set_up, for the ufw tests: the real ufw_enabled, ufw's IPv6 on,
# no assumed yes, and linger standing in for the step's other changes
ufw_step_setup() {
    unset DOTFILES_ASSUME_YES
    restore_fn ufw_enabled
    ufw_defaults yes
    replace_fn lingering '[ -e "$SANDBOX/linger" ]'
    touch "$SANDBOX/linger"
}
