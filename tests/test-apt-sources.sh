#!/bin/bash
set -euo pipefail

# lib/system.sh's apt sources: status_apt_source, apt_repo_published, add_apt_repo's checks and
# rollbacks, and apt_get_update's lock retries.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
load_script lib/common.sh
load_script lib/system.sh
stub_sudo_exec
real_install="$(command -v install)"
real_mv="$(command -v mv)"

# --- status_apt_source ---
file="$APT_SOURCES_DIR/example.list"
content="deb [signed-by=/k] https://example.com/ubuntu resolute main"
release=https://example.com/dists/resolute/Release
# A release upgrade's source isn't fixable by re-running the step until the repo publishes
echo "${content/resolute/stale-suite}" > "$file"
stub_http_status 404
status_out="$(status_apt_source Example "$file" "$content" example "$release")"
assert_contains "$status_out" "missing    Example's apt source"
assert_contains "$status_out" "hasn't published packages for Ubuntu resolute yet"
rm "$file"

# --- apt_repo_published ---
release_url=https://example.com/ubuntu/dists/resolute/Release
# An unreachable host counts as published, so add_apt_repo's own failure says what's wrong
stub_http_status 404
assert_exit 1 apt_repo_published Example "$release_url"
for http in 200 000; do
    stub_http_status "$http"
    assert_exit 0 apt_repo_published Example "$release_url"
done

# --- add_apt_repo ---
# served-key holds one fingerprint per key; gpg prints each as --with-colons does
fpr=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
echo "$fpr" | tr 'A-F' 'a-f' > "$SANDBOX/served-key"
replace_fn fetch 'echo "fetch $1" >> "$STUB_LOG"
[ ! -e "$SANDBOX/fetch-fails" ] || return 1
cp "$SANDBOX/served-key" "$2"'
stub gpg 'for key; do :; done
if [ "$1 $2" == "--batch --dearmor" ]; then
    grep -v "^-----"
    exit
fi
[ "$1 $2" == "--show-keys --with-colons" ] || exit 2
grep -v "^-----" "$key" | while IFS= read -r f; do
    printf "pub:-:4096:1:%s:1487788586:::-:::scESC::::::23::0:\n" "$(echo "$f" | cut -c 25-)"
    printf "fpr:::::::::%s:\n" "$f"
    printf "sub:-:4096:1:7EA0A9C3F273FCD8:1487788586::::::s::::::23:\nfpr:::::::::D3306A018370199E527AE7997EA0A9C3F273FCD8:\n"
done'
stub apt-get
keyring="$SANDBOX/keyrings/example.gpg"
add() {
    add_apt_repo Example "$file" "$content" https://example.com/key.gpg "$keyring" "$fpr"
}
# shellcheck disable=SC2034 # apt_get_update reads them
APT_UPDATE_RETRY_DELAY=0 APT_UPDATE_TRIES=4
reset() {
    rm -rf "$APT_SOURCES_DIR" "$SANDBOX/keyrings"
    mkdir -p "$APT_SOURCES_DIR" "$SANDBOX/keyrings"
    echo "$fpr" > "$SANDBOX/served-key"
    : > "$STUB_LOG"
}

echo "${content/resolute/stale-suite}" > "$file"
assert_exit 0 add
assert_eq "$content" "$(cat "$file")" "the source after adding the repo"
assert_eq "$(cat "$SANDBOX/served-key")" "$(cat "$keyring")" "the key after adding the repo"
assert_file_contains "$STUB_LOG" "update --error-on=any -o Dir::Etc::sourcelist=$file -o Dir::Etc::sourceparts=-"

# apt's gpgv reads a .gpg keyring only unarmored
printf '%s\n' "-----BEGIN PGP PUBLIC KEY BLOCK-----" "$fpr" "-----END PGP PUBLIC KEY BLOCK-----" > "$SANDBOX/served-key"
assert_exit 0 add
assert_eq "$fpr" "$(cat "$keyring")" "an armored key in a .gpg keyring"
echo "$fpr" > "$SANDBOX/served-key"

