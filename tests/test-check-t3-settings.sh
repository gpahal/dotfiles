#!/bin/bash
set -euo pipefail

# scripts/check-t3-settings.sh, with GitHub stubbed.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
unset GITHUB_TOKEN

# The latest release is v9.9.9; a raw file comes from $SANDBOX/upstream
mkdir -p "$SANDBOX/upstream"
stub curl 'out="" url="${!#}"
case " $* " in *" -H @- "*) cat >> "'"$SANDBOX"'/headers" ;; esac
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

check 1
keys="$(sed -nE 's/.*keys the t3-code step writes:(.*)$/\1/p' <<< "$RUN_OUTPUT")"
for what in server client; do
    assert_contains "$RUN_OUTPUT" "schema lacks these $what settings keys" "the report of $what keys"
done
[ -n "$keys" ] || fail "the report names no keys the t3-code step writes"

for key in $keys; do
    echo "  $key: Schema.String,"
done | sort -u > "$schema"

# The token goes to curl through stdin, not its command line, which any local user can read
GITHUB_TOKEN=test-token check 0
assert_file_not_contains "$STUB_LOG" "test-token"
assert_eq "Authorization: Bearer test-token" "$(sort -u "$SANDBOX/headers")" "the headers curl read"

# A key whose default is the value the step writes warns without failing
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
assert_contains "$RUN_OUTPUT" "WARNING: the t3-code step writes server settings $key = $value"
mv "$schema.bak" "$schema"

# A schema in which the search finds a made-up key can't check the real ones
echo "  dotfilesNoSuchT3Setting: Schema.String," >> "$schema"
check 1
assert_contains "$RUN_OUTPUT" "found a made-up key"

test_done

