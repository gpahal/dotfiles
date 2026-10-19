# shellcheck shell=bash
# Power and recovery for the ubuntu step: the sleep targets, sleep.conf, and the sysctl settings.
# ubuntu/install.sh sources this file and sets the constants it uses. It only defines functions.

sleep_masked() {
    local target
    for target in "${SLEEP_TARGETS[@]}"; do
        [ "$(systemctl is-enabled "$target" 2>/dev/null)" == "masked" ] || return 1
    done
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

# Print each setting in $SYSCTL_CONTENT the kernel doesn't have, as "<key> <value it has>", one
# per line. Fails when sysctl can't be found. The inotify limits count when at least as high,
# since another file, such as an IDE's, may raise them further; kernel.panic must match.
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

# Succeeds when the kernel has each setting in $SYSCTL_CONTENT, which a failed sysctl --system
# leaves undone
sysctl_in_effect() {
    local differences
    differences="$(sysctl_differences)" && [ -z "$differences" ]
}

sysctl_written() {
    sysctl_file_written && sysctl_in_effect
}

# Print the files sysctl --system reads after $SYSCTL_CONF, whose values win over it, one per line
# in the order it reads them. It reads the *.conf files in the SYSCTL_SOURCES dirs sorted by name,
# only the first of each name in the dirs' order, then a source that's a file, /etc/sysctl.conf.
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

# Print each setting the kernel lacks that a file sysctl --system reads after $SYSCTL_CONF sets,
# as "<key> is <value>, set by <files>", one per line
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

# Write $SYSCTL_CONF and put it in effect. --system loads every file in boot order, so a later
# file's value still wins, where -p on the step's file would override it until the next reboot.
# It fails when any key in any file does, such as one a VM's kernel lacks, after setting the rest,
# so the step judges it by sysctl_in_effect instead.
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