echo old-key > "$keyring"
echo "${content/resolute/stale-suite}" > "$file"
echo 0123456789ABCDEF0123456789ABCDEF01234567 > "$SANDBOX/served-key"
: > "$STUB_LOG"
assert_exit 1 add
assert_eq old-key "$(cat "$keyring")" "the key after a key with another fingerprint"
assert_eq "${content/resolute/stale-suite}" "$(cat "$file")" "the source after a key with another fingerprint"
assert_eq "sudo cat $file" "$(grep '^sudo' "$STUB_LOG")" "sudo calls for a key with another fingerprint"
assert_file_not_contains "$STUB_LOG" "apt-get"
# apt would trust a second key too
printf '%s\n' "$fpr" 0123456789ABCDEF0123456789ABCDEF01234567 > "$SANDBOX/served-key"
assert_exit 1 add
assert_eq old-key "$(cat "$keyring")" "the key after a download with a second key"
echo "<html>" > "$SANDBOX/served-key"
stub_gpg="$(cat "$STUB_DIR/gpg")"
stub gpg 'echo "gpg: no valid OpenPGP data found." >&2; exit 2'
assert_exit 1 add
assert_eq old-key "$(cat "$keyring")" "the key after a download that isn't a key"
printf '%s\n' "$stub_gpg" > "$STUB_DIR/gpg"
echo "$fpr" > "$SANDBOX/served-key"

# A source an earlier run left isn't known to work, so a failed update removes it
echo "$content" > "$file"
echo "$fpr" > "$keyring"
stub apt-get 'echo "E: The repository is not signed."; exit 100'
assert_exit 1 add
[ ! -e "$file" ] || fail "a source that still fails was put back"
[ ! -e "$keyring" ] || fail "the key of a source that still fails was put back"
echo "${content/resolute/stale-suite}" > "$file"
echo old-key > "$keyring"
assert_exit 1 add
assert_eq "${content/resolute/stale-suite}" "$(cat "$file")" "the source after a failed update"
assert_eq old-key "$(cat "$keyring")" "the key after a failed update"
# A new source fails its first update: it and its new key go
reset
assert_exit 1 add
[ ! -e "$file" ] || fail "a new source was kept after its update failed"
[ ! -e "$keyring" ] || fail "a new key was kept after its source's update failed"
stub apt-get

# The lock wait must show as it happens, not once the update is done
rm -f "$file"
stub apt-get 'if [ ! -e "'"$SANDBOX"'/locked-once" ]; then
    touch "'"$SANDBOX"'/locked-once"
    echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 812 (apt-get)"
    exit 100
fi
cat "'"$SANDBOX"'/add-output" > "'"$SANDBOX"'/seen-during-update"'
add > "$SANDBOX/add-output" 2>&1 || fail "add_apt_repo failed after the lock was freed"
seen="$(cat "$SANDBOX/seen-during-update")"
assert_contains "$seen" "Updating apt's lists for Example" "output before the update"
assert_contains "$seen" "apt's lists lock is held by another update" "output before the update"
stub apt-get

# A lock still held isn't the source's fault, so it stays
reset
stub apt-get 'echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 6 (apt-get)" >&2
exit 100'
assert_exit 1 add
assert_eq "$content" "$(cat "$file" 2> /dev/null)" "the source while another update held the lock"
stub apt-get

reset
echo old-key > "$keyring"
echo "${content/resolute/stale-suite}" > "$file"
touch "$SANDBOX/fetch-fails"
assert_exit 1 add
rm "$SANDBOX/fetch-fails"
assert_eq old-key "$(cat "$keyring")" "the key after its download failed"
assert_eq "${content/resolute/stale-suite}" "$(cat "$file")" "the source after the key's download failed"
assert_file_not_contains "$STUB_LOG" "apt-get"

# Writing the key fails partway: the old one stays, with no temp file beside it
reset
echo old-key > "$keyring"
stub install 'dest="${!#}"
if [[ "${dest##*/}" == .example.gpg.* ]]; then
    echo "ne" > "$dest"
    exit 1
fi
exec "'"$real_install"'" "$@"'
assert_exit 1 add
rm "$STUB_DIR/install"
assert_eq old-key "$(cat "$keyring")" "the key after writing it failed partway"
assert_eq example.gpg "$(ls -A "$SANDBOX/keyrings")" "files beside the key after writing it failed"
[ ! -e "$file" ] || fail "the source was written after the key failed"

