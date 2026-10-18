# shellcheck shell=bash
# The user-level instructions the claude-code and codex steps copy, which source this file after
# lib/common.sh. It only defines functions.

# user_instructions_to <dest> <action> [arg...]
# Pass ai_tools/user-instructions.md and <dest>, where an AI tool reads its user-level
# instructions, to <action>, followed by any further arguments: copy_file_ask to copy them, or
# status_file to report them. They may hold instructions added by hand, so copy_file_ask only
# replaces them when asked. A step wraps it in a *_files function, which scripts/check-docs.sh
# finds.
# e.g. user_instructions_to "$HOME/.codex/AGENTS.md" status_file "merge by hand"
user_instructions_to() {
    local dest="$1" action="$2"
    shift 2
    "$action" "$DOTFILES_DIR/ai_tools/user-instructions.md" "$dest" "$@"
}

# Copy the user-level instructions to <dest>, asking before replacing an edited copy
install_user_instructions() {
    echo "  User-level instructions:"
    user_instructions_to "$1" copy_file_ask
}
