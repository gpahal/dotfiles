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
OUT="$DIR/com.gpahal.dotfiles.sdPlugin/profiles/System.streamDeckProfile"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R "$DIR/profile/" "$tmp/"
for page in "$tmp"/*.sdProfile/Profiles/*/; do
    mkdir -p "$page/Images"
done
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$tmp" && zip -q -r -X "$OUT" -- *.sdProfile)
echo "Built $OUT"
