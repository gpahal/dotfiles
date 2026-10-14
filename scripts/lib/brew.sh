# shellcheck shell=bash
# The readers of homebrew/Brewfile and homebrew/install.sh's cask lists that scripts/check-docs.sh
# and scripts/check-brew-packages.sh share. It only defines functions.

# Print each formula in a Brewfile, a space, and "mac" when it's in an `if OS.mac?` block, or "any"
# e.g. brewfile_formulae homebrew/Brewfile
brewfile_formulae() {
    awk '/^if OS\.mac\?/ { mac = 1; next } mac && /^end/ { mac = 0; next }
        $1 == "brew" { name = $2; gsub(/[",]/, "", name); print name, (mac ? "mac" : "any") }' "$1"
}

# Print the casks in one of homebrew/install.sh's arrays, one per line. Reads the file rather than
# sourcing it, so the check runs none of the step's code.
# e.g. cask_list homebrew/install.sh UBUNTU_CASKS
cask_list() {
    awk -v name="$2" '$0 == name "=(" { on = 1; next } on && /^\)/ { exit } on && NF && $1 !~ /^#/ { print $1 }' "$1"
}
