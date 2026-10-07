#!/bin/bash
set -euo pipefail

# Install Node LTS and Go with mise, and Rust with rustup.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
    echo "Installing language runtimes via mise..."
    mise use --global node@lts go@latest

    # Rust is managed by rustup directly rather than mise, so projects' rust-toolchain.toml files
    # are respected
    if [ -x "$HOME/.cargo/bin/rustup" ] || command -v rustup &>/dev/null; then
        echo "rustup already installed."
    else
        echo "Installing rustup..."
        # --no-modify-path: zsh/basic-settings.zsh already adds ~/.cargo/bin to PATH
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
