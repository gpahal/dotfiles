# The sudo PAM config Touch ID for sudo wants, and the read-only status check of it that both
# macos/setup-touch-id-sudo.sh and the macos step's status run. Source it; don't run it.
# DOTFILES_PAM_DIR replaces /etc/pam.d, DOTFILES_PAM_MODULES_DIR /usr/lib/pam, and
# DOTFILES_PAM_LOCAL_MODULES_DIR /usr/local/lib/pam, for tests.
# shellcheck shell=bash

PAM_DIR="${DOTFILES_PAM_DIR:-/etc/pam.d}"
# Where OpenPAM looks for a module given by bare name, in order
PAM_MODULES_DIR="${DOTFILES_PAM_MODULES_DIR:-/usr/lib/pam}"
PAM_LOCAL_MODULES_DIR="${DOTFILES_PAM_LOCAL_MODULES_DIR:-/usr/local/lib/pam}"
SUDO_LOCAL="$PAM_DIR/sudo_local"
# Spaced like the lines in macOS's sudo_local.template
SUDO_LOCAL_HEADER="# sudo_local: local config file which survives system update and is included for sudo"
TID_LINE="auth       sufficient     pam_tid.so"

# /etc/pam.d/sudo reads sudo_local only on macOS 14 and later
sudo_reads_sudo_local() {
    grep -qE '^[[:space:]]*auth[[:space:]]+include[[:space:]]+sudo_local([[:space:]]|$)' "$PAM_DIR/sudo" 2>/dev/null
}

# Print where pam-reattach's module is once it's installed: Homebrew links it under its prefix.
# Prints nothing without Homebrew.
reattach_module() {
    local prefix
    command -v brew &>/dev/null || return 0
    prefix="$(brew --prefix 2>/dev/null)" || return 0
    echo "$prefix/lib/pam/pam_reattach.so"
}

reattach_installed() {
    local module
    module="$(reattach_module)"
    [ -n "$module" ] && [ -f "$module" ]
}

# Print sudo_local as it should be, whatever it holds now: the template's header, then, when
# pam-reattach is installed, its module with ignore_ssh, so sudo over SSH asks for the password
# rather than showing a Touch ID prompt on the Mac's screen, then pam_tid. pam_reattach must come
# first for Touch ID to work inside tmux.
desired_sudo_local() {
    echo "$SUDO_LOCAL_HEADER"
    if reattach_installed; then
        echo "auth       optional       $(reattach_module) ignore_ssh"
    fi
    echo "$TID_LINE"
}

# Succeeds when an active line loads pam_tid
has_tid() {
    [ -f "$SUDO_LOCAL" ] && awk '$1 == "auth" && $3 ~ /(^|\/)pam_tid\.so$/ { found = 1 } END { exit !found }' "$SUDO_LOCAL"
}

# Print the absolute path of a module as sudo_local names it. A bare name such as pam_tid.so comes
# out under the first search dir that has it, or under /usr/lib/pam when none does.
pam_module_path() {
    local dir
    if [[ "$1" == /* ]]; then
        echo "$1"
        return
    fi
    for dir in "$PAM_MODULES_DIR" "$PAM_LOCAL_MODULES_DIR"; do
        if pam_module_exists "$dir/$1"; then
            echo "$dir/$1"
            return
        fi
    done
    echo "$PAM_MODULES_DIR/$1"
}

# The absolute paths of the modules sudo_local's active lines load, in file order (pam_module_path)
sudo_local_modules() {
    local module
    [ -f "$SUDO_LOCAL" ] || return 0
    awk '$1 !~ /^#/ && NF >= 3 && $2 != "include" { print $3 }' "$SUDO_LOCAL" |
        while IFS= read -r module; do
            pam_module_path "$module"
        done
}

# Succeeds when a module pam_module_path prints exists. OpenPAM also tries the name with its
# major version, .2, which is how macOS ships its own, e.g. /usr/lib/pam/pam_tid.so.2.
pam_module_exists() {
    [ -f "$1" ] || [ -f "$1.2" ]
}

# status_touch_id <state>: report Touch ID for sudo, with <state> (missing or skipped) for off.
# Touch ID is optional in the macos step, which skips it when off. Every module sudo_local loads
# must exist: pam-reattach can be uninstalled under it, and then sudo may fail, depending on the
# stack.
status_touch_id() {
    local off="$1" module
    if [ -e "$PAM_DIR/sudo" ] && [ ! -r "$PAM_DIR/sudo" ]; then
        status_item unverified "Touch ID for sudo: $PAM_DIR/sudo isn't readable, so whether sudo reads $SUDO_LOCAL is unknown; check it with sudo cat $PAM_DIR/sudo"
        return 0
    fi
    if ! sudo_reads_sudo_local; then
        status_item "$off" "Touch ID for sudo: $PAM_DIR/sudo doesn't include sudo_local, which macOS 14 added"
        return 0
    fi
    if [ -e "$SUDO_LOCAL" ] && [ ! -r "$SUDO_LOCAL" ]; then
        status_item unverified "Touch ID for sudo: $SUDO_LOCAL isn't readable; check it with sudo cat $SUDO_LOCAL"
        return 0
    fi
    if ! has_tid; then
        status_item "$off" "Touch ID for sudo: off, an option that just touch-id turns on"
    elif [ "$(cat "$SUDO_LOCAL")" == "$(desired_sudo_local)" ]; then
        status_item ok "Touch ID for sudo, in $SUDO_LOCAL"
        reattach_installed ||
            status_item skipped "Touch ID in tmux: pam-reattach isn't installed; the homebrew step installs it, then re-run just touch-id"
    else
        status_item missing "Touch ID for sudo: $SUDO_LOCAL differs from what just touch-id writes; run it to rewrite the file"
    fi
    while IFS= read -r module; do
        pam_module_exists "$module" && continue
        if [[ "$module" == */pam_reattach.so ]]; then
            status_item missing "$SUDO_LOCAL loads $module, which doesn't exist, so Touch ID in tmux doesn't work and sudo may fail; re-run the homebrew step to put pam-reattach back, or just touch-id to drop the line"
        else
            status_item missing "$SUDO_LOCAL loads $module, which doesn't exist, so sudo may fail; just touch-id rewrites the file without it"
        fi
    done < <(sudo_local_modules)
}
