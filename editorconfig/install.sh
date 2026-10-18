#!/bin/bash
set -euo pipefail

# Copy the home-wide EditorConfig, which every project under $HOME picks up unless its own
# .editorconfig sets root = true.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Pass the file the step copies, as source and destination, to a function: copy_file to copy it,
# or status_file to report it
editorconfig_files() {
    "$1" "$DOTFILES_DIR/editorconfig/editorconfig" "$HOME/.editorconfig"
}

status() { copy_status editorconfig_files; }

apply() { copy_step "Copying EditorConfig..." editorconfig_files; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
