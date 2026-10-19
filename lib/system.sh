# Helpers for the steps and scripts that change the system with sudo: root-owned files and
# third-party apt repos. The item list that drives a step's sudo changes is in lib/common.sh. The
# ubuntu, docker, and chrome steps, macos/setup-touch-id-sudo.sh, and ubuntu/setup-alerts.sh
# source it. Source it after lib/common.sh, whose helpers it uses; don't run it.
# shellcheck shell=bash

# Replace a root-owned file with a copy of a local file, with sudo, creating its directory. The
# copy goes to a temp file in the same directory, which is then renamed into place, so a failed
# write leaves the old file whole: sudo tee would cut it short, and a drop-in cut short can lose a
# setting such as PasswordAuthentication no. The temp file's leading dot keeps run-parts and
# *.conf globs from reading it. The file keeps its mode unless one is given; a new one gets 644.
# A group, when given, is set by the same install, so no write can leave the file without it. A
# symlink's target is replaced, as replace_file does, and a dangling one fails: stat reads a
# link's own mode as 777, and mv would replace the link with a file of that mode. A missing
# directory gets 755 whatever the umask, so the users the hooks run as, such as nut, can read
# what's in it; an existing one keeps its mode, since install -d would reset it.
# Usage: install_root_file <src> <dest> [mode] [group]
install_root_file() {
    local src="$1" dest="$2" mode="${3:-}" group="${4:-}" dir tmp opts target
    dir="$(dirname "$dest")"
    sudo test -d "$dir" || sudo install -d -m 0755 "$dir" || return 1
    # mv would move the new file into a directory, and succeed
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
    if sudo install "${opts[@]}" "$src" "$tmp" && sudo mv -f "$tmp" "$dest"; then
        return 0
    fi
    sudo rm -f "$tmp"
    return 1
}

# Write content, plus a newline, to a root-owned file, as install_root_file does
# Usage: write_root_file <dest> <content> [mode] [group]
write_root_file() {
    local src status=0
    src="$(mktemp)" || return 1
    printf '%s\n' "$2" > "$src" && install_root_file "$src" "$1" "${3:-}" "${4:-}" || status=1
    rm -f "$src"
    return "$status"
}

# read_root_file <file> [-n]: print a root-owned file a step installs, through sudo when only root
# can read it, with -n through sudo -n, which works only while credentials are cached. Prints
# nothing when it's missing, and fails when it can't be read.
read_root_file() {
    if [ ! -e "$1" ]; then
        return 0
    elif [ -r "$1" ]; then
        cat "$1"
    elif [ "${2:-}" == -n ]; then
        sudo -n cat "$1" 2>/dev/null
    else
        sudo cat "$1"
    fi
}

# Print the HTTP status of a HEAD request for a URL: 200 when it's there, 404 when it isn't, and
# 000 when its host can't be reached
http_status() {
    curl -sIL --connect-timeout 15 --max-time 30 -o /dev/null -w '%{http_code}' "$1" || true
}

# Print what's wrong with an apt source file a step owns, or nothing when it reads exactly what the
# step writes: "missing", or "differs from what setup writes", as when a release upgrade comments
# it out, adds Enabled: no, or leaves the old release's suite
# e.g. apt_source_state "$DOCKER_SOURCES" "$(docker_sources)"
apt_source_state() {
    if [ ! -e "$1" ]; then
        echo missing
    elif ! file_is "$1" "$2"; then
        echo "differs from what setup writes"
    fi
}

# Report an apt source file a step owns, as apt_source_state judges it. A re-run fixes it only once
# the repo publishes packages for this release (apt_repo_published).
# e.g. status_apt_source Docker "$DOCKER_SOURCES" "$(docker_sources)" docker "$(docker_release_url)"
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

# Whether a repo has published packages for this release: its release check URL (the repo's Release
# file for this release) isn't a 404, as it is for a while after a release upgrade. Nothing a step
# does fixes that, so when it hasn't, this says to wait, and the step leaves the repo alone without
# asking for sudo.
# e.g. apt_repo_published Docker "$(docker_release_url)"
apt_repo_published() {
    [ "$(http_status "$2")" != 404 ] && return 0
    echo "  $1 hasn't published packages for Ubuntu $(ubuntu_codename) yet; re-run this step later."
    return 1
}

# Print the fingerprint of each key in an OpenPGP key file, its primary key's, uppercase, one per
# line, or nothing when it holds none. Every key counts, since apt trusts every key in the file.
# gpg gets a temp home, since --show-keys would create ~/.gnupg.
apt_key_fingerprint() {
    local home
    home="$(mktemp -d)" || return 1
    GNUPGHOME="$home" gpg --show-keys --with-colons "$1" 2>/dev/null |
        awk -F: '$1 == "pub" { primary = 1; next } $1 == "fpr" && primary { print toupper($10); primary = 0 }' ||
        true
    rm -rf "$home"
}

# Add a third-party apt repo whose source file a step owns: install its key, write the source when
# its content differs, and update from that file alone, so a failure is the repo's. The key must
# have the fingerprint the step pins, so a swapped key, which unattended-upgrades would then trust
# as root, fails before anything changes. A source apt can't use fails every later apt-get update,
# so on failure the previous source and key come back, or the new ones go. A previous source that
# already held this content isn't known to work, as when a held lists lock kept it untested, so it
# goes too. Callers first check apt_repo_published, before asking for sudo, so they ask for nothing
# they can't do. Run it as `add_apt_repo ... || ...`, where set -e is off, so each command checks
# its own failure.
# e.g. add_apt_repo Docker "$DOCKER_SOURCES" "$(docker_sources)" "$DOCKER_KEY_URL" "$DOCKER_KEYRING" "$DOCKER_KEY_FPR"
add_apt_repo() {
    local name="$1" file="$2" content="$3" key_url="$4" keyring="$5" fpr="$6"
    local key fingerprint old_key="" output="" previous="" reason="" untested=false
    require_cmd gpg || return 1
    # Read the source to restore before the key changes, so failing to read it changes nothing
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
    # An untested source's key goes with it
    if ! "$untested" && [ -e "$keyring" ] && ! { old_key="$(mktemp)" && cp "$keyring" "$old_key"; }; then
        rm -f "$key" "$old_key"
        return 1
    fi
    # A failed write leaves the old key
    if ! sudo install -m 0755 -d "$(dirname "$keyring")" || ! install_root_file "$key" "$keyring" 0644; then
        rm -f "$key" "$old_key"
        return 1
    fi
    rm -f "$key"
    # A failed write leaves the old source, but the key has changed, so it gets the same rollback
    # as a failed update. --error-on=any fails on a key apt can't verify, which apt-get update
    # otherwise only warns about. A lists lock another update still holds after apt_get_update's
    # tries says nothing about this source.
    if ! file_is "$file" "$content" && ! write_root_file "$file" "$content"; then
        reason="Writing $file failed"
    else
        echo "  Updating apt's lists for $name (this waits while another apt update holds the lock)..."
        if ! output="$(apt_get_update --error-on=any -o Dir::Etc::sourcelist="$file" \
            -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)"; then
            printf '%s\n' "$output" >&2
            reason="apt-get update failed with the new $file alone"
            # The new file and the key it names stay then
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
        # Put the old key back, or remove the new one when there was none to keep
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

# Print this Ubuntu release's codename, such as resolute, which apt sources name as their suite
ubuntu_codename() {
    (
        # shellcheck source=/dev/null
        . "${OS_RELEASE:-/etc/os-release}" 2>/dev/null || true
        echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    )
}
