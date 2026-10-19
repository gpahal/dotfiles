# shellcheck shell=bash

# Prints "<formula> mac" inside an `if OS.mac?` block, else "<formula> any".
brewfile_formulae() {
    awk '/^if OS\.mac\?/ { mac = 1; next } mac && /^end/ { mac = 0; next }
        $1 == "brew" { name = $2; gsub(/[",]/, "", name); print name, (mac ? "mac" : "any") }' "$1"
}

# Reads the array rather than sourcing the step, so none of its code runs.
# e.g. cask_list homebrew/install.sh UBUNTU_CASKS
cask_list() {
    awk -v name="$2" '$0 == name "=(" { on = 1; next } on && /^\)/ { exit }
        on && NF && $1 !~ /^#/ { gsub(/"/, "", $1); print $1 }' "$1"
}
