# shellcheck shell=bash
# Hashing for the skills step. ai_tools/skills/install.sh sources this file. It only defines
# functions.

# Print one SHA-256 for a directory's contents: each file's hash and path relative to it, which
# files are executable, and each symlink's target. Hashing every file in one run keeps it fast
# for a dir of many files. Fails when the directory doesn't exist or a file can't be read. Any
# further arguments are a find expression for entries to leave out, such as -name .git.
dir_sha256() {
    local dir="$1" hash sums exes links sum
    shift
    [ -d "$dir" ] || return 1
    if command -v sha256sum &>/dev/null; then
        hash=sha256sum
    else
        hash="shasum -a 256"
    fi
    # "$@" becomes the find expression's prefix, since Bash 3.2's local can't be trusted with arrays
    [ $# -eq 0 ] || set -- \( "$@" \) -prune -o
    # shellcheck disable=SC2086 # $hash is a command and its flags
    sums="$(cd "$dir" && find . "$@" -type f -exec $hash {} +)" || return 1
    exes="$(cd "$dir" && find . "$@" -type f -perm -u+x -print)" || return 1
    links="$(cd "$dir" && find . "$@" -type l -print | while IFS= read -r path; do
        printf '%s -> %s\n' "$path" "$(readlink "$path")"
    done)" || return 1
    # The three kinds of line differ in form, so sorting them together keeps them apart
    # shellcheck disable=SC2086
    sum="$(printf '%s\n' "$sums" "$exes" "$links" | LC_ALL=C sort | $hash)"
    echo "${sum%% *}"
}
