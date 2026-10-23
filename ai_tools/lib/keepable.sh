# shellcheck shell=bash
# Settings a user may override, such as the model: set when unset, and replaced only when
# replace_custom_value agrees. A step lists them in an array of <jq path> <JSON value> <name>
# triples. keep_read <array> <settings as JSON> sets <array>_CURRENT and <array>_WANTED, one entry
# per triple (strings bare, other values as compact JSON, empty when unset), and keep_choose sets
# <array>_REPLACE. keep_value <array> CURRENT|WANTED|REPLACE <index> prints one.

# Sets the caller's triples and n
_keep_triples() {
    eval "triples=(\"\${$1[@]}\")"
    n=$((${#triples[@]} / 3))
}

keep_read() {
    local triples n k filter="" json="${2:-null}" line
    _keep_triples "$1"
    for ((k = 0; k < n; k++)); do filter+="([try (${triples[k * 3]})][0] | f), "; done
    for ((k = 0; k < n; k++)); do filter+="(${triples[k * 3 + 1]} | f), "; done
    jq -s -e "length == 1" <<< "$json" &> /dev/null || json=null
    eval "$1_CURRENT=() $1_WANTED=()"
    k=0
    # shellcheck disable=SC2034 # the evals read line
    while IFS= read -r line; do
        if [ "$k" -lt "$n" ]; then
            eval "$1_CURRENT[k]=\"\$line\""
        else
            eval "$1_WANTED[k - n]=\"\$line\""
        fi
        k=$((k + 1))
    done < <(jq -r 'def f: if . == null then "" elif type == "string" then . else tojson end;
        '"${filter%, }" <<< "$json")
}

keep_value() {
    eval "printf '%s\n' \"\${$1_$2[$3]:-}\""
}

keep_choose() {
    local triples n k
    _keep_triples "$1"
    eval "$1_REPLACE=()"
    for ((k = 0; k < n; k++)); do
        if replace_custom_value "${triples[k * 3 + 2]}" "$(keep_value "$1" CURRENT "$k")" \
            "$(keep_value "$1" WANTED "$k")"; then
            eval "$1_REPLACE[k]=true"
        fi
    done
}

keep_status() {
    local triples n k current wanted
    _keep_triples "$1"
    for ((k = 0; k < n; k++)); do
        current="$(keep_value "$1" CURRENT "$k")"
        wanted="$(keep_value "$1" WANTED "$k")"
        if [ -n "$current" ] && [ "$current" != "$wanted" ]; then
            status_custom_value "${triples[k * 3 + 2]}" "$current" "$wanted"
        fi
    done
}
