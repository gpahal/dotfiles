# shellcheck shell=bash

# user_instructions_to <dest> <action> [arg...]: runs <action> <repo file> <dest> [arg...].
user_instructions_to() {
    local dest="$1" action="$2"
    shift 2
    "$action" "$DOTFILES_DIR/ai_tools/user-instructions.md" "$dest" "$@"
}

install_user_instructions() {
    echo "  User-level instructions:"
    user_instructions_to "$1" copy_file
}
