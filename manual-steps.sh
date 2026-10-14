#!/bin/bash
set -euo pipefail

# Print the setup steps scripts can't do on this OS. The list is the README's Manual steps
# section, read at run time, so it has one copy.

# shellcheck source=lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

main() {
    step_args "$@"
    # Nothing to check: the list is what scripts can't do
    ! status_requested "$@" || return 0
    local os=Ubuntu
    is_macos && os=macOS
    echo ""
    echo "Remaining manual steps on $os (README.md → Manual steps):"
    print_doc_section "$DOTFILES_DIR/README.md" "## Manual steps" "### $os"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
