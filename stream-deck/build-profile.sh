#!/bin/bash
set -euo pipefail

# Build profiles/<Page>.streamDeckProfile in the plugin, one per page of its layout.json, with the
# actions its manifest.json names. Commit them with layout.json; the stream-deck step then replaces
# the copies Stream Deck installed. Takes another output folder, for the tests.

# shellcheck source=lib/profiles.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/profiles.sh"

OUT_DIR="${1:-$DECK_SRC/com.gpahal.dotfiles.sdPlugin/profiles}"
mkdir -p "$OUT_DIR"
# Absolute, so the Built line names the full path
OUT_DIR="$(CDPATH='' cd -- "$OUT_DIR" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

upper() {
    tr '[:lower:]' '[:upper:]'
}

# The page's keys, as Stream Deck writes them, with each ActionID fixed by page and position
page_manifest() {
    local page="$1" position ids="{}"
    for position in $(jq -r --arg page "$page" '.pages[$page] | keys_unsorted[]' "$DECK_LAYOUT"); do
        ids="$(jq -c --arg p "$position" --arg id "$(profile_uuid "action/$page/$position")" '. + {($p): $id}' <<< "$ids")"
    done
    jq --arg page "$page" --argjson ids "$ids" --slurpfile manifest "$DECK_MANIFEST" '
        $manifest[0] as $m | .pages[$page] | with_entries(.value as $action | .value = (
            (first($m.Actions[] | select(.UUID == "\($m.UUID).\($action)"))
                // error("layout.json has \($action), which manifest.json lacks")) as $a |
            {ActionID: $ids[.key], LinkedTitle: true, Name: $a.Name,
             Plugin: {Name: $m.Name, UUID: $m.UUID, Version: $m.Version}, Resources: null,
             Settings: {}, State: 0, States: [{}], UUID: $a.UUID})) |
        {Controllers: [{Actions: ., Type: "Keypad"}], Icon: "", Name: ""}' "$DECK_LAYOUT"
}

# A profile has its page, and an empty default page as Stream Deck's own profiles do
build() {
    local page="$1" title profile_id page_id default_id dir
    title="$(profile_title "$page")"
    profile_id="$(profile_uuid "profile/$page")"
    page_id="$(profile_uuid "page/$page")"
    default_id="$(profile_uuid "default-page/$page")"
    dir="$tmp/$title/$(upper <<< "$profile_id").sdProfile"
    mkdir -p "$dir/Profiles/$(upper <<< "$page_id")/Images" "$dir/Profiles/$(upper <<< "$default_id")/Images"
    jq -n --arg model "$DECK_MODEL" --arg name "$title" --arg page "$page_id" --arg default "$default_id" \
        '{Device: {Model: $model, UUID: ""}, Name: $name,
          Pages: {Current: $page, Default: $default, Pages: [$page]}, Version: "3.0"}' > "$dir/manifest.json"
    page_manifest "$page" > "$dir/Profiles/$(upper <<< "$page_id")/manifest.json"
    jq -n '{Controllers: [{Actions: null, Type: "Keypad"}], Icon: "", Name: ""}' \
        > "$dir/Profiles/$(upper <<< "$default_id")/manifest.json"
    # Reproducible bytes: fixed modes and UTC times, sorted entries, -X, and -0 since zlib builds
    # deflate differently
    chmod -R u=rwX,go=rX "$tmp/$title"
    find "$tmp/$title" -exec env TZ=UTC touch -t 202001010000 {} +
    # Zipped in $tmp, then moved, so a failed build leaves the previous profile
    (cd "$tmp/$title" && find -- *.sdProfile | LC_ALL=C sort | TZ=UTC zip -q -X -0 "$tmp/$title.zip" -@)
    mv -f "$tmp/$title.zip" "$OUT_DIR/$title.streamDeckProfile"
    echo "Built $OUT_DIR/$title.streamDeckProfile"
}

for page in $(layout_pages); do
    build "$page"
done
