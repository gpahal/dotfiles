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

status() {
    status_check "Solaar" apt_installed solaar
    status_result
}

apply() {
    echo "Setting up Logitech devices..."
    if apt_installed solaar; then
        echo "  Solaar is already installed."
        return 0
    fi
    confirm_sudo_changes "Install Solaar from Ubuntu's universe" || return 0
    # Stale lists can name a version the mirror no longer has
    apt_get_update || return 1
    apt_get install -y solaar || return 1
    # It installs udev rules that give your desktop session access to Logitech receivers
    echo "  Applied. Solaar starts with your desktop session. Reconnect a receiver to see it there."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
