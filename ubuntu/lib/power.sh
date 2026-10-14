# shellcheck shell=bash
# Power and recovery for the ubuntu step: the sleep targets, sleep.conf, and the sysctl settings.
# ubuntu/install.sh sources this file and sets the constants it uses. It only defines functions.

sleep_masked() {
    local target
    for target in "${SLEEP_TARGETS[@]}"; do
        [ "$(systemctl is-enabled "$target" 2>/dev/null)" == "masked" ] || return 1
    done
}

sleep_conf_written() {
    file_is "$SLEEP_CONF" "$SLEEP_CONF_CONTENT"
}

sysctl_file_written() {
    file_is "$SYSCTL_CONF" "$SYSCTL_CONTENT"
}

# Succeeds when the kernel has each setting in $SYSCTL_CONTENT, which a failed sysctl --system
# leaves undone
sysctl_in_effect() {
    local key value sysctl
    sysctl="$(sbin_cmd sysctl)" || return 1
    while IFS='=' read -r key value; do
        key="${key//[[:space:]]/}"
        value="${value//[[:space:]]/}"
        [ "$("$sysctl" -n "$key" 2>/dev/null)" == "$value" ] || return 1
    done < <(grep -E '^[a-z]' <<< "$SYSCTL_CONTENT")
}

sysctl_written() {
    sysctl_file_written && sysctl_in_effect
}
