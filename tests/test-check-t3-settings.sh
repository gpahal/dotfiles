#!/bin/bash
set -euo pipefail

# scripts/check-t3-settings.sh, with GitHub stubbed, reads the latest release's tag, or the one
# given, downloads T3 Code's schemas at it, and fails naming each key the t3-code step writes that
# they lack.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
unset GITHUB_TOKEN

# GitHub: the latest release is v9.9.9, and a raw file is the one of the same name in
# $SANDBOX/upstream, or missing
mkdir -p "$SANDBOX/upstream"
stub curl 'out="" url="${!#}"
while [ $# -gt 0 ]; do
    [ "$1" != -o ] || out="$2"
    shift
done
case "$url" in
    */releases/latest) echo "  \"tag_name\": \"v9.9.9\"," > "$out" ;;
    https://raw.githubusercontent.com/*) cp "'"$SANDBOX"'/upstream/${url##*/}" "$out" 2>/dev/null || exit 22 ;;
    *) exit 22 ;;
esac'
schema="$SANDBOX/upstream/settings.ts"
: > "$schema"
: > "$SANDBOX/upstream/project.ts"
check() {
    : > "$STUB_LOG"
    assert_exit "$1" "$BASH" "$REPO_DIR/scripts/check-t3-settings.sh" "${@:2}"
}

# Empty schemas lack every key, and the made-up one isn't reported
check 1
assert_contains "$RUN_OUTPUT" "T3 Code v9.9.9"
assert_file_contains "$STUB_LOG" "https://api.github.com/repos/pingdotgg/t3code/releases/latest"
assert_file_contains "$STUB_LOG" "https://raw.githubusercontent.com/pingdotgg/t3code/v9.9.9/packages/contracts/src/settings.ts"
assert_not_contains "$RUN_OUTPUT" "dotfilesNoSuchT3Setting"
assert_not_contains "$RUN_OUTPUT" "made-up key"
keys="$(sed -nE 's/.*keys the t3-code step writes:(.*)$/\1/p' <<< "$RUN_OUTPUT")"
for what in server client; do
    assert_contains "$RUN_OUTPUT" "schema lacks these $what settings keys" "the report of $what keys"
done

# A schema with every key passes
for key in $keys; do
    echo "  $key: Schema.String,"
done | sort -u > "$schema"
check 0
assert_contains "$RUN_OUTPUT" "server settings: every key is in the schema"
assert_contains "$RUN_OUTPUT" "client settings: every key is in the schema"
assert_contains "$RUN_OUTPUT" "All checks passed"
assert_not_contains "$RUN_OUTPUT" "WARNING"

# A key whose default, a constant here, is the value the step writes, warns without failing
assignment="$(
    source "$REPO_DIR/ai_tools/t3-code/install.sh"
    t3_code_server_filter | grep -oE '\.[a-zA-Z_][a-zA-Z0-9_]* = "[^"]*"' | head -n 1
)"
key="${assignment%% *}"
key="${key#.}"
value="${assignment#* = }"
[ -n "$key" ] || fail "couldn't read a value the t3-code step writes"
sed -i.bak "s/^  $key: .*/  $key: Schema.String.pipe(Schema.withDecodingDefault(Effect.succeed(DEFAULT_SETTING))),/" "$schema"
echo "export const DEFAULT_SETTING = $value;" >> "$schema"
check 0
assert_contains "$RUN_OUTPUT" "WARNING: the t3-code step writes server settings $key = $value, T3 Code v9.9.9's default"
assert_contains "$RUN_OUTPUT" "All checks passed, with"
mv "$schema.bak" "$schema"

# A schema in which the search finds a made-up key can't check the real ones
echo "  dotfilesNoSuchT3Setting: Schema.String," >> "$schema"
check 1
assert_contains "$RUN_OUTPUT" "found a made-up key"
sed -i.bak '/dotfilesNoSuchT3Setting/d' "$schema"

# A tag given is used without asking for the latest, and a schema missing at it fails
rm "$SANDBOX/upstream/project.ts"
check 1 v1.2.3
assert_file_not_contains "$STUB_LOG" "releases/latest"
assert_contains "$RUN_OUTPUT" "Couldn't download packages/contracts/src/project.ts at v1.2.3"

check 2 v1 v2
assert_contains "$RUN_OUTPUT" "usage: check-t3-settings.sh"

test_done
