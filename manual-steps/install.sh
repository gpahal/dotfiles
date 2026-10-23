#!/bin/bash
set -euo pipefail

# Print the setup steps scripts can't do on this OS.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../scripts/lib/markdown.sh
source "$DOTFILES_DIR/scripts/lib/markdown.sh"

status() { return 0; }

apply() {
    local os=Ubuntu
    is_macos && os=macOS
    echo ""
    echo "Remaining manual steps on $os (README.md → Manual steps):"
    print_doc_section "$DOTFILES_DIR/README.md" "## Manual steps" "### $os"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
