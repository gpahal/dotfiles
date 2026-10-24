#!/bin/bash
set -euo pipefail

# Write the "### macOS" and "### Ubuntu" lists under "## Manual steps" in README.md and
# ai_tools/README.md from the steps manual-steps/steps.sh and ai_tools/manual-steps/steps.sh
# declare. --check changes nothing, and fails when a README differs, as just check runs it.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/manual.sh
source "$DOTFILES_DIR/lib/manual.sh"

STEPS_FILES=(manual-steps/steps.sh ai_tools/manual-steps/steps.sh)

usage() {
    echo "Usage: bash scripts/manual-steps-doc.sh [--check] (or: just manual-steps-doc)"
    echo "Write the READMEs' Manual steps lists from ${STEPS_FILES[*]}."
    echo "--check changes nothing, and fails when a README's lists differ from them."
}

# readme_with_steps <steps file>: the steps file's README, with its OS lists from the steps
readme_with_steps() {
    local dir
    dir="$(mktemp -d)" || return 1
    (
        # shellcheck disable=SC1090 # a steps file
        source "$DOTFILES_DIR/$1"
        manual_steps
        MANUAL_DONE=" "
        manual_markdown macos > "$dir/macos"
        manual_markdown ubuntu > "$dir/ubuntu"
        echo "$MANUAL_DOC" > "$dir/doc"
    ) || {
        rm -rf "$dir"
        return 1
    }
    # Each list replaces what's under its heading, up to the next heading
    MACOS="$dir/macos" UBUNTU="$dir/ubuntu" awk '
        /^## / { manual = $0 == "## Manual steps"; skip = 0 }
        /^### / { skip = 0 }
        manual && ($0 == "### macOS" || $0 == "### Ubuntu") {
            print
            print ""
            file = $0 == "### macOS" ? ENVIRON["MACOS"] : ENVIRON["UBUNTU"]
            while ((getline line < file) > 0) print line
            close(file)
            print ""
            skip = 1
            next
        }
        skip { next }
        { print }' "$(cat "$dir/doc")"
    rm -rf "$dir"
}

steps_doc() {
    (
        # shellcheck disable=SC1090 # a steps file
        source "$DOTFILES_DIR/$1"
        echo "$MANUAL_DOC"
    )
}

main() {
    local check=false file doc tmp status=0
    case "$#:${1:-}" in
        0:) ;;
        1:--check) check=true ;;
        1:-h | 1:--help)
            usage
            return 0
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
    for file in "${STEPS_FILES[@]}"; do
        doc="$(steps_doc "$file")"
        tmp="$(mktemp)"
        if ! readme_with_steps "$file" > "$tmp"; then
            echo "Couldn't build $(shown_path "$doc")'s Manual steps from $file." >&2
            rm -f "$tmp"
            status=1
            continue
        fi
        if cmp -s "$tmp" "$doc"; then
            rm -f "$tmp"
            "$check" || echo "$(shown_path "$doc"): Manual steps already match $file"
        elif "$check"; then
            echo "$(shown_path "$doc")'s Manual steps differ from $file. Run just manual-steps-doc:" >&2
            diff "$doc" "$tmp" >&2 || true
            rm -f "$tmp"
            status=1
        else
            write_back "$tmp" "$doc" || status=1
            echo "$(shown_path "$doc"): wrote Manual steps from $file"
        fi
    done
    return "$status"
}

main "$@"
