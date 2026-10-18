# shellcheck shell=bash
# The readers of homebrew/Brewfile and of homebrew/install.sh's cask and App Store lists that
# scripts/check-docs.sh and scripts/check-brew-packages.sh share. It only defines functions.

# Print each formula in a Brewfile, a space, and "mac" when it's in an `if OS.mac?` block, or "any"
# e.g. brewfile_formulae homebrew/Brewfile
brewfile_formulae() {
    awk '/^if OS\.mac\?/ { mac = 1; next } mac && /^end/ { mac = 0; next }
        $1 == "brew" { name = $2; gsub(/[",]/, "", name); print name, (mac ? "mac" : "any") }' "$1"
}

# Print the entries of one of homebrew/install.sh's arrays, written one per line, without their
# indent or quotes, skipping comments. Reads the file rather than sourcing it, so the check runs
# none of the step's code.
# e.g. array_entries homebrew/install.sh MAS_APPS
array_entries() {
    awk -v name="$2" '$0 == name "=(" { on = 1; next } on && /^\)/ { exit }
        on && NF && $1 !~ /^#/ { sub(/^[ \t]+/, ""); gsub(/"/, ""); print }' "$1"
}

# Print the casks in one of homebrew/install.sh's arrays, one per line
# e.g. cask_list homebrew/install.sh UBUNTU_CASKS
cask_list() {
    array_entries "$1" "$2" | awk '{ print $1 }'
}
