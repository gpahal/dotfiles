#!/bin/bash

# The zsh step: one source line per startup file, the recorded checkout, the login shell offer, and a
# file it can't copy. tests/test-checkout.sh covers which checkout it records.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

stub_login_shell_zsh
load_script zsh/install.sh
checkout="$(main_checkout)"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Checkout for upgrade and upgrade-ai-tools, recorded in ~/.local/state/dotfiles/checkout: $checkout; none is recorded"
replace_fn current_login_shell 'echo /bin/zsh'
replace_fn login_zsh_path 'echo /bin/zsh'

# Each startup file gets one line, after other installers' lines
# shellcheck disable=SC2329
macos_profile() {
    as_os macos
    assert_exit 0 apply
    [ ! -e "$HOME/.zsh/profile.sh" ] || fail "apply copied profile.sh on macOS"
    assert_file_contains "$HOME/.zprofile" "$PATH_ZSH_LINE"
}
subtest macos_profile
as_os ubuntu
stock='if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
PATH="$HOME/.local/bin:$PATH"'
printf '%s\n' "# mine" > "$HOME/.zshrc"
printf '%s\n' "# mine" > "$HOME/.zprofile"
printf '%s\n' "$stock" > "$HOME/.profile"
startup_files() {
    local file
    for file in .zshrc .zprofile .zshenv .profile; do
        printf '== %s\n' "$file"
        cat "$HOME/$file"
    done
}
assert_exit 0 apply
# On Ubuntu, ~/.zshenv sources path.zsh; ~/.zprofile is macOS only.
expected="$(printf '%s\n' "== .zshrc" "# mine" "$ZSHRC_LINE" "== .zprofile" "# mine" \
    "== .zshenv" "$PATH_ZSH_LINE" "== .profile" "$stock" "$PROFILE_LINE")"
assert_eq "$expected" "$(startup_files)" "the startup files"
assert_exit 0 apply
assert_not_contains "$RUN_OUTPUT" "Added"
assert_eq "$expected" "$(startup_files)" "the startup files after a second run"
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "ok         profile.sh sourced in ~/.profile"
assert_contains "$RUN_OUTPUT" "ok         path.zsh sourced in ~/.zshenv"
assert_contains "$RUN_OUTPUT" "skipped    path.zsh sourced in ~/.zprofile: macOS only"
assert_contains "$RUN_OUTPUT" "ok         Checkout for upgrade and upgrade-ai-tools, recorded in ~/.local/state/dotfiles/checkout: $checkout"

# A declined login shell change doesn't fail the step
stub_sudo_cacheable
stub chsh
replace_fn current_login_shell 'echo /bin/bash'
replace_fn login_zsh_path 'echo "$SANDBOX/bin/zsh"'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Login shell left as /bin/bash"
assert_file_not_contains "$STUB_LOG" "chsh"

: > "$STUB_LOG"
answer yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "chsh -s $SANDBOX/bin/zsh"
assert_file_not_contains "$STUB_LOG" "sudo -n chsh"

# Root's chsh, with sudo cached, doesn't ask for a password
: > "$STUB_LOG"
cache_sudo yes
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo -n chsh -s $SANDBOX/bin/zsh $(id -un)"

stub chsh 'exit 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run manually: chsh -s $SANDBOX/bin/zsh"
cache_sudo no
stub chsh

replace_fn current_login_shell 'echo /bin/zsh'
replace_fn login_zsh_path 'echo /bin/zsh'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "zsh is already the login shell."
run status
assert_contains "$RUN_OUTPUT" "ok         /bin/zsh as the login shell"

# As Ubuntu's /bin/zsh is /usr/bin/zsh
mkdir -p "$SANDBOX/usr/bin"
touch "$SANDBOX/usr/bin/zsh"
ln -s usr/bin "$SANDBOX/merged-bin"
replace_fn current_login_shell 'echo "$SANDBOX/merged-bin/zsh"'
replace_fn login_zsh_path 'echo "$SANDBOX/usr/bin/zsh"'
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "zsh is already the login shell."
replace_fn login_zsh_path 'echo /bin/zsh'

replace_fn current_login_shell 'echo /opt/homebrew/bin/zsh'
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    /bin/zsh as the login shell: it's /opt/homebrew/bin/zsh"

# A file it can't copy fails the step after it copies the rest
replace_fn current_login_shell 'echo /bin/zsh'
rm -rf "$HOME/.zsh" "$HOME/.zshrc" "$HOME/.config/starship.toml"
mkdir -p "$HOME/.zsh"
printf 'mine\n' > "$HOME/.zsh/aliases.zsh"
if as_unwritable "$HOME/.zsh/aliases.zsh" main; then
    assert_eq "" "$(cmp "$REPO_DIR/zsh/main.zsh" "$HOME/.zsh/main.zsh" 2>&1)" "main.zsh after a failed copy"
    [ -f "$HOME/.config/starship.toml" ] || fail "the zsh step stopped before starship.toml"
    assert_file_contains "$HOME/.zshrc" "source \$HOME/.zsh/main.zsh"
fi
test_done
