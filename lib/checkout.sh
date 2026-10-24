# The checkout the daily health alert and the upgrade shell functions run, so neither needs the repo
# at a fixed path. The zsh and ubuntu steps record the main worktree of the checkout they run from
# in CHECKOUT_FILE. The ubuntu step copies this file beside health-alert.sh, which reads only
# CHECKOUT_FILE and recorded_checkout; zsh/aliases.zsh reads CHECKOUT_FILE itself.
# shellcheck shell=bash

CHECKOUT_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/checkout"

# Prints the recorded checkout, which may since have moved; fails when none is recorded
recorded_checkout() {
    local dir=""
    { IFS= read -r dir < "$CHECKOUT_FILE"; } 2> /dev/null || true
    [ -n "$dir" ] || return 1
    printf '%s\n' "$dir"
}

# The main worktree of the checkout at DOTFILES_DIR, so a worktree removed later isn't recorded.
# DOTFILES_DIR itself when it isn't a git checkout or its main worktree is bare. The .git check
# stops git finding a repo above a plain dir.
main_checkout() {
    local main=""
    if [ -e "$DOTFILES_DIR/.git" ]; then
        main="$(git -C "$DOTFILES_DIR" worktree list --porcelain 2> /dev/null | awk '
            NR == 1 && sub(/^worktree /, "") { path = $0 }
            NF == 0 { exit }
            $0 == "bare" { path = "" }
            END { print path }')" || main=""
    fi
    if [ -n "$main" ] && [ -f "$main/setup.sh" ]; then
        printf '%s\n' "$main"
    else
        printf '%s\n' "$DOTFILES_DIR"
    fi
}

# status_checkout <what runs it>, such as "the daily health alert"
status_checkout() {
    local main recorded text
    main="$(main_checkout)"
    text="Checkout for $1, recorded in $(shown_path "$CHECKOUT_FILE"): $(shown_path "$main")"
    if ! recorded="$(recorded_checkout)"; then
        status_item missing "$text; none is recorded"
    elif [ "$recorded" != "$main" ]; then
        status_item missing "$text; it names $(shown_path "$recorded")"
    else
        status_item ok "$text"
    fi
}

# apply_checkout <what runs it>
apply_checkout() {
    local main recorded
    main="$(main_checkout)"
    recorded="$(recorded_checkout)" || recorded=""
    [ "$recorded" != "$main" ] || return 0
    { mkdir -p "${CHECKOUT_FILE%/*}" && printf '%s\n' "$main" > "$CHECKOUT_FILE.tmp" &&
        mv -f "$CHECKOUT_FILE.tmp" "$CHECKOUT_FILE"; } || return 1
    echo "  Recorded $(shown_path "$main") as the checkout for $1, in $(shown_path "$CHECKOUT_FILE")"
}
