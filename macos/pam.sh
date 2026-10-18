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
# Where the check of the copy's parent dirs stops; tests, whose sandbox sits under dirs root and
# they own, change it
PAM_TRUSTED_DIR=/

# Where Homebrew links pam-reattach's module, the copy's source. Without HOMEBREW_PREFIX, as in a
# shell that didn't read Homebrew's shellenv, it's Apple Silicon's prefix.
REATTACH_SOURCE="${HOMEBREW_PREFIX:-/opt/homebrew}/lib/pam/pam_reattach.so"

reattach_source_installed() {
    [ -f "$REATTACH_SOURCE" ]
}

# Succeeds when $PAM_ROOT_UID owns $1 and neither its group nor others can write it
pam_owner_safe() {
    local perms owner
    read -r perms _ owner _ < <(/bin/ls -ldn "$1" 2>/dev/null) || return 1
    [ "$owner" == "$PAM_ROOT_UID" ] && [ "${perms:5:1}" != w ] && [ "${perms:8:1}" != w ]
}

# Succeeds when an ACL entry on $1 lets someone write, add to, delete, or take over it. ls -le
# prints each entry on its own numbered line, such as " 0: group:everyone allow add_file,delete_child".
pam_acl_writable() {
    /bin/ls -lde "$1" 2>/dev/null | awk '
        NR > 1 && $1 ~ /^[0-9]+:$/ {
            for (i = 2; i < NF; i++) {
                if ($i != "allow") continue
                n = split($(i + 1), perms, ",")
                for (j = 1; j <= n; j++)
                    if (perms[j] ~ /^(write|append|add_file|add_subdirectory|delete|delete_child|writeattr|writeextattr|writesecurity|chown)$/)
                        found = 1
            }
        }
        END { exit !found }'
}

# pam_path_safe <path>: succeed when <path> and each parent up to $PAM_TRUSTED_DIR is root's alone
# to change, so nothing running as you can swap the module sudo loads as root. Otherwise print the
# first problem and its fix, and fail. A missing one is fine, since install -d and install create
# it root's. A symlink fails, since its own owner says nothing about where it points.
pam_path_safe() {
    local path="$1"
    while :; do
        if [ -L "$path" ]; then
            echo "$path is a symlink; remove it with sudo rm $path"
            return 1
        elif [ -e "$path" ] && ! pam_owner_safe "$path"; then
            echo "$path isn't root's alone to write; run sudo chown root $path && sudo chmod go-w $path"
            return 1
        elif [ -e "$path" ] && pam_acl_writable "$path"; then
            echo "$path has an ACL entry that lets others write it; remove it with sudo chmod -N $path"
            return 1
        fi
        if [ "$path" == "$PAM_TRUSTED_DIR" ] || [ "$path" == / ]; then
            return 0
        fi
        path="$(dirname "$path")"
    done
}

# Succeeds when OpenPAM would load pam_reattach.so.2, which it tries before the copy
reattach_shadowed() {
    [ -e "$REATTACH_MODULE.2" ] || [ -L "$REATTACH_MODULE.2" ]
}

# What just touch-id fixes by installing the copy again: a link in its place, or an owner or mode
# that lets others write it
reattach_module_replaceable() {
    [ -L "$REATTACH_MODULE" ] || { [ -e "$REATTACH_MODULE" ] && ! pam_owner_safe "$REATTACH_MODULE"; }
}

# Succeeds when the copy needs installing: Homebrew's module exists, and the copy is missing,
# differs from it, or is replaceable
reattach_copy_needed() {
    reattach_source_installed || return 1
    [ ! -f "$REATTACH_MODULE" ] || reattach_module_replaceable || ! cmp -s "$REATTACH_SOURCE" "$REATTACH_MODULE"
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
    local off="$1" module fix reason
    if [ -e "$SUDO_LOCAL" ] && [ ! -r "$SUDO_LOCAL" ]; then
        status_item unverified "Touch ID for sudo: $SUDO_LOCAL isn't readable; check it with sudo cat $SUDO_LOCAL"
        return 0
    fi
    if ! has_tid; then
        status_item "$off" "Touch ID for sudo: off, an option that just touch-id turns on"
    elif [ "$(cat "$SUDO_LOCAL")" == "$(desired_sudo_local)" ]; then
        status_item ok "Touch ID for sudo, in $SUDO_LOCAL"
        if [ -e "$REATTACH_MODULE" ] || [ -L "$REATTACH_MODULE" ]; then
            # just touch-id reinstalls the copy from Homebrew's, so it refuses without that
            fix="re-run just touch-id"
            reattach_source_installed || fix="run brew install pam-reattach, then just touch-id"
            if reattach_shadowed; then
                status_item missing "Touch ID in tmux: $REATTACH_MODULE.2 exists, and OpenPAM loads it instead of the copy; remove it with sudo rm $REATTACH_MODULE.2, then re-run just touch-id"
            elif ! reason="$(pam_path_safe "$PAM_LOCAL_MODULES_DIR")"; then
                status_item missing "Touch ID in tmux: sudo can't safely load $REATTACH_MODULE: $reason"
            elif [ -L "$REATTACH_MODULE" ]; then
                status_item missing "Touch ID in tmux: $REATTACH_MODULE, which sudo loads, is a symlink; $fix"
            elif ! pam_owner_safe "$REATTACH_MODULE"; then
                status_item missing "Touch ID in tmux: $REATTACH_MODULE, which sudo loads, isn't root's alone to write; $fix"
            elif ! reason="$(pam_path_safe "$REATTACH_MODULE")"; then
                status_item missing "Touch ID in tmux: sudo can't safely load $REATTACH_MODULE: $reason"
            elif reattach_source_installed && ! cmp -s "$REATTACH_SOURCE" "$REATTACH_MODULE"; then
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
