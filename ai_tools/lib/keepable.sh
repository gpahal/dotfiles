# shellcheck shell=bash
# Values you can change in an AI tool's settings, such as the model, shared by the claude-code and
# codex steps, which source this file. It only defines functions and the table below.
#
# Each value is set only when unset, and one of your own is replaced only when
# replace_custom_value agrees. A step adds its values with keepable, and defines
# <tool>_keep_current <path>, which prints the setting's value. When the repo's values aren't
# JSON, it also defines <tool>_keep_wanted <value>, which prints the repo's value the same way, so
# the two compare equal when they match; keepable_unquote is the default. Each prints nothing for
# unset.

# One row per value: its tool, its path in the tool's settings, the repo's value in the settings'
# own syntax, the name prompts and status give it, and whether only Ubuntu gets it.
# keepable_choose sets KEEP_REPLACE to whether to write each over yours. Sourcing this file again,
# as for a second step in the same shell, keeps the rows the first step added.
KEEP_TOOLS=(${KEEP_TOOLS[@]+"${KEEP_TOOLS[@]}"})
KEEP_PATHS=(${KEEP_PATHS[@]+"${KEEP_PATHS[@]}"})
KEEP_VALUES=(${KEEP_VALUES[@]+"${KEEP_VALUES[@]}"})
KEEP_NAMES=(${KEEP_NAMES[@]+"${KEEP_NAMES[@]}"})
KEEP_UBUNTU=(${KEEP_UBUNTU[@]+"${KEEP_UBUNTU[@]}"})
KEEP_REPLACE=(${KEEP_REPLACE[@]+"${KEEP_REPLACE[@]}"})

# Drop a tool's rows, so a step loaded again adds its values once
# Usage: keepable_forget <tool>
keepable_forget() {
    local i tools=() paths=() values=() names=() ubuntu=() replace=()
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

# Print the index of each of a tool's values that applies on this OS
keepable_indexes() {
    local i
    for i in ${KEEP_TOOLS[@]+"${!KEEP_TOOLS[@]}"}; do
        [ "${KEEP_TOOLS[i]}" == "$1" ] || continue
        ! "${KEEP_UBUNTU[i]}" || is_ubuntu || continue
        echo "$i"
    done
}

# Print value $2 of tool $1's settings as <tool>_keep_current prints it
keepable_current() {
    "$1_keep_current" "${KEEP_PATHS[$2]}"
}

# Print the repo's value $2 as <tool>_keep_current prints it
keepable_wanted() {
    if declare -F "$1_keep_wanted" > /dev/null; then
        "$1_keep_wanted" "${KEEP_VALUES[$2]}"
    else
        keepable_unquote "${KEEP_VALUES[$2]}"
    fi
}

# Decide, asking with a terminal, whether to replace each of a tool's values of your own
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

# Status items naming each of a tool's values you set to your own
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

# Print one line of JSON without a string's quotes, as the <tool>_keep_* functions print values
keepable_unquote() {
    local value="${1#\"}"
    printf '%s\n' "${value%\"}"
}
