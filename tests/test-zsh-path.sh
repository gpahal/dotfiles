#!/bin/bash
set -euo pipefail

# Homebrew's directories come before /usr/bin in nested shells, such as tmux panes, which inherit
# HOMEBREW_PREFIX and a PATH that macOS's path_helper (in /etc/zprofile) or the parent has
# reordered. Checks login shells, which read the ~/.zprofile lines the zsh step adds, and
# interactive non-login shells, which only read main.zsh. A sandbox dir stands in for Homebrew.
# Also checks that main.zsh runs brew shellenv when a shell starts without it, and the .zprofile,
# .profile, and .zshenv lines.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# The mise checks below run the real mise, which setup_sandbox hides behind a sentinel, in a
# zsh started with env -i and the sandbox HOME
REAL_MISE="$(command -v mise || true)"
setup_sandbox
ZSH_BIN="$(command -v zsh)" || skip "zsh isn't installed"
stub brew 'exit 1'
stub dscl 'case "$*" in *UserShell*) echo "UserShell: /bin/zsh" ;; *) exit 1 ;; esac'
stub getent 'echo "$2:x:1000:1000::$HOME:/usr/bin/zsh"'
stub chsh 'exit 1'
assert_exit 0 bash "$REPO_DIR/zsh/install.sh"

BREW="$SANDBOX/brew"
mkdir -p "$BREW/bin" "$BREW/sbin"

# Print PATH's entries, one per line, from a zsh started with the given flags and a PATH that
# puts /usr/bin first, as path_helper leaves it
nested_path() {
    env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" PATH="/usr/bin:/bin:$BREW/bin:$BREW/sbin" \
        "$ZSH_BIN" "$1" 'print -rl -- $path' < /dev/null 2> /dev/null
}

# Check that the first directory comes before the second in a list of lines
assert_before() {
    local first second
    # A missing directory leaves its line number empty, which fails below
    first="$(grep -nxF -- "$2" <<< "$1" | head -1 | cut -d: -f1)" || true
    second="$(grep -nxF -- "$3" <<< "$1" | head -1 | cut -d: -f1)" || true
    if [ -z "$first" ] || [ -z "$second" ] || [ "$first" -ge "$second" ]; then
        fail "$4: $2 isn't before $3. PATH was:"
        _show "$1"
    fi
}

for flags in -lc -ic -lic; do
    output="$(nested_path "$flags")"
    assert_before "$output" "$BREW/bin" /usr/bin "zsh $flags"
    assert_before "$output" "$BREW/sbin" /usr/bin "zsh $flags"
    # ~/.local/bin (claude, codex, t3) stays ahead of Homebrew
    assert_before "$output" "$HOME/.local/bin" "$BREW/bin" "zsh $flags"
    # So do the `cargo install` and `go install` dirs, behind ~/.local/bin
    for dir in "$HOME/.cargo/bin" "$HOME/go/bin"; do
        assert_before "$output" "$HOME/.local/bin" "$dir" "zsh $flags"
        assert_before "$output" "$dir" "$BREW/bin" "zsh $flags"
    done
    # A shell started from another one, such as a tmux pane, adds no second copy
    assert_eq "" "$(sort <<< "$output" | uniq -d)" "PATH entries repeated in zsh $flags"
done

