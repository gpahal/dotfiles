#!/bin/bash
set -euo pipefail

# Install Solaar for Logitech devices, since Logi Options+ has no Linux version.
# Installs a package with sudo whatever HOME is: test it in an Ubuntu VM.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

STEP_OS=ubuntu

solaar_installed() {
    apt_installed solaar
}

install_solaar() {
    # Stale lists can name a version the mirror no longer has
    apt_get_update || return 1
    apt_get install -y solaar || return 1
    echo "  Applied. Solaar starts with your desktop session. Reconnect a receiver to see it there."
}

logitech_items() {
    items_reset
    item --sudo "Solaar" "Install Solaar from Ubuntu's universe" solaar_installed install_solaar
}

status() {
    logitech_items
    items_status solaar_installed
    status_result
}

apply() {
    echo "Setting up Logitech devices..."
    local pending=()
    logitech_items
    items_pending solaar_installed
    if [ ${#pending[@]} -eq 0 ]; then
        echo "  Solaar is already installed."
        return 0
    fi
    confirm_sudo_changes "${pending[@]}" || return 0
    items_apply solaar_installed
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
