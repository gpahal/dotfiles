#!/bin/bash
set -euo pipefail

# Copy the home-wide EditorConfig.
#
# Every project under $HOME picks it up unless its own .editorconfig sets root = true.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

editorconfig_files() {
    "$1" "$DOTFILES_DIR/editorconfig/editorconfig" "$HOME/.editorconfig"
}

status() { copy_status editorconfig_files; }

apply() { copy_step "Copying EditorConfig..." editorconfig_files; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