# ~/.local/bin stays ahead of mise's tool dirs in interactive shells, which `mise activate` would
# otherwise move in front of it at every prompt, so a CLI installed both ways (codex with npm and
# natively) resolves to the same copy as in login shells. mise's config adds a dir to PATH, the
# way an installed tool does, and running the hook twice stands in for prompts.
if [ -n "$REAL_MISE" ]; then
    MISE_BIN="$REAL_MISE"
    MISE_TOOL="$SANDBOX/mise-tool"
    mkdir -p "$HOME/.config/mise" "$MISE_TOOL" "$HOME/.local/bin"
    printf '[env]\n_.path = ["%s"]\n' "$MISE_TOOL" > "$HOME/.config/mise/config.toml"
    for dir in "$HOME/.local/bin" "$MISE_TOOL"; do
        printf '#!/bin/sh\n' > "$dir/both-cli"
        chmod +x "$dir/both-cli"
    done
    # Usage: mise_shell <zsh flags> <commands>
    mise_shell() {
        env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" \
            PATH="${MISE_BIN%/*}:/usr/bin:/bin:$BREW/bin:$BREW/sbin" "$ZSH_BIN" "$1" "$2" \
            < /dev/null 2> /dev/null
    }
    # shellcheck disable=SC2016 # expanded by zsh
    output="$(mise_shell -ic '_mise_hook; cd /; _mise_hook; print -rl -- $path')"
    assert_before "$output" "$HOME/.local/bin" "$MISE_TOOL" "zsh -ic after mise's hook"
    # A nested shell, such as a tmux pane, inherits the activated PATH
    # shellcheck disable=SC2016
    output="$(mise_shell -ic 'zsh -ic "_mise_hook; print -rl -- \$path"')"
    assert_before "$output" "$HOME/.local/bin" "$MISE_TOOL" "nested zsh -ic after mise's hook"
    assert_eq "$(mise_shell -lc 'command -v both-cli')" \
        "$(mise_shell -ic '_mise_hook; command -v both-cli')" "both-cli in login and interactive shells"
    rm -rf "$HOME/.config/mise" "$HOME/.local/bin/both-cli"
else
    skip_rest "the mise checks: mise isn't installed"
fi

# A ~/.zprofile missing the reordering line and the Cargo and Go line gets them right after the
# Homebrew line, so mise's shims and ~/.local/bin, added after them, stay ahead of Homebrew
load_script zsh/install.sh
printf '%s\n' "# mine" "$ZPROFILE_BREW_LINE" "$ZPROFILE_MISE_LINE" "$ZPROFILE_LOCAL_LINE" > "$HOME/.zprofile"
chmod 640 "$HOME/.zprofile"
inode="$(/bin/ls -i "$HOME/.zprofile" | awk '{ print $1 }')"
run setup_zprofile
expected="$(printf '%s\n' "# mine" "${ZPROFILE_LINES[@]}")"
assert_eq "$expected" "$(cat "$HOME/.zprofile")" "upgraded .zprofile"
# The new contents are moved into place, keeping the mode, rather than written over the old ones,
# which a full disk would leave cut short
assert_eq 640 "$(file_mode "$HOME/.zprofile")" "the mode of the upgraded .zprofile"
[ "$inode" != "$(/bin/ls -i "$HOME/.zprofile" | awk '{ print $1 }')" ] ||
    fail "the upgraded .zprofile was rewritten in place"
run setup_zprofile
assert_contains "$RUN_OUTPUT" "already sets up PATH"
assert_eq "$expected" "$(cat "$HOME/.zprofile")" ".zprofile after a second run"

# A ~/.zprofile with the lines out of order fails status, and setup puts them back in order
# where the first one was, dropping the other copies
printf '%s\n' "# mine" "$ZPROFILE_MISE_LINE" "# orbstack" "$ZPROFILE_BREW_LINE" \
    "$ZPROFILE_BREW_FIRST_LINE" "$ZPROFILE_LOCAL_LINE" "$ZPROFILE_MISE_LINE" > "$HOME/.zprofile"
assert_exit 1 zprofile_set_up
run setup_zprofile
# Only reordered, so the message mustn't say lines were added
assert_contains "$RUN_OUTPUT" "Updated the PATH lines in ~/.zprofile"
expected="$(printf '%s\n' "# mine" "${ZPROFILE_LINES[@]}" "# orbstack")"
assert_eq "$expected" "$(cat "$HOME/.zprofile")" ".zprofile with the lines out of order"
assert_exit 0 zprofile_set_up
# Lines in the wrong order alone fail status too
printf '%s\n' "$ZPROFILE_LOCAL_LINE" "${ZPROFILE_LINES[@]:0:4}" > "$HOME/.zprofile"
assert_exit 1 zprofile_set_up
run setup_zprofile
assert_eq "$(printf '%s\n' "${ZPROFILE_LINES[@]}")" "$(cat "$HOME/.zprofile")" ".zprofile with ~/.local/bin first"

# A shell started without HOMEBREW_PREFIX, from an app rather than a login shell, runs brew
# shellenv where Homebrew is installed. So does one whose PATH already starts with Homebrew's
# dirs, for which shellenv prints nothing, such as a pane of the tmux server systemd starts at
# boot: it gets tmux.conf's PATH but no HOMEBREW_PREFIX.
for prefix in /opt/homebrew /home/linuxbrew/.linuxbrew; do
    [ -x "$prefix/bin/brew" ] || continue
    for start_path in /usr/bin:/bin "$prefix/bin:$prefix/sbin:/usr/bin:/bin"; do
        assert_eq "$prefix" "$(env -i HOME="$HOME" TERM=dumb PATH="$start_path" "$ZSH_BIN" -c \
            'source ~/.zsh/main.zsh; print -r -- $HOMEBREW_PREFIX' < /dev/null 2> /dev/null)" \
            "HOMEBREW_PREFIX with PATH=$start_path"
    done
    break
done
# A shell that inherits HOMEBREW_PREFIX, from a sh that read ~/.profile or a parent zsh, gets the
# prefix's completions first in fpath
assert_eq "$BREW/share/zsh/site-functions" \
    "$(env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" PATH=/usr/bin:/bin "$ZSH_BIN" -c \
        'source ~/.zsh/main.zsh; print -r -- $fpath[1]' < /dev/null 2> /dev/null)" "fpath's first dir"

# An unwritable destination fails instead of reporting an unchanged file. Directories fail
# consistently even for a privileged test user.
# shellcheck disable=SC2329
is_ubuntu() { true; }
for entry in 'setup_zshrc .zshrc' 'setup_zprofile .zprofile' 'setup_profile .profile' 'setup_zshenv .zshenv'; do
    read -r function_name filename <<< "$entry"
    rm -f "$HOME/$filename"
    mkdir "$HOME/$filename"
    assert_exit 1 "$function_name"
    assert_not_contains "$RUN_OUTPUT" "already"
    rmdir "$HOME/$filename"
done

# On Ubuntu, ~/.profile puts ~/.local/bin ahead of Homebrew, as ~/.zprofile does, so `sh -lc` (T3
# Code's SSH check) finds the same codex as zsh. Ubuntu's stock ~/.profile adds ~/.local/bin
# before the Homebrew line, and a user may have added a plain line too. A PATH with the sandbox
# Homebrew first stands in for brew shellenv.
# shellcheck disable=SC2016 # expanded by sh
stock='if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
PATH="$HOME/.local/bin:$PATH"'
printf '%s\n' "$stock" > "$HOME/.profile"
run setup_profile
assert_contains "$RUN_OUTPUT" "Updated the Homebrew, Cargo, Go, mise, and ~/.local/bin lines in ~/.profile"
expected="$(printf '%s\n' "$stock" "${PROFILE_LINES[@]}")"
assert_eq "$expected" "$(cat "$HOME/.profile")" ".profile"
run setup_profile
assert_contains "$RUN_OUTPUT" "already"
assert_eq "$expected" "$(cat "$HOME/.profile")" ".profile after a second run"
# A ~/.profile with only the Homebrew line gets the rest
printf '%s\n' "${PROFILE_LINES[0]}" > "$HOME/.profile"
run setup_profile
assert_eq "$(printf '%s\n' "${PROFILE_LINES[@]}")" "$(cat "$HOME/.profile")" "upgraded .profile"
# One missing the Cargo, Go, and mise lines gets them between Homebrew and ~/.local/bin
printf '%s\n' "${PROFILE_LINES[0]}" "# mine" "${PROFILE_LINES[4]}" > "$HOME/.profile"
run setup_profile
assert_eq "$(printf '%s\n' "${PROFILE_LINES[@]:0:4}" "# mine" "${PROFILE_LINES[4]}")" \
    "$(cat "$HOME/.profile")" ".profile missing the Cargo, Go, and mise lines"
mkdir -p "$HOME/.local/bin"
for dir in "$HOME/.local/bin" "$BREW/bin"; do
    printf '#!/bin/sh\n' > "$dir/codex"
    chmod +x "$dir/codex"
done
assert_eq "$HOME/.local/bin/codex" \
    "$(env -i HOME="$HOME" PATH="$BREW/bin:/usr/bin:/bin" /bin/sh -lc 'command -v codex' < /dev/null)" \
    "codex in sh -lc"
output="$(env -i HOME="$HOME" PATH="$BREW/bin:/usr/bin:/bin" /bin/sh -lc 'echo "$PATH"' < /dev/null | tr : '\n')"
for dir in "$HOME/.cargo/bin" "$HOME/go/bin"; do
    assert_before "$output" "$HOME/.local/bin" "$dir" "sh -lc"
    assert_before "$output" "$dir" "$BREW/bin" "sh -lc"
done
# mise's shims go between ~/.local/bin and Cargo's dir once mise has made them, under
# $MISE_DATA_DIR when that's set, so desktop apps find mise's Node and Go
assert_not_contains "$output" "mise" "sh -lc's PATH without mise's shims dir"
mkdir -p "$HOME/.local/share/mise/shims"
output="$(env -i HOME="$HOME" PATH="$BREW/bin:/usr/bin:/bin" /bin/sh -lc 'echo "$PATH"' < /dev/null | tr : '\n')"
assert_before "$output" "$HOME/.local/bin" "$HOME/.local/share/mise/shims" "sh -lc"
assert_before "$output" "$HOME/.local/share/mise/shims" "$HOME/.cargo/bin" "sh -lc"
output="$(env -i HOME="$HOME" MISE_DATA_DIR="$SANDBOX/no-mise" PATH="$BREW/bin:/usr/bin:/bin" /bin/sh -lc 'echo "$PATH"' < /dev/null)"
assert_not_contains "$output" "mise" "sh -lc's PATH with MISE_DATA_DIR set to a dir without shims"
rm -r "$HOME/.local/share/mise"
# A login sh started from another one adds Cargo's and Go's dirs only once
nested="$(env -i HOME="$HOME" PATH="$BREW/bin:/usr/bin:/bin" /bin/sh -lc '/bin/sh -lc "echo \"\$PATH\""' < /dev/null | tr : '\n')"
for dir in "$HOME/.cargo/bin" "$HOME/go/bin"; do
    assert_eq 1 "$(grep -cxF "$dir" <<< "$nested")" "copies of $dir in a nested sh -l"
done
# A PATH that already has Cargo's dir, as rustup's own env line leaves it, still gets Go's
with_cargo="$(env -i HOME="$HOME" PATH="$HOME/.cargo/bin:$BREW/bin:/usr/bin:/bin" /bin/sh -lc 'echo "$PATH"' < /dev/null | tr : '\n')"
assert_eq 1 "$(grep -cxF "$HOME/go/bin" <<< "$with_cargo")" "copies of ~/go/bin with Cargo's dir already on PATH"
assert_eq 1 "$(grep -cxF "$HOME/.cargo/bin" <<< "$with_cargo")" "copies of ~/.cargo/bin with it already on PATH"
# On Ubuntu, ~/.zshenv puts Homebrew and ~/.local/bin on PATH for commands run directly over SSH
# (`ssh host codex`), which start a zsh that is neither login nor interactive. The sandbox Homebrew
# stands in for /home/linuxbrew/.linuxbrew.
rm -f "$HOME/.zshenv"
run setup_zshenv
assert_contains "$RUN_OUTPUT" "Updated the skip_global_compinit and PATH lines in ~/.zshenv"
assert_eq "$(printf '%s\n' "${ZSHENV_LINES[@]}")" "$(cat "$HOME/.zshenv")" ".zshenv"
run setup_zshenv
assert_contains "$RUN_OUTPUT" "already"
assert_eq "$(printf '%s\n' "${ZSHENV_LINES[@]}")" "$(cat "$HOME/.zshenv")" ".zshenv after a second run"
# A ~/.zshenv missing the PATH line gets it
printf '%s\n' "${ZSHENV_LINES[0]}" > "$HOME/.zshenv"
run setup_zshenv
assert_eq "$(printf '%s\n' "${ZSHENV_LINES[@]}")" "$(cat "$HOME/.zshenv")" "upgraded .zshenv"
run setup_zshenv
assert_contains "$RUN_OUTPUT" "already"
printf '%s\n' "${ZSHENV_LINES[@]}" | sed "s|/home/linuxbrew/.linuxbrew|$BREW|g" > "$HOME/.zshenv"
# Print PATH from zsh run with the given flags, as sshd would start it
zshenv_path() {
    env -i HOME="$HOME" TERM=dumb PATH="/usr/bin:/bin" "$ZSH_BIN" "$@" 'print -rl -- $path' \
        < /dev/null 2> /dev/null
}
output="$(zshenv_path -c)"
assert_eq "$(printf '%s\n' "$HOME/.local/bin" "$HOME/.local/share/mise/shims" "$HOME/.cargo/bin" "$HOME/go/bin" \
    "$BREW/bin" "$BREW/sbin" /usr/bin /bin)" "$output" "zsh -c"
# So `ssh host npm test` finds the tools mise installs, through its shims, under $MISE_DATA_DIR
# when that's set
mkdir -p "$HOME/.local/share/mise/shims" "$SANDBOX/mise-data/shims"
for shim in "$HOME/.local/share/mise/shims/fake-node" "$SANDBOX/mise-data/shims/fake-node"; do
    printf '#!/bin/sh\n' > "$shim"
    chmod +x "$shim"
done
# Usage: find_shim [VAR=value...]
find_shim() {
    env -i HOME="$HOME" TERM=dumb PATH="/usr/bin:/bin" "$@" "$ZSH_BIN" -c 'command -v fake-node' \
        < /dev/null 2> /dev/null
}
assert_eq "$HOME/.local/share/mise/shims/fake-node" "$(find_shim)" "fake-node in zsh -c"
assert_eq "$SANDBOX/mise-data/shims/fake-node" "$(find_shim MISE_DATA_DIR="$SANDBOX/mise-data")" \
    "fake-node in zsh -c with MISE_DATA_DIR"
# Interactive shells end up with the same order once main.zsh runs
output="$(zshenv_path -ic)"
assert_before "$output" "$HOME/.local/bin" "$BREW/bin" "zsh -ic with .zshenv"
assert_before "$output" "$BREW/bin" /usr/bin "zsh -ic with .zshenv"
assert_before "$output" "$BREW/sbin" /usr/bin "zsh -ic with .zshenv"
# Login shells skip the line, since ~/.zprofile sets up PATH there
assert_not_contains "$(zshenv_path -lc)" "$BREW/bin" "zsh -lc with .zshenv"
# A shell started from one that set up Homebrew keeps the PATH it inherits
output="$(env -i HOME="$HOME" HOMEBREW_PREFIX="$BREW" PATH="/first:/usr/bin:/bin" "$ZSH_BIN" -c \
    'print -rl -- $path' < /dev/null 2> /dev/null)"
assert_eq "$(printf '%s\n' /first /usr/bin /bin)" "$output" "zsh -c under a Homebrew shell"

# On Ubuntu, systemd user services, such as the T3 Code service and its agents, get PATH from the
# environment.d file the ubuntu step copies: Cargo's and Go's dirs, then Homebrew's. systemd
# expands ${VAR} there as sh does, so sh stands in for it.
output="$(env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -c '. "$1"; echo "$PATH"' sh \
    "$REPO_DIR/ubuntu/environment.d/99-homebrew.conf" | tr : '\n')"
assert_eq "$(printf '%s\n' "$HOME/.cargo/bin" "$HOME/go/bin" /home/linuxbrew/.linuxbrew/bin \
    /home/linuxbrew/.linuxbrew/sbin /usr/bin /bin)" "$output" "PATH from environment.d"
test_done
