# shellcheck shell=bash
# Settings a user may override (e.g. the model): set when unset, replaced only if
# replace_custom_value agrees. A step defines <tool>_keep_current <path>, and
# <tool>_keep_wanted <value> when its values aren't JSON, printing values in one comparable form
# (empty for unset).

# Re-sourcing keeps rows another step already added.
KEEP_TOOLS=(${KEEP_TOOLS[@]+"${KEEP_TOOLS[@]}"})
KEEP_PATHS=(${KEEP_PATHS[@]+"${KEEP_PATHS[@]}"})
KEEP_VALUES=(${KEEP_VALUES[@]+"${KEEP_VALUES[@]}"})
KEEP_NAMES=(${KEEP_NAMES[@]+"${KEEP_NAMES[@]}"})
KEEP_UBUNTU=(${KEEP_UBUNTU[@]+"${KEEP_UBUNTU[@]}"})
KEEP_REPLACE=(${KEEP_REPLACE[@]+"${KEEP_REPLACE[@]}"})

keepable_forget() {
    local i tools=() paths=() values=() names=() ubuntu=() replace=()
    # Loaded values are by index, which this changes
    keepable_unload
    for i in ${KEEP_TOOLS[@]+"${!KEEP_TOOLS[@]}"}; do
        [ "${KEEP_TOOLS[i]}" != "$1" ] || continue
        tools+=("${KEEP_TOOLS[i]}")
        paths+=("${KEEP_PATHS[i]}")
        values+=("${KEEP_VALUES[i]}")
        names+=("${KEEP_NAMES[i]}")
        ubuntu+=("${KEEP_UBUNTU[i]}")
        replace+=("${KEEP_REPLACE[i]}")
    done
    KEEP_TOOLS=(${tools[@]+"${tools[@]}"})
    KEEP_PATHS=(${paths[@]+"${paths[@]}"})
    KEEP_VALUES=(${values[@]+"${values[@]}"})
    KEEP_NAMES=(${names[@]+"${names[@]}"})
    KEEP_UBUNTU=(${ubuntu[@]+"${ubuntu[@]}"})
    KEEP_REPLACE=(${replace[@]+"${replace[@]}"})
}

# Usage: keepable <tool> <path> <value> <name> [ubuntu]
keepable() {
    KEEP_TOOLS+=("$1")
    KEEP_PATHS+=("$2")
    KEEP_VALUES+=("$3")
    KEEP_NAMES+=("$4")
    KEEP_UBUNTU+=("$([ "${5:-}" == ubuntu ] && echo true || echo false)")
    KEEP_REPLACE+=(false)
}

keepable_indexes() {
    local i
    for i in ${KEEP_TOOLS[@]+"${!KEEP_TOOLS[@]}"}; do
        [ "${KEEP_TOOLS[i]}" == "$1" ] || continue
        ! "${KEEP_UBUNTU[i]}" || is_ubuntu || continue
        echo "$i"
    done
}

KEEP_LOADED=""
KEEP_LOADED_CURRENT=()
KEEP_LOADED_WANTED=()

# Cache a tool's values until keepable_unload. Uses <tool>_keep_current_all/<tool>_keep_wanted_all
# (one line per argument) when defined. Reload after anything else may have written the settings.
keepable_load() {
    local i line n indexes=() paths=() values=()
    keepable_unload
    for i in $(keepable_indexes "$1"); do
        indexes+=("$i")
        paths+=("${KEEP_PATHS[i]}")
        values+=("${KEEP_VALUES[i]}")
    done
    if [ ${#indexes[@]} -gt 0 ] && declare -F "$1_keep_current_all" > /dev/null; then
        n=0
        while IFS= read -r line; do
            KEEP_LOADED_CURRENT[indexes[n]]="$line"
            n=$((n + 1))
        done < <("$1_keep_current_all" "${paths[@]}")
        n=0
        while IFS= read -r line; do
            KEEP_LOADED_WANTED[indexes[n]]="$line"
            n=$((n + 1))
        done < <("$1_keep_wanted_all" "${values[@]}")
    else
        for i in ${indexes[@]+"${indexes[@]}"}; do
            KEEP_LOADED_CURRENT[i]="$(keepable_current "$1" "$i")"
            KEEP_LOADED_WANTED[i]="$(keepable_wanted "$1" "$i")"
        done
    fi
    KEEP_LOADED="$1"
}

keepable_unload() {
    KEEP_LOADED=""
    KEEP_LOADED_CURRENT=()
    KEEP_LOADED_WANTED=()
}

keepable_current() {
    if [ "$KEEP_LOADED" == "$1" ]; then
        printf '%s\n' "${KEEP_LOADED_CURRENT[$2]:-}"
    else
        "$1_keep_current" "${KEEP_PATHS[$2]}"
    fi
}

keepable_wanted() {
    if [ "$KEEP_LOADED" == "$1" ]; then
        printf '%s\n' "${KEEP_LOADED_WANTED[$2]:-}"
    elif declare -F "$1_keep_wanted" > /dev/null; then
        "$1_keep_wanted" "${KEEP_VALUES[$2]}"
    else
        keepable_unquote "${KEEP_VALUES[$2]}"
    fi
}

keepable_choose() {
    local i
    for i in ${KEEP_TOOLS[@]+"${!KEEP_TOOLS[@]}"}; do
        [ "${KEEP_TOOLS[i]}" != "$1" ] || KEEP_REPLACE[i]=false
    done
    for i in $(keepable_indexes "$1"); do
        if replace_custom_value "${KEEP_NAMES[i]}" "$(keepable_current "$1" "$i")" "$(keepable_wanted "$1" "$i")"; then
            KEEP_REPLACE[i]=true
        fi
    done
}

keepable_status() {
    local i value wanted
    for i in $(keepable_indexes "$1"); do
        value="$(keepable_current "$1" "$i")"
        wanted="$(keepable_wanted "$1" "$i")"
        if [ -n "$value" ] && [ "$value" != "$wanted" ]; then
            status_custom_value "${KEEP_NAMES[i]}" "$value" "$wanted"
        fi
    done
}

keepable_unquote() {
    local value="${1#\"}"
    printf '%s\n' "${value%\"}"
}
