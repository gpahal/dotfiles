#!/bin/bash
set -euo pipefail

# Zip stream-deck/profile into the plugin's profiles/System.streamDeckProfile, the System page
# the Overview key switches to. Run it after editing the profile, and commit both;
# tests/test-stream-deck.sh fails when the zip is out of date. Stream Deck installs the page the
# first time Overview is pressed and keeps its own copy after, so a changed page reaches Stream
# Deck only once the installed System profile is deleted in its settings.
#
# A .streamDeckProfile is a zip of the profile's .sdProfile folder, laid out as Stream Deck stores
# profiles: a manifest naming the pages, and a folder per page with its manifest and an Images
# folder.

DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An absolute path as the argument builds the zip there instead, as tests/test-stream-deck.sh does
# to compare it with the committed one
OUT="${1:-$DIR/com.gpahal.dotfiles.sdPlugin/profiles/System.streamDeckProfile}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# profile/. copies the folder's contents with both BSD and GNU cp; profile/ does only with BSD's
cp -R "$DIR/profile/." "$tmp/"
for page in "$tmp"/*.sdProfile/Profiles/*/; do
    mkdir -p "$page/Images"
done
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# The same profile always zips to the same bytes, so a rebuild with no edits leaves the zip, and
# the installed plugin, unchanged: fixed modes and times (in UTC, since zip stores local time),
# entries in sorted order, no extra attributes (-X), and stored rather than deflated (-0), since
# zlib builds can deflate the same file differently
chmod -R u=rwX,go=rX "$tmp"
find "$tmp" -exec env TZ=UTC touch -t 202001010000 {} +
(cd "$tmp" && find -- *.sdProfile | LC_ALL=C sort | TZ=UTC zip -q -X -0 "$OUT" -@)
echo "Built $OUT"
