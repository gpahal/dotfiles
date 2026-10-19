#!/bin/bash
set -euo pipefail

# Install Solaar on Ubuntu to pair and configure Logitech mice and keyboards, since Logi Options+
# has no Linux version. It comes from Ubuntu's universe, so its updates come with Ubuntu's. This
# needs sudo, so the step asks first. On macOS, the homebrew step installs Logi Options+.
#
# A temp HOME doesn't isolate this step, which installs a package with sudo. Test it in an Ubuntu
# VM.

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
    # It installs udev rules that give your desktop session access to Logitech receivers
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
