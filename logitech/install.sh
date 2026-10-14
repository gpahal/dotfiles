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

status() {
    if is_macos; then
        status_item skipped "Solaar: the homebrew step installs Logi Options+ on macOS"
        return 0
    fi
    status_check "Solaar" apt_installed solaar
    status_result
}

main() {
    step_args "$@"
    if status_requested "$@"; then
        status
        return $?
    fi
    echo "Setting up Logitech devices..."
    if is_macos; then
        echo "  The homebrew step installs Logi Options+ on macOS; skipping."
        return 0
    fi
    require_supported_os || return 1

    if apt_installed solaar; then
        echo "  Solaar is already installed."
        return 0
    fi
    confirm_sudo_changes "Install Solaar from Ubuntu's universe" || return 0
    apt_get install -y solaar || return 1
    # It installs udev rules that give your desktop session access to Logitech receivers
    echo "  Applied. Solaar starts with your desktop session. Reconnect a receiver to see it there."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
