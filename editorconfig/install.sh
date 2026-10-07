#!/bin/bash
set -euo pipefail

# Copy the home-wide EditorConfig, which every project under $HOME picks up unless its own
# .editorconfig sets root = true.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
    echo "Copying EditorConfig..."
    copy_file "$DOTFILES_DIR/editorconfig/editorconfig" "$HOME/.editorconfig"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
