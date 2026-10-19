#!/bin/bash
set -euo pipefail

# test-docker-sources.sh covers add_apt_repo's other failures
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
load_script chrome/install.sh
APT_SOURCES_DIR="$SANDBOX/apt/sources.list.d"
stub_sudo_exec

# --- apt_source_state and status_apt_source ---
file="$APT_SOURCES_DIR/example.list"
content="deb [signed-by=/k] https://example.com/ubuntu resolute main"
assert_eq missing "$(apt_source_state "$file" "$content")" "no file"
echo "$content" > "$file"
assert_eq "" "$(apt_source_state "$file" "$content")" "the exact content"
echo "# $content" > "$file"
assert_eq "differs from what setup writes" "$(apt_source_state "$file" "$content")" "a changed file"
stub curl 'cat "'"$SANDBOX"'/http-status"'
release=https://example.com/dists/resolute/Release
echo 200 > "$SANDBOX/http-status"
echo "$content" > "$file"
assert_eq "  ok         Example's apt source ($file)" \
    "$(status_apt_source Example "$file" "$content" example "$release")" "status, ok"
echo "${content/resolute/stale-suite}" > "$file"
assert_eq "  missing    Example's apt source ($file): differs from what setup writes; re-run the example step" \
    "$(status_apt_source Example "$file" "$content" example "$release")" "status, differing"
echo 404 > "$SANDBOX/http-status"
assert_eq "  missing    Example's apt source ($file): differs from what setup writes; Example hasn't published packages for Ubuntu resolute yet" \
    "$(status_apt_source Example "$file" "$content" example "$release")" "status, differing, not yet published"
echo 200 > "$SANDBOX/http-status"
rm "$file"
assert_eq "  missing    Example's apt source ($file): missing; re-run the example step" \
    "$(status_apt_source Example "$file" "$content" example "$release")" "status, missing"

# --- add_apt_repo ---
# served-key holds one fingerprint per key; gpg prints each as --with-colons does
fpr=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
echo "$fpr" | tr 'A-F' 'a-f' > "$SANDBOX/served-key"
replace_fn fetch 'echo "fetch $1" >> "$STUB_LOG"
[ ! -e "$SANDBOX/fetch-fails" ] || return 1
cp "$SANDBOX/served-key" "$2"'
stub gpg 'for key; do :; done
[ "$1 $2" == "--show-keys --with-colons" ] || exit 2
while IFS= read -r f; do
    printf "pub:-:4096:1:%s:1487788586:::-:::scESC::::::23::0:\n" "$(echo "$f" | cut -c 25-)"
    printf "fpr:::::::::%s:\n" "$f"
    printf "sub:-:4096:1:7EA0A9C3F273FCD8:1487788586::::::s::::::23:\nfpr:::::::::D3306A018370199E527AE7997EA0A9C3F273FCD8:\n"
done < "$key"'
stub apt-get
keyring="$SANDBOX/keyrings/example.gpg"
add() {
    add_apt_repo Example "$file" "$content" https://example.com/key.gpg "$keyring" "$fpr"
}
release_url=https://example.com/ubuntu/dists/resolute/Release

# An unreachable host counts as published, so add_apt_repo's own failure says what's wrong
echo 404 > "$SANDBOX/http-status"
assert_exit 1 apt_repo_published Example "$release_url"
assert_contains "$RUN_OUTPUT" "Example hasn't published packages for Ubuntu resolute yet; re-run this step later."
for http in 200 000; do
    echo "$http" > "$SANDBOX/http-status"
    assert_exit 0 apt_repo_published Example "$release_url"
done

echo "${content/resolute/stale-suite}" > "$file"
assert_exit 0 add
assert_eq "$content" "$(cat "$file")" "the source after adding the repo"
assert_eq "$(cat "$SANDBOX/served-key")" "$(cat "$keyring")" "the key after adding the repo"
assert_file_contains "$STUB_LOG" "update --error-on=any -o Dir::Etc::sourcelist=$file -o Dir::Etc::sourceparts=-"

echo old-key > "$keyring"
echo "${content/resolute/stale-suite}" > "$file"
echo 0123456789ABCDEF0123456789ABCDEF01234567 > "$SANDBOX/served-key"
: > "$STUB_LOG"
assert_exit 1 add
assert_contains "$RUN_OUTPUT" "Example's apt key from https://example.com/key.gpg has the fingerprint 0123456789ABCDEF0123456789ABCDEF01234567, not $fpr"
assert_eq old-key "$(cat "$keyring")" "the key after a key with another fingerprint"
assert_eq "${content/resolute/stale-suite}" "$(cat "$file")" "the source after a key with another fingerprint"
assert_eq "sudo cat $file" "$(grep '^sudo' "$STUB_LOG")" "sudo calls for a key with another fingerprint"
assert_file_not_contains "$STUB_LOG" "apt-get"
# apt would trust a second key too
printf '%s\n' "$fpr" 0123456789ABCDEF0123456789ABCDEF01234567 > "$SANDBOX/served-key"
assert_exit 1 add
assert_contains "$RUN_OUTPUT" "has the fingerprint $fpr, 0123456789ABCDEF0123456789ABCDEF01234567, not $fpr"
assert_eq old-key "$(cat "$keyring")" "the key after a download with a second key"
echo "<html>" > "$SANDBOX/served-key"
stub_gpg="$(cat "$STUB_DIR/gpg")"
stub gpg 'echo "gpg: no valid OpenPGP data found." >&2; exit 2'
assert_exit 1 add
assert_contains "$RUN_OUTPUT" "has the fingerprint (none), not $fpr"
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
assert_contains "$RUN_OUTPUT" "An earlier run left it, and it still fails, so it was removed."
assert_not_contains "$RUN_OUTPUT" "the old one is back"
echo "${content/resolute/stale-suite}" > "$file"
echo old-key > "$keyring"
assert_exit 1 add
assert_eq "${content/resolute/stale-suite}" "$(cat "$file")" "the source after a failed update"
assert_eq old-key "$(cat "$keyring")" "the key after a failed update"
assert_contains "$RUN_OUTPUT" "so the old one is back"
stub apt-get

# The lock wait must show as it happens, not once the update is done
# shellcheck disable=SC2034 # apt_get_update reads it
APT_UPDATE_RETRY_DELAY=0
rm "$file"
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

echo old-key > "$keyring"
echo "${content/resolute/stale-suite}" > "$file"
touch "$SANDBOX/fetch-fails"
: > "$STUB_LOG"
assert_exit 1 add
rm "$SANDBOX/fetch-fails"
assert_eq old-key "$(cat "$keyring")" "the key after its download failed"
assert_eq "${content/resolute/stale-suite}" "$(cat "$file")" "the source after the key's download failed"
assert_file_not_contains "$STUB_LOG" "apt-get"
rm -rf "$APT_SOURCES_DIR" "$SANDBOX/keyrings"
mkdir -p "$APT_SOURCES_DIR"

# --- the chrome step's google_source_exists ---

check=google_source_exists
GOOGLE_SOURCES="$APT_SOURCES_DIR/google-chrome.sources"
uri=https://dl.google.com/linux/chrome-stable/deb/
assert_exit 1 "$check"
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nEnabled: no\n' "$uri" > "$GOOGLE_SOURCES"
assert_exit 1 "$check"
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\n' "$uri" > "$GOOGLE_SOURCES"
assert_exit 0 "$check"
test_done
