# Helpers for sudo changes and system state: root-owned files, third-party apt repos, and linger.
# Source after lib/common.sh.
# shellcheck shell=bash

# install_root_file <src> <dest> [mode] [group] [owner]: writes a temp file and renames it, since
# sudo tee could cut a drop-in short and lose a setting. The leading dot hides the temp file from
# run-parts and *.conf globs. A dangling symlink fails: stat reads it as 777 and mv would replace
# the link. A new directory gets 755 regardless of umask so hook users such as nut can read it.
install_root_file() {
    local src="$1" dest="$2" mode="${3:-}" group="${4:-}" owner="${5:-}" dir tmp opts target
    dir="$(dirname "$dest")"
    sudo test -d "$dir" || sudo install -d -m 0755 "$dir" || return 1
    # mv would move the new file into the directory, and succeed
    if sudo test -d "$dest"; then
        echo "  $dest is a directory; remove it and re-run." >&2
        return 1
    fi
    if sudo test -L "$dest"; then
        if ! target="$(sudo readlink -f -- "$dest" 2>/dev/null)" || [ -z "$target" ] ||
            ! sudo test -e "$target"; then
            echo "  $dest is a symlink to nothing; remove it and re-run." >&2
            return 1
        fi
        dest="$target"
        dir="$(dirname "$dest")"
    fi
    # Through sudo, since the file or its directory may be root-only
    if [ -z "$mode" ]; then
        mode="$(sudo bash -c "$(declare -f file_mode)"'; [ ! -e "$1" ] || file_mode "$1"' _ "$dest")" ||
            return 1
    fi
    tmp="$(sudo mktemp "$dir/.${dest##*/}.XXXXXX")" || return 1
    opts=(-m "${mode:-644}")
    [ -z "$group" ] || opts+=(-g "$group")
    [ -z "$owner" ] || opts+=(-o "$owner")
    if sudo install "${opts[@]}" "$src" "$tmp" && sudo mv -f "$tmp" "$dest"; then
        return 0
    fi
    sudo rm -f "$tmp"
    return 1
}

# write_root_file <dest> <content> [mode] [group] [owner]
write_root_file() {
    local src status=0
    src="$(mktemp)" || return 1
    printf '%s\n' "$2" > "$src" && install_root_file "$src" "$1" "${3:-}" "${4:-}" "${5:-}" || status=1
    rm -f "$src"
    return "$status"
}

# write_root_content <dest-var> <content-var> [mode]: write_root_file taking variable names, so it
# works as an item's fix, such as "write_root_content SLEEP_CONF SLEEP_CONF_CONTENT"
write_root_content() {
    write_root_file "${!1}" "${!2}" "${3:-}"
}

# root_copy_current <src> <dest> <mode>. The mode is fixed, not the repo file's, since a checkout
# can lose exec bits and run-parts skips a non-executable hook.
root_copy_current() {
    cmp -s "$1" "$2" && { [ "$3" != 0755 ] || [ -x "$2" ]; }
}

# install_root_copy <src> <dest> <mode>
install_root_copy() {
    root_copy_current "$@" || install_root_file "$@"
}

# read_root_file <file> [-n]: -n uses sudo -n. Prints nothing when missing, fails when unreadable.
# In a directory only root can search, such as /etc/nut, only sudo can tell whether it exists.
read_root_file() {
    local sudo=(sudo) err=/dev/stderr
    [ "${2:-}" != -n ] || { sudo=(sudo -n); err=/dev/null; }
    if [ -r "$1" ]; then
        cat "$1"
    elif [ -e "$1" ]; then
        "${sudo[@]}" cat "$1" 2>"$err"
    elif [ -x "$(dirname "$1")" ]; then
        return 0
    else
        # shellcheck disable=SC2016 # root's shell expands it
        "${sudo[@]}" sh -c '[ ! -e "$1" ] || cat "$1"' _ "$1" 2>"$err"
    fi
}

# "<owner> <group> <mode>", following symlinks. To run it under sudo, pass both functions:
# sudo bash -c "$(declare -f file_mode owner_group_mode)"'; owner_group_mode "$1"' _ <file>
owner_group_mode() {
    local mode names
    mode="$(file_mode "$1")" && names="$(LC_ALL=C ls -ldL "$1")" || return 1
    # ls -l's third and fourth fields on GNU and BSD alike
    awk -v mode="$mode" '{ print $3, $4, mode; exit }' <<< "$names"
}

SBIN_PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Never search the user's PATH: sudo would run a planted command from e.g. ~/.cargo/bin as root.
sbin_cmd() {
    PATH="$SBIN_PATH" command -v "$1"
}

LINGER_DIR=/var/lib/systemd/linger

# systemd starts your user services at boot, without a login
lingering() {
    [ -e "$LINGER_DIR/$(id -un)" ]
}

# 000 when the host can't be reached
http_status() {
    curl -sIL --connect-timeout 15 --max-time 30 -o /dev/null -w '%{http_code}' "$1" || true
}

# deb822_source <uri> <components> <keyring> [architectures]: the source setup writes for this
# release
deb822_source() {
    printf '%s\n' "Types: deb" "URIs: $1" "Suites: $(ubuntu_codename)" "Components: $2"
    [ -z "${4:-}" ] || echo "Architectures: $4"
    echo "Signed-By: $3"
}

# apt_release_url <uri>: 404s until the repo publishes packages for this release
apt_release_url() {
    echo "$1/dists/$(ubuntu_codename)/Release"
}

# Prints nothing when the file matches what setup writes
apt_source_state() {
    if [ ! -e "$1" ]; then
        echo missing
    elif ! file_is "$1" "$2"; then
        echo "differs from what setup writes"
    fi
}

status_apt_source() {
    local state
    state="$(apt_source_state "$2" "$3")"
    if [ -z "$state" ]; then
        status_item ok "$1's apt source ($2)"
    elif [ "$(http_status "$5")" == 404 ]; then
        status_item missing "$1's apt source ($2): $state; $1 hasn't published packages for Ubuntu $(ubuntu_codename) yet"
    else
        status_item missing "$1's apt source ($2): $state; re-run the $4 step"
    fi
}

# The Release file 404s for a while after a release upgrade, and no step can fix that
apt_repo_published() {
    [ "$(http_status "$2")" != 404 ] && return 0
    echo "  $1 hasn't published packages for Ubuntu $(ubuntu_codename) yet; re-run this step later."
    return 1
}

# Every primary key's fingerprint, since apt trusts every key in the file. A temp GNUPGHOME,
# since --show-keys would create ~/.gnupg.
apt_key_fingerprint() {
    local home
    home="$(mktemp -d)" || return 1
    GNUPGHOME="$home" gpg --show-keys --with-colons "$1" 2>/dev/null |
        awk -F: '$1 == "pub" { primary = 1; next } $1 == "fpr" && primary { print toupper($10); primary = 0 }' ||
        true
    rm -rf "$home"
}

# gpgv, which apt runs, reads a .gpg keyring only unarmored. A temp GNUPGHOME, as above.
dearmor_key() {
    local home out status=0
    home="$(mktemp -d)" || return 1
    if ! out="$(mktemp)"; then
        rm -rf "$home"
        return 1
    fi
    GNUPGHOME="$home" gpg --batch --dearmor < "$1" > "$out" && [ -s "$out" ] && mv -f "$out" "$1" ||
        status=1
    rm -rf "$home" "$out"
    return "$status"
}

# The pinned fingerprint stops a swapped key, which unattended-upgrades would trust as root. A
# source apt can't use breaks every later apt-get update, so on failure the previous source and
# key are restored, or the new ones removed. A previous source with the same content is untested,
# so it goes too. Runs under ||, so each command checks its own failure.
add_apt_repo() {
    local name="$1" file="$2" content="$3" key_url="$4" keyring="$5" fpr="$6"
    local key fingerprint old_key="" output="" previous="" reason="" untested=false
    require_cmd gpg || return 1
    # Read before the key changes, so failing to read changes nothing
    if [ -e "$file" ]; then
        previous="$(sudo cat "$file")" || return 1
    fi
    if [ -n "$previous" ] && [ "$previous" == "$content" ]; then
        previous=""
        untested=true
    fi
    key="$(mktemp)" || return 1
    if ! fetch "$key_url" "$key" "$name's apt key"; then
        rm -f "$key"
        return 1
    fi
    fingerprint="$(apt_key_fingerprint "$key" | join_lines ', ')"
    if [ "$fingerprint" != "$fpr" ]; then
        echo "  $name's apt key from $key_url has the fingerprint ${fingerprint:-(none)}, not $fpr, so" >&2
        echo "  nothing was changed. If $name has published a new key, check its fingerprint against" >&2
        echo "  $name's docs, then update the step's pinned one." >&2
        rm -f "$key"
        return 1
    fi
    case "$keyring" in
        *.gpg)
            if grep -q -- '-----BEGIN PGP' "$key" && ! dearmor_key "$key"; then
                echo "  Couldn't unarmor $name's apt key, so nothing was changed." >&2
                rm -f "$key"
                return 1
            fi
            ;;
    esac
    # An untested source's key goes with it
    if ! "$untested" && [ -e "$keyring" ] && ! { old_key="$(mktemp)" && cp "$keyring" "$old_key"; }; then
        rm -f "$key" "$old_key"
        return 1
    fi
    if ! install_root_file "$key" "$keyring" 0644; then
        rm -f "$key" "$old_key"
        return 1
    fi
    rm -f "$key"
    # shellcheck disable=SC2034 # apt_install_fresh, in lib/common.sh, reads it
    APT_LISTS_FRESH=""
    # The key has changed, so a failed write gets the same rollback as a failed update. --error-on=any
    # fails on an unverifiable key, which apt-get update otherwise only warns about.
    if ! file_is "$file" "$content" && ! write_root_file "$file" "$content"; then
        reason="Writing $file failed"
    else
        echo "  Updating apt's lists for $name (this waits while another apt update holds the lock)..."
        if ! output="$(apt_get_update --error-on=any -o Dir::Etc::sourcelist="$file" \
            -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)"; then
            printf '%s\n' "$output" >&2
            reason="apt-get update failed with the new $file alone"
            # A lock still held after apt_get_update's tries says nothing about this source, so keep it
            if apt_lists_locked <<< "$output"; then
                echo "  Another apt-get update holds apt's lock, so $file was kept. Re-run once it finishes." >&2
                rm -f "$old_key"
                return 1
            fi
        fi
    fi
    if [ -n "$reason" ]; then
        if [ -n "$previous" ]; then
            if write_root_file "$file" "$previous"; then
                echo "  $reason, so the old one is back. Fix the error above and re-run." >&2
            else
                echo "  $reason, and putting the old one back failed too. Fix $file by hand, or delete it, then re-run." >&2
            fi
        elif sudo rm -f "$file"; then
            if "$untested"; then
                echo "  $reason. An earlier run left it, and it still fails, so it was removed. Fix the error above and re-run." >&2
            else
                echo "  $reason, so it was removed. Fix the error above and re-run." >&2
            fi
        else
            echo "  $reason, and removing it failed too. Delete $file by hand, then re-run." >&2
        fi
        if [ -n "$old_key" ]; then
            install_root_file "$old_key" "$keyring" 0644
        else
            sudo rm -f "$keyring"
        fi || echo "  Couldn't put $name's old key back at $keyring. Re-run to install it again." >&2
        rm -f "$old_key"
        return 1
    fi
    rm -f "$old_key"
    printf '%s\n' "$output"
}

# The suite apt sources name, such as resolute
ubuntu_codename() {
    (
        # shellcheck source=/dev/null
        . "${OS_RELEASE:-/etc/os-release}" 2>/dev/null || true
        echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    )
}
