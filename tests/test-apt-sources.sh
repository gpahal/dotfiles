#!/bin/bash
set -euo pipefail

# lib/common.sh's apt repo helpers. apt_source_state and status_apt_source judge a step's source
# file by its exact content, so a missing file, a stale suite, and one a release upgrade turned off
# all count. add_apt_repo waits without changing anything while the repo's Release file for this
# release is a 404, and keeps the old key and source when the key's download fails. The chrome
# step's google_source_exists only checks that the .deb's source file is there and on.
# test-docker-sources.sh and test-ubuntu-step.sh cover add_apt_repo's other failures through the
# docker and ubuntu steps.
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
load_script chrome/install.sh
APT_SOURCES_DIR="$SANDBOX/apt/sources.list.d"
stub sudo 'exec env "$@"'

# --- apt_source_state and status_apt_source ---
file="$APT_SOURCES_DIR/example.list"
content="deb [signed-by=/k] https://example.com/ubuntu resolute main"
assert_eq missing "$(apt_source_state "$file" "$content")" "no file"
echo "$content" > "$file"
assert_eq "" "$(apt_source_state "$file" "$content")" "the exact content"
for changed in "# $content # disabled on upgrade to resolute" "${content/resolute/stale-suite}" "$content
deb https://example.com/other resolute main"; do
    echo "$changed" > "$file"
    assert_eq "differs from what setup writes" "$(apt_source_state "$file" "$content")" "a changed file: $changed"
done
# deb822's way of turning a source off
stanza="$(printf '%s\n' "Types: deb" "URIs: https://example.com/ubuntu" "Suites: resolute")"
printf '%s\n' "$stanza" "Enabled: no" > "$file"
assert_eq "differs from what setup writes" "$(apt_source_state "$file" "$stanza")" "a stanza turned off"
echo "$content" > "$file"
assert_eq "  ok         Example's apt source ($file)" "$(status_apt_source Example "$file" "$content" example)" "status, ok"
echo "${content/resolute/stale-suite}" > "$file"
assert_eq "  missing    Example's apt source ($file): differs from what setup writes; re-run the example step" \
    "$(status_apt_source Example "$file" "$content" example)" "status, differing"
rm "$file"
assert_eq "  missing    Example's apt source ($file): missing; re-run the example step" \
    "$(status_apt_source Example "$file" "$content" example)" "status, missing"

# --- add_apt_repo ---
# curl answers the HEAD request for the Release file with $SANDBOX/http-status. fetch writes the
# key, or fails when $SANDBOX/fetch-fails exists. apt-get update succeeds.
stub curl 'cat "'"$SANDBOX"'/http-status"'
fetch() {
    echo "fetch $1" >> "$STUB_LOG"
    [ ! -e "$SANDBOX/fetch-fails" ] || return 1
    echo new-key > "$2"
}
stub apt-get
keyring="$SANDBOX/keyrings/example.gpg"
add() {
    add_apt_repo Example "$file" "$content" https://example.com/key.gpg "$keyring" \
        https://example.com/ubuntu/dists/resolute/Release
}

# No packages for this release yet: it says so, and changes nothing
echo 404 > "$SANDBOX/http-status"
echo "${content/resolute/stale-suite}" > "$file"
assert_exit "$APT_REPO_UNPUBLISHED" add
assert_contains "$RUN_OUTPUT" "Example hasn't published packages for Ubuntu resolute yet; re-run this step later."
assert_eq "${content/resolute/stale-suite}" "$(cat "$file")" "the source while the repo has no packages for this release"
assert_file_not_contains "$STUB_LOG" "fetch"
assert_file_not_contains "$STUB_LOG" "apt-get"

# Published: the key and the source are written, and apt updates from that source alone
echo 200 > "$SANDBOX/http-status"
assert_exit 0 add
assert_eq "$content" "$(cat "$file")" "the source after adding the repo"
assert_eq new-key "$(cat "$keyring")" "the key after adding the repo"
assert_file_contains "$STUB_LOG" "update --error-on=any -o Dir::Etc::sourcelist=$file -o Dir::Etc::sourceparts=-"

# While another update holds apt's lock, the wait shows as it happens, not once the update is
# done: apt-get reports the lock once, then copies what the step has printed so far
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

# The key's download fails, or its host can't be reached: the old key and source stay, and no
# update runs
for http in 200 000; do
    echo "$http" > "$SANDBOX/http-status"
    echo old-key > "$keyring"
    echo "${content/resolute/stale-suite}" > "$file"
    touch "$SANDBOX/fetch-fails"
    : > "$STUB_LOG"
    assert_exit 1 add
    rm "$SANDBOX/fetch-fails"
    assert_eq old-key "$(cat "$keyring")" "the key after its download failed ($http)"
    assert_eq "${content/resolute/stale-suite}" "$(cat "$file")" "the source after the key's download failed ($http)"
    assert_file_not_contains "$STUB_LOG" "apt-get"
done
rm -rf "$APT_SOURCES_DIR" "$SANDBOX/keyrings"
mkdir -p "$APT_SOURCES_DIR"

# --- the chrome step's google_source_exists: the .deb's file, there and on ---
check=google_source_exists
list="$APT_SOURCES_DIR/google-chrome.list"
sources="$APT_SOURCES_DIR/google-chrome.sources"
uri=https://dl.google.com/linux/chrome/deb/
assert_exit 1 "$check"
: > "$list"
assert_exit 1 "$check"
printf '# deb %s stable main # disabled on upgrade to resolute\n' "$uri" > "$list"
assert_exit 1 "$check"
printf '### THIS FILE IS AUTOMATICALLY CONFIGURED ###\n\ndeb [arch=amd64] %s stable main\n' "$uri" > "$list"
assert_exit 0 "$check"
rm "$list"
printf 'deb %s stable main\n' "$uri" > "$list.distUpgrade"
assert_exit 1 "$check"
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nEnabled: no\n' "$uri" > "$sources"
assert_exit 1 "$check"
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\n' "$uri" > "$sources"
assert_exit 0 "$check"
test_done
