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

# Where sudo_local loads pam-reattach's module from: a copy in a root-owned dir that just
# touch-id installs, since sudo runs it as root and anything running as you can write Homebrew's
# copy. It also keeps sudo working after pam-reattach is uninstalled.
REATTACH_MODULE="$PAM_LOCAL_MODULES_DIR/pam_reattach.so"
# The owner the copy and its dir must have; tests, whose sandbox files are theirs, change it
PAM_ROOT_UID=0

# Print where Homebrew links pam-reattach's module, the copy's source. Prints nothing without
# Homebrew.
reattach_source() {
    local prefix
    command -v brew &>/dev/null || return 0
    prefix="$(brew --prefix 2>/dev/null)" || return 0
    echo "$prefix/lib/pam/pam_reattach.so"
}

reattach_source_installed() {
    local source
    source="$(reattach_source)"
    [ -n "$source" ] && [ -f "$source" ]
}

# Succeeds when $PAM_ROOT_UID owns $1 and neither its group nor others can write it
root_only_writable() {
    local perms owner
    read -r perms _ owner _ < <(/bin/ls -ldn "$1" 2>/dev/null) || return 1
    [ "$owner" == "$PAM_ROOT_UID" ] && [ "${perms:5:1}" != w ] && [ "${perms:8:1}" != w ]
}

# Succeeds when the copy and its dir are root's alone to write
reattach_module_safe() {
    root_only_writable "$PAM_LOCAL_MODULES_DIR" && root_only_writable "$REATTACH_MODULE"
}

# Succeeds when the copy needs installing: Homebrew's module exists, and the copy is missing,
# differs from it, or isn't root's alone to write
reattach_copy_needed() {
    local source
    reattach_source_installed || return 1
    source="$(reattach_source)"
    ! { [ -f "$REATTACH_MODULE" ] && cmp -s "$source" "$REATTACH_MODULE" && reattach_module_safe; }
}

# Print sudo_local as it should be, whatever it holds now: the template's header, then, when
# pam-reattach is installed or its copy is in place, the copy with ignore_ssh, so sudo over SSH
# asks for the password rather than showing a Touch ID prompt on the Mac's screen, then pam_tid.
# pam_reattach must come first for Touch ID to work inside tmux. just touch-id installs the copy
# before writing the file, so the line never names a missing module.
desired_sudo_local() {
    echo "$SUDO_LOCAL_HEADER"
    if [ -f "$REATTACH_MODULE" ] || reattach_source_installed; then
        echo "auth       optional       $REATTACH_MODULE ignore_ssh"
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
# must exist: one can be removed under it, and then sudo may fail, depending on the stack.
status_touch_id() {
    local off="$1" module source
    if [ -e "$SUDO_LOCAL" ] && [ ! -r "$SUDO_LOCAL" ]; then
        status_item unverified "Touch ID for sudo: $SUDO_LOCAL isn't readable; check it with sudo cat $SUDO_LOCAL"
        return 0
    fi
    if ! has_tid; then
        status_item "$off" "Touch ID for sudo: off, an option that just touch-id turns on"
    elif [ "$(cat "$SUDO_LOCAL")" == "$(desired_sudo_local)" ]; then
        status_item ok "Touch ID for sudo, in $SUDO_LOCAL"
        source="$(reattach_source)"
        if [ -f "$REATTACH_MODULE" ]; then
            if ! root_only_writable "$PAM_LOCAL_MODULES_DIR"; then
                status_item missing "Touch ID in tmux: $PAM_LOCAL_MODULES_DIR, which sudo loads pam-reattach from, isn't root's alone to write; re-run just touch-id"
            elif ! root_only_writable "$REATTACH_MODULE"; then
                status_item missing "Touch ID in tmux: $REATTACH_MODULE, which sudo loads, isn't root's alone to write; re-run just touch-id"
            elif [ -n "$source" ] && [ -f "$source" ] && ! cmp -s "$source" "$REATTACH_MODULE"; then
                status_item missing "Touch ID in tmux: pam-reattach was upgraded; re-run just touch-id to install the new module"
            fi
        elif ! reattach_source_installed; then
            status_item skipped "Touch ID in tmux: pam-reattach isn't installed; the homebrew step installs it, then re-run just touch-id"
        fi
    else
        status_item missing "Touch ID for sudo: $SUDO_LOCAL differs from what just touch-id writes; run it to rewrite the file"
    fi
    while IFS= read -r module; do
        pam_module_exists "$module" && continue
        if [[ "$module" == */pam_reattach.so ]]; then
            status_item missing "$SUDO_LOCAL loads $module, which doesn't exist, so Touch ID in tmux doesn't work and sudo may fail; run brew install pam-reattach, then just touch-id"
        else
            status_item missing "$SUDO_LOCAL loads $module, which doesn't exist, so sudo may fail; just touch-id rewrites the file without it"
        fi
    done < <(sudo_local_modules)
}
