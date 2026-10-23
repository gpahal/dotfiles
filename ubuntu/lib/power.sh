# shellcheck shell=bash
# ubuntu/install.sh sets the constants.

# is-enabled prints a line per unit
sleep_masked() {
    [ "$(systemctl is-enabled "${SLEEP_TARGETS[@]}" 2>/dev/null | grep -cx masked)" -eq ${#SLEEP_TARGETS[@]} ]
}

mask_sleep() {
    sudo systemctl mask "${SLEEP_TARGETS[@]}"
}

sleep_conf_written() {
    file_is "$SLEEP_CONF" "$SLEEP_CONF_CONTENT"
}

write_sleep_conf() {
    write_root_file "$SLEEP_CONF" "$SLEEP_CONF_CONTENT"
}

sysctl_file_written() {
    file_is "$SYSCTL_CONF" "$SYSCTL_CONTENT"
}

# Prints "<key> <current value>" per unmet setting. inotify limits only need to be at least as
# high, since another file may raise them.
sysctl_differences() {
    local key value sysctl have
    sysctl="$(sbin_cmd sysctl)" || return 1
    while IFS='=' read -r key value; do
        key="${key//[[:space:]]/}"
        value="${value//[[:space:]]/}"
        have="$("$sysctl" -n "$key" 2>/dev/null)" || have=""
        case "$key" in
            fs.inotify.*) [[ "$have" =~ ^[0-9]+$ ]] && [ "$have" -ge "$value" ] && continue ;;
            *) [ "$have" == "$value" ] && continue ;;
        esac
        echo "$key ${have:-unset}"
    done < <(grep -E '^[a-z]' <<< "$SYSCTL_CONTENT")
}

sysctl_in_effect() {
    local differences
    differences="$(sysctl_differences)" && [ -z "$differences" ]
}

sysctl_written() {
    sysctl_file_written && sysctl_in_effect
}

# Files sysctl --system reads after $SYSCTL_CONF, which override it: *.conf sorted by name, first
# of each name in dir order, then /etc/sysctl.conf.
sysctl_files_read_later() {
    local LC_ALL=C source file name ours seen=" "
    ours="${SYSCTL_CONF##*/}"
    for source in "${SYSCTL_SOURCES[@]}"; do
        if [ -d "$source" ]; then
            for file in "$source"/*.conf; do
                [ -e "$file" ] || continue
                name="${file##*/}"
                case "$seen" in *" $name "*) continue ;; esac
                seen="$seen$name "
                if [[ "$name" > "$ours" ]]; then printf '%s\t%s\n' "$name" "$file"; fi
            done
        fi
    done | LC_ALL=C sort -t $'\t' -k1,1 | cut -f2-
    for source in "${SYSCTL_SOURCES[@]}"; do
        if [ -f "$source" ]; then echo "$source"; fi
    done
}

sysctl_overrides() {
    local key have files file later=()
    while IFS= read -r file; do later+=("$file"); done < <(sysctl_files_read_later)
    [ ${#later[@]} -gt 0 ] || return 0
    while read -r key have; do
        files=""
        for file in "${later[@]}"; do
            ! grep -qE "^[[:space:]]*-?${key//./[./]}[[:space:]]*=" "$file" 2>/dev/null ||
                files="${files:+$files, }$file"
        done
        [ -z "$files" ] || echo "$key is $have, set by $files"
    done < <(sysctl_differences || true)
}

# --system, not -p, so a later file still wins as at boot. It fails on any unknown key in any file
# (as in a VM), so judge by sysctl_in_effect instead.
apply_sysctl() {
    local overrides line
    sysctl_file_written || write_root_file "$SYSCTL_CONF" "$SYSCTL_CONTENT" || return 1
    sudo sysctl --system > /dev/null || true
    sysctl_in_effect && return 0
    overrides="$(sysctl_overrides)"
    if [ -n "$overrides" ]; then
        echo "  sysctl --system didn't put $SYSCTL_CONF in effect, since another file sets these:" >&2
        while IFS= read -r line; do echo "    $line"; done <<< "$overrides" >&2
        echo "  Change or remove them there, and re-run the step." >&2
    else
        echo "  sysctl --system didn't put $SYSCTL_CONF in effect; check it with sysctl --system." >&2
    fi
    return 1
}
