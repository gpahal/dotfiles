#!/bin/bash
set -euo pipefail

# Copy the lazygit config.
#
# On macOS, lazygit reads ~/Library/Application Support/lazygit, not ~/.config/lazygit, unless
# XDG_CONFIG_HOME is set (`lazygit --print-config-dir` shows which). Ubuntu uses ~/.config/lazygit.

# shellcheck source=../lib/common.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

config_path() {
    local config_home="$HOME/.config"
    is_macos && config_home="$HOME/Library/Application Support"
    echo "${XDG_CONFIG_HOME:-$config_home}/lazygit/config.yml"
}

lazygit_files() {
    "$1" "$DOTFILES_DIR/lazygit/config.yml" "$(config_path)"
}

status() { copy_status lazygit_files; }

apply() { copy_step "Copying lazygit config..." lazygit_files; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
