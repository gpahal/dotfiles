# shellcheck shell=bash
# The Mac's Stream Deck profiles, one per page of the plugin's layout.json. build-profile.sh
# generates them; the stream-deck step checks the copies Stream Deck installs in ProfilesV3 and
# deletes the stale ones, and every other profile for the deck, while Stream Deck is quit. Needs jq.

DECK_SRC="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECK_LAYOUT="$DECK_SRC/com.gpahal.dotfiles.sdPlugin/layout.json"
# shellcheck disable=SC2034 # build-profile.sh reads it
DECK_MANIFEST="$DECK_SRC/com.gpahal.dotfiles.sdPlugin/manifest.json"
DECK_PLUGIN_UUID=com.gpahal.dotfiles
# The Stream Deck MK.2's model code, as Stream Deck writes it in a profile
DECK_MODEL=20GBA9901
PROFILES_DIR="$HOME/Library/Application Support/com.elgato.StreamDeck/ProfilesV3"
# Separates fields: a tab would merge empty ones under read
SEP=$'\x1f'

layout_pages() {
    jq -r '.pages | keys_unsorted[]' "$DECK_LAYOUT"
}

# main -> Main, the profile's name and file name
profile_title() {
    printf '%s%s\n' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

# A UUID that's the same on every build: SHA-1 of the name, shaped as a version 5 UUID
profile_uuid() {
    local hex
    if command -v sha1sum &> /dev/null; then
        hex="$(printf '%s/%s' "$DECK_PLUGIN_UUID" "$1" | sha1sum)"
    else
        hex="$(printf '%s/%s' "$DECK_PLUGIN_UUID" "$1" | shasum -a 1)"
    fi
    printf '%s-%s-5%s-%x%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" $(((0x${hex:16:1} & 0x3) | 0x8)) \
        "${hex:17:3}" "${hex:20:12}"
}

# A profile's keys as "<page index>:<column>,<row> <action UUID>" lines, so a profile Stream Deck
# installed compares with layout.json whatever fields it adds
layout_keys() {
    jq -r --arg page "$1" --arg plugin "$DECK_PLUGIN_UUID" \
        '.pages[$page] // {} | to_entries[] | "0:\(.key) \($plugin).\(.value)"' "$DECK_LAYOUT" | LC_ALL=C sort
}

# Page folders are named by page UUID, in either case
profile_keys() (
    local dir="$1" page folder i=0
    shopt -s nocasematch
    while IFS= read -r page; do
        for folder in "$dir"/Profiles/*/; do
            folder="${folder%/}"
            [[ "${folder##*/}" == "$page" ]] || continue
            jq -r --arg i "$i" '.Controllers[]? | select(.Type == "Keypad") | .Actions // {} | to_entries[] |
                "\($i):\(.key) \(.value.UUID)"' "$folder/manifest.json" 2> /dev/null
        done
        i=$((i + 1))
    done < <(jq -r '.Pages.Pages[]?' "$dir/manifest.json" 2> /dev/null) | LC_ALL=C sort
)

# "<page> <name> <dir>", split by SEP, for each profile in ProfilesV3 that the plugin installed,
# with the page its name points to, else with no page for any other profile for the deck's model.
# A folder that isn't a real *.sdProfile directory, or whose manifest doesn't parse, is left out.
installed_profiles() {
    local dir
    for dir in "$PROFILES_DIR"/*.sdProfile; do
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        jq -r --arg plugin "$DECK_PLUGIN_UUID" --arg model "$DECK_MODEL" --arg dir "$dir" --arg sep "$SEP" '
            if .InstalledByPluginUUID == $plugin and ((.PreconfiguredName // "") | startswith("profiles/")) then
                [(.PreconfiguredName | ltrimstr("profiles/") | ascii_downcase), .Name // "", $dir]
            elif .Device.Model == $model then ["", .Name // "", $dir]
            else empty end | join($sep)' "$dir/manifest.json" 2> /dev/null
    done
}

# What to do with each profile, as "<state> <dir> <text>" lines split by SEP, the state being:
# - ok, or missing (no dir), for each page's profile;
# - reinstall, for a copy of the plugin's that's stale: the plugin's archive changed (the pages
#   named as arguments), its keys differ from layout.json, or there are two copies;
# - delete, for any other profile for the deck;
# - wait, for one that deleting would only have Stream Deck replace with its default profile,
#   since the Main profile isn't installed yet.
profile_plan() {
    local list page title dirs dir name count main_ok=false
    list="$(installed_profiles)"
    for page in $(layout_pages); do
        title="$(profile_title "$page")"
        dirs="$(printf '%s\n' "$list" | awk -F "$SEP" -v p="$page" '$1 == p { print $3 }')"
        count="$(printf '%s' "$dirs" | grep -c '^' || true)"
        if [ "$count" -eq 0 ] && [ "$page" == main ]; then
            plan_line missing "" "Stream Deck's $title profile: Stream Deck installs it when it loads the plugin; accept its prompt"
        elif [ "$count" -eq 0 ]; then
            plan_line missing "" "Stream Deck's $title profile: press the key that opens it, and accept Stream Deck's prompt"
        elif [ "$count" -gt 1 ]; then
            while IFS= read -r dir; do
                plan_line reinstall "$dir" "$count copies of Stream Deck's $title profile: the next run reinstalls it"
            done <<< "$dirs"
        elif printf ' %s ' "$*" | grep -qF " $page "; then
            plan_line reinstall "$dirs" "the plugin's $title profile changed"
        elif [ "$(profile_keys "$dirs")" != "$(layout_keys "$page")" ]; then
            plan_line reinstall "$dirs" "Stream Deck's $title profile differs from layout.json: the next run reinstalls it"
        else
            plan_line ok "$dirs" "Stream Deck's $title profile"
            [ "$page" != main ] || main_ok=true
        fi
    done
    while IFS="$SEP" read -r page name dir; do
        [ -n "$dir" ] || continue
        # The plugin's profile for a page layout.json no longer has is extra too
        [ -z "$page" ] || ! layout_pages | grep -qxF "$page" || continue
        count="$(profile_keys "$dir" | grep -c '^' || true)"
        if [ "$count" -eq 1 ]; then count="1 key"; else count="$count keys"; fi
        if "$main_ok"; then
            plan_line delete "$dir" "extra Stream Deck profile $name ($count): the next run deletes it"
        else
            plan_line wait "$dir" "extra Stream Deck profile $name ($count): deleted once the Main profile is installed"
        fi
    done <<< "$list"
}

plan_line() {
    printf '%s%s%s%s%s\n' "$1" "$SEP" "$2" "$SEP" "$3"
}

# Only a real directory named *.sdProfile directly in ProfilesV3
delete_profile() {
    local dir="$1" name="${1##*/}"
    if [ "$dir" != "$PROFILES_DIR/$name" ] || [[ "$name" != *.sdProfile ]] || [ ! -d "$dir" ] || [ -L "$dir" ]; then
        echo "  Not deleting $dir: it isn't a profile folder in $PROFILES_DIR" >&2
        return 1
    fi
    rm -rf -- "$dir"
}
