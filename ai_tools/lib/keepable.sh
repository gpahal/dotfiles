# shellcheck shell=bash
# Settings a user may override, such as the model: set when unset, and replaced only when
# replace_custom_value agrees. A step lists them in an array of <jq path> <JSON value> <name>
# triples.

# read_custom_values <settings as JSON> <triple...>: sets CUSTOM_VALUES to each triple's current
# value and the repo's, in turn: strings bare, other values as compact JSON, and the current one
# empty when unset.
read_custom_values() {
    local json="${1:-null}" filter="" line
    shift
    while [ $# -ge 3 ]; do
        filter+="([try ($1)][0] | f), ($2 | f), "
        shift 3
    done
    jq -s -e "length == 1" <<< "$json" &> /dev/null || json=null
    CUSTOM_VALUES=()
    while IFS= read -r line; do
        CUSTOM_VALUES+=("$line")
    done < <(jq -r 'def f: if . == null then "" elif type == "string" then . else tojson end;
        '"${filter%, }" <<< "$json")
}