# Writing the source fails: the old key and source are back, or no source, with no temp files
stub mv 'if [ "${!#}" = "'"$file"'" ] && rm "'"$SANDBOX"'/mv-fails-once" 2> /dev/null; then
    exit 1
fi
exec "'"$real_mv"'" "$@"'
for before in source none; do
    reset
    echo old-key > "$keyring"
    [ "$before" != source ] || echo "old source" > "$file"
    touch "$SANDBOX/mv-fails-once"
    assert_exit 1 add
    assert_eq old-key "$(cat "$keyring")" "the key after writing the source failed ($before before)"
    if [ "$before" = source ]; then
        assert_eq "old source" "$(cat "$file")" "the source after writing it failed"
    else
        [ ! -e "$file" ] || fail "a source was kept after writing it failed"
    fi
    assert_eq "$([ "$before" != source ] || echo example.list)" "$(ls -A "$APT_SOURCES_DIR")" \
        "files beside the source after writing it failed ($before before)"
    assert_file_not_contains "$STUB_LOG" "apt-get"
done
# Putting the old source back fails too: say so, rather than that it's back
stub mv '[ "${!#}" != "'"$file"'" ] || exit 1
exec "'"$real_mv"'" "$@"'
reset
echo old-key > "$keyring"
echo "old source" > "$file"
assert_exit 1 add
assert_contains "$RUN_OUTPUT" "putting the old one back failed too"
rm "$STUB_DIR/mv"

# An unreadable source: nothing changes
reset
echo old-key > "$keyring"
echo "old source" > "$file"
chmod 000 "$file"
if [ ! -r "$file" ]; then
    assert_exit 1 add
    chmod 644 "$file"
    assert_eq old-key "$(cat "$keyring")" "the key when the source can't be read"
    assert_eq "old source" "$(cat "$file")" "an unreadable source"
    assert_file_not_contains "$STUB_LOG" "apt-get"
else
    echo "Skipped the unreadable source case: root reads any file"
fi
chmod 644 "$file"

# --- apt_install_fresh ---
# One update serves the run, until add_apt_repo changes a source or key
reset
stub apt-get
# shellcheck disable=SC2034 # apt_install_fresh reads it
APT_LISTS_FRESH=""
apt_install_fresh one > /dev/null 2>&1 || fail "apt_install_fresh one failed"
apt_install_fresh two > /dev/null 2>&1 || fail "apt_install_fresh two failed"
assert_eq 1 "$(grep -c "^apt-get .* update$" "$STUB_LOG")" "apt-get updates for two installs"
add > /dev/null 2>&1 || fail "add_apt_repo failed"
apt_install_fresh three > /dev/null 2>&1 || fail "apt_install_fresh three failed"
assert_eq 2 "$(grep -c "^apt-get .* update$" "$STUB_LOG")" "apt-get updates after add_apt_repo"

# --- apt_get_update ---
# Retried only for apt's lists lock, which apt-daily can hold
stub apt-get 'S="'"$SANDBOX"'"
if [ -e "$S/apt-broken" ]; then
    echo "E: The repository http://example.invalid resolute Release does not have a Release file." >&2
    exit 100
fi
n="$(cat "$S/locked" 2>/dev/null || echo 0)"
[ "$n" -gt 0 ] || exit 0
echo $((n - 1)) > "$S/locked"
echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 812 (apt-get)" >&2
echo "E: Unable to lock directory /var/lib/apt/lists/" >&2
exit 100'
updates() { grep -c "^apt-get .* update$" "$STUB_LOG" || true; }
: > "$STUB_LOG"
echo 2 > "$SANDBOX/locked"
assert_exit 0 apt_get_update
assert_eq 3 "$(updates)" "apt-get updates after two lock failures"
: > "$STUB_LOG"
echo 100 > "$SANDBOX/locked"
assert_exit 100 apt_get_update
assert_eq "$APT_UPDATE_TRIES" "$(updates)" "apt-get updates while the lock stays held"
: > "$STUB_LOG"
rm "$SANDBOX/locked"
touch "$SANDBOX/apt-broken"
assert_exit 100 apt_get_update
assert_eq 1 "$(updates)" "apt-get updates after another error"
test_done
