#!/bin/bash
set -euo pipefail

# Write the "### macOS" and "### Ubuntu" lists under "## Manual steps" in README.md, every manual
# step, as manual-steps/steps.sh declares them, and in ai_tools/README.md, only the AI tools' from
# ai_tools/manual-steps/steps.sh. --check changes nothing, and fails when a README differs, as just
# check runs it.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/manual.sh
source "$DOTFILES_DIR/lib/manual.sh"

# "<README>|<steps file>|<function that declares its steps>"
DOCS=("README.md|manual-steps/steps.sh|manual_steps"
    "ai_tools/README.md|ai_tools/manual-steps/steps.sh|ai_manual_steps")

usage() {
    echo "Usage: bash scripts/manual-steps-doc.sh [--check] (or: just manual-steps-doc)"
    echo "Write the READMEs' Manual steps lists from manual-steps/steps.sh and ai_tools/manual-steps/steps.sh."
    echo "--check changes nothing, and fails when a README's lists differ from them."
}

# readme_with_steps <README> <steps file> <function>: the README, with its OS lists from the steps
readme_with_steps() {
    local doc="$DOTFILES_DIR/$1" dir
    dir="$(mktemp -d)" || return 1
    (
        # shellcheck disable=SC1090 # a steps file
        source "$DOTFILES_DIR/$2"
        manual_reset
        "$3"
        MANUAL_DONE=" "
        manual_markdown macos "$doc" > "$dir/macos"
        manual_markdown ubuntu "$doc" > "$dir/ubuntu"
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
        { print }' "$doc"
    rm -rf "$dir"
}

main() {
    local check=false entry readme file fn doc tmp status=0
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
    for entry in "${DOCS[@]}"; do
        IFS='|' read -r readme file fn <<< "$entry"
        doc="$DOTFILES_DIR/$readme"
        tmp="$(mktemp)"
        if ! readme_with_steps "$readme" "$file" "$fn" > "$tmp"; then
            echo "Couldn't build $readme's Manual steps from $file." >&2
            rm -f "$tmp"
            status=1
            continue
        fi
        if cmp -s "$tmp" "$doc"; then
            rm -f "$tmp"
            "$check" || echo "$readme: Manual steps already match $file"
        elif "$check"; then
            echo "$readme's Manual steps differ from $file. Run just manual-steps-doc:" >&2
            diff "$doc" "$tmp" >&2 || true
            rm -f "$tmp"
            status=1
        else
            write_back "$tmp" "$doc" || status=1
            echo "$readme: wrote Manual steps from $file"
        fi
    done
    return "$status"
}

main "$@"
