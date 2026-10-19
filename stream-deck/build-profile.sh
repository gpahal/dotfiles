#!/bin/bash
set -euo pipefail

# Zip stream-deck/profile into the plugin's System.streamDeckProfile; commit both after editing.
# Stream Deck keeps its own copy, so delete the installed System profile to pick up changes.

DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$DIR/com.gpahal.dotfiles.sdPlugin/profiles/System.streamDeckProfile}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# profile/. works with both BSD and GNU cp
cp -R "$DIR/profile/." "$tmp/"
for page in "$tmp"/*.sdProfile/Profiles/*/; do
    mkdir -p "$page/Images"
done
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# Reproducible bytes: fixed modes and UTC times, sorted entries, -X, and -0 since zlib builds
# deflate differently
chmod -R u=rwX,go=rX "$tmp"
find "$tmp" -exec env TZ=UTC touch -t 202001010000 {} +
(cd "$tmp" && find -- *.sdProfile | LC_ALL=C sort | TZ=UTC zip -q -X -0 "$OUT" -@)
echo "Built $OUT"
