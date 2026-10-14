#!/bin/bash
set -euo pipefail

# Send a desktop notification through the terminal (OSC 9) in terminals that support it
# (Ghostty, iTerm2, kitty, WezTerm, Warp). Works inside tmux too.

MESSAGE="${1:-Hello from ${TERM_PROGRAM:-your terminal}}"

if [ -n "${TMUX:-}" ]; then
    # tmux only forwards the sequence when wrapped in DCS passthrough. This pane is visible, so
    # on works here, but drops notifications from panes you can't see.
    case "$(tmux show-options -gv allow-passthrough 2>/dev/null)" in
        off)
            echo "tmux allow-passthrough is off. Add 'set -g allow-passthrough all' to tmux.conf." >&2
            exit 1
            ;;
        on)
            echo "tmux allow-passthrough is on, which drops notifications from panes you can't see. Set it to all in tmux.conf." >&2
            ;;
    esac
    # shellcheck disable=SC1003 # the trailing backslash is part of the escape sequence
    printf '\ePtmux;\e\e]9;%s\a\e\\' "$MESSAGE"
else
    printf '\e]9;%s\a' "$MESSAGE"
fi

echo "Sent. If nothing appeared, check notification permissions for your terminal app on the computer displaying it."
