#!/bin/bash
set -euo pipefail

# Send a desktop notification through the terminal (OSC 9) in terminals that support it
# (Ghostty, iTerm2, kitty, WezTerm, Warp). Works inside tmux too.

MESSAGE="${1:-Hello from ${TERM_PROGRAM:-your terminal}}"

if [ -n "${TMUX:-}" ]; then
    # tmux only forwards the sequence when wrapped in DCS passthrough (needs allow-passthrough on)
    if [ "$(tmux show-options -gv allow-passthrough 2>/dev/null)" = "off" ]; then
        echo "tmux allow-passthrough is off. Add 'set -g allow-passthrough on' to tmux.conf." >&2
        exit 1
    fi
    # shellcheck disable=SC1003 # the trailing backslash is part of the escape sequence
    printf '\ePtmux;\e\e]9;%s\a\e\\' "$MESSAGE"
else
    printf '\e]9;%s\a' "$MESSAGE"
fi

echo "Sent. If nothing appeared, check System Settings → Notifications → your terminal app."
