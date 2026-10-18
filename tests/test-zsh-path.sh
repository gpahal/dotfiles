#!/bin/bash
set -euo pipefail

# zsh/path.zsh puts ~/.local/bin, mise's shims, Cargo's and Go's dirs, then Homebrew's in front of
# /usr/bin, without running mise or brew, and without repeating a dir, in nested shells too, such
# as tmux panes, which inherit HOMEBREW_PREFIX and a PATH that macOS's path_helper (in
# /etc/zprofile) or the parent has reordered. Checks login shells, which source it from
# ~/.zprofile, interactive non-login shells, which source it from main.zsh, and on Ubuntu other
# shells, which source it from ~/.zshenv. A sandbox dir stands in for Homebrew. Also checks the
# Homebrew environment a shell that starts without it gets, the one line the step adds to each
# startup file, and the PATH zsh/profile.sh gives sh login shells through ~/.profile.

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
    # Only mise, not the rest of its dir, such as /opt/homebrew/bin, where the real sentinels are
    MISE_BIN="$SANDBOX/mise-bin"
    mkdir -p "$MISE_BIN"
    ln -s "$REAL_MISE" "$MISE_BIN/mise"
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
            PATH="$MISE_BIN:/usr/bin:/bin:$BREW/bin:$BREW/sbin" "$ZSH_BIN" "$1" "$2" \
            < /dev/null 2> /dev/null
    }
    output="$(mise_shell -ic '_mise_hook; cd /; _mise_hook; print -rl -- $path')"
    assert_before "$output" "$HOME/.local/bin" "$MISE_TOOL" "zsh -ic after mise's hook"
    # A nested shell, such as a tmux pane, inherits the activated PATH
    output="$(mise_shell -ic 'zsh -ic "_mise_hook; print -rl -- \$path"')"
    assert_before "$output" "$HOME/.local/bin" "$MISE_TOOL" "nested zsh -ic after mise's hook"
    assert_eq "$(mise_shell -lc 'command -v both-cli')" \
        "$(mise_shell -ic '_mise_hook; command -v both-cli')" "both-cli in login and interactive shells"
    rm -rf "$HOME/.config/mise" "$HOME/.local/bin/both-cli"
else
    skip_rest "the mise checks: mise isn't installed"
fi

# A login shell that isn't interactive, as Codex and T3 Code start for each command, gets mise's
# shims without running mise, and nothing in it runs brew once HOMEBREW_PREFIX is set
stub mise 'exit 1'
: > "$STUB_LOG"
# macOS's path_helper puts /etc/paths.d's Homebrew dir ahead of the stubs, so put them back first
cp "$HOME/.zprofile" "$SANDBOX/zprofile"
printf '%s\n' "path=(\"$STUB_DIR\" \$path)" | cat - "$SANDBOX/zprofile" > "$HOME/.zprofile"
output="$(env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" STUB_LOG="$STUB_LOG" PATH="$STUB_DIR:/usr/bin:/bin" \
    "$ZSH_BIN" -lc 'print -rl -- $path' < /dev/null 2> /dev/null)"
assert_before "$output" "$HOME/.local/bin" "$HOME/.local/share/mise/shims" "zsh -lc"
assert_before "$output" "$HOME/.local/share/mise/shims" "$HOME/.cargo/bin" "zsh -lc"
assert_file_not_contains "$STUB_LOG" "mise"
assert_file_not_contains "$STUB_LOG" "brew"
cp "$SANDBOX/zprofile" "$HOME/.zprofile"

# Each startup file gets one line, after what other installers (e.g. OrbStack) put there, so
# their dirs come first. A second run changes nothing.
load_script zsh/install.sh
# On macOS, which has no ~/.profile line to source it, profile.sh isn't copied
# shellcheck disable=SC2329
macos_profile() {
    is_ubuntu() { false; }
    is_macos() { true; }
    login_zsh_path() { echo "$ZSH_BIN"; }
    rm -f "$HOME/.zsh/profile.sh"
    assert_exit 0 apply
    [ ! -e "$HOME/.zsh/profile.sh" ] || fail "apply copied profile.sh on macOS"
    run status
    assert_contains "$RUN_OUTPUT" "skipped    profile.sh in ~/.zsh: Ubuntu only"
}
subtest macos_profile
# Ubuntu's, which apply needs, at the path of the zsh found here
# shellcheck disable=SC2329
is_ubuntu() { true; }
# shellcheck disable=SC2329
is_macos() { false; }
# shellcheck disable=SC2329
login_zsh_path() { echo "$ZSH_BIN"; }
stock='if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
PATH="$HOME/.local/bin:$PATH"'
printf '%s\n' "# mine" > "$HOME/.zshrc"
printf '%s\n' "# mine" > "$HOME/.zprofile"
rm -f "$HOME/.zshenv"
printf '%s\n' "$stock" > "$HOME/.profile"
startup_files() {
    local file
    for file in .zshrc .zprofile .zshenv .profile; do
        printf '== %s\n' "$file"
        cat "$HOME/$file"
    done
}
assert_exit 0 apply
expected="$(printf '%s\n' "== .zshrc" "# mine" "$ZSHRC_LINE" "== .zprofile" "# mine" "$PATH_ZSH_LINE" \
    "== .zshenv" "$PATH_ZSH_LINE" "== .profile" "$stock" "$PROFILE_LINE")"
assert_eq "$expected" "$(startup_files)" "the startup files"
assert_exit 0 apply
assert_not_contains "$RUN_OUTPUT" "Added"
assert_eq "$expected" "$(startup_files)" "the startup files after a second run"
run status
assert_contains "$RUN_OUTPUT" "ok         profile.sh sourced in ~/.profile"
assert_contains "$RUN_OUTPUT" "ok         path.zsh sourced in ~/.zshenv"
assert_eq "" "$(grep -E '^ *missing ' <<< "$RUN_OUTPUT" | grep -v "login shell" || true)" "missing items after a run"

# A shell started without HOMEBREW_PREFIX, from an app or a systemd service rather than a login
# shell, gets the environment `brew shellenv zsh` would give it, without running brew: the copy of
# path.zsh points at the sandbox Homebrew, whose brew records that it ran
sed -e "s|/home/linuxbrew/.linuxbrew|$BREW|g" -e "s|/opt/homebrew|$BREW|g" "$REPO_DIR/zsh/path.zsh" \
    > "$HOME/.zsh/path.zsh"
printf '#!/bin/sh\ntouch "%s"\n' "$SANDBOX/brew-ran" > "$BREW/bin/brew"
chmod +x "$BREW/bin/brew"
if [[ "$OSTYPE" == darwin* ]]; then repository="$BREW"; else repository="$BREW/Homebrew"; fi
for flags in -ic -lc -c; do
    assert_eq "$BREW $BREW/Cellar $repository $BREW/share/zsh/site-functions $BREW/share/info:" \
        "$(env -i HOME="$HOME" TERM=dumb PATH=/usr/bin:/bin "$ZSH_BIN" "$flags" \
            'print -r -- $HOMEBREW_PREFIX $HOMEBREW_CELLAR $HOMEBREW_REPOSITORY $fpath[1] $INFOPATH' \
            < /dev/null 2> /dev/null)" "Homebrew's environment in zsh $flags"
done
# A MANPATH gets a leading colon, so man searches its default path too. macOS's path_helper sets
# MANPATH in a login shell, so this checks another.
assert_eq ":/a::/b" "$(env -i HOME="$HOME" TERM=dumb MANPATH=::/a::/b:: PATH=/usr/bin:/bin "$ZSH_BIN" -c \
    'print -r -- $MANPATH' < /dev/null 2> /dev/null)" "MANPATH"
[ ! -e "$SANDBOX/brew-ran" ] || fail "a shell without HOMEBREW_PREFIX ran brew"
# A shell that inherits HOMEBREW_PREFIX, from a sh that read ~/.profile or a parent zsh, gets the
# prefix's completions first in fpath
assert_eq "$BREW/share/zsh/site-functions" \
    "$(env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" PATH=/usr/bin:/bin "$ZSH_BIN" -c \
        'source ~/.zsh/main.zsh; print -r -- $fpath[1]' < /dev/null 2> /dev/null)" "fpath's first dir"

# On Ubuntu, ~/.profile puts ~/.local/bin ahead of Homebrew, as ~/.zprofile does, so `sh -lc` (T3
# Code's SSH check) finds the same codex as zsh. Ubuntu's stock ~/.profile adds ~/.local/bin
# before the line that sources profile.sh, and a user may have added a plain line too. A PATH with
# the sandbox Homebrew first stands in for brew shellenv.
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
# A PATH that already has Homebrew ahead of Cargo's and Go's dirs, as a desktop session's PATH
# from systemd has once brew shellenv runs, still ends up in ~/.zprofile's order
# macOS's /etc/profile moves the system dirs first, so compare only the first copy of each of these
expected="$(printf '%s\n' "$HOME/.local/bin" "$HOME/.local/share/mise/shims" "$HOME/.cargo/bin" "$HOME/go/bin" "$BREW/bin")"
output="$(env -i HOME="$HOME" PATH="$BREW/bin:$HOME/.cargo/bin:$HOME/go/bin:/usr/bin:/bin" /bin/sh -lc 'echo "$PATH"' < /dev/null |
    tr : '\n' | grep -xF -- "$expected" | awk '!seen[$0]++')"
assert_eq "$expected" "$output" "sh -lc's PATH with Homebrew ahead of Cargo's and Go's dirs"
# Without the copy of profile.sh, sh still starts
mv "$HOME/.zsh/profile.sh" "$SANDBOX/profile.sh"
assert_eq ok "$(env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -lc 'echo ok' < /dev/null 2> /dev/null)" \
    "sh -lc without profile.sh"
mv "$SANDBOX/profile.sh" "$HOME/.zsh/profile.sh"

# On Ubuntu, ~/.zshenv sources path.zsh too, for commands run directly over SSH (`ssh host
# codex`), which start a zsh that is neither login nor interactive. The sandbox Homebrew stands in
# for /home/linuxbrew/.linuxbrew.
# Print PATH from zsh run with the given flags and PATH, as sshd or systemd would start it
zshenv_path() {
    env -i HOME="$HOME" TERM=dumb PATH="${ZSHENV_PATH:-/usr/bin:/bin}" "$ZSH_BIN" "$@" \
        'print -rl -- $path' < /dev/null 2> /dev/null
}
expected="$(printf '%s\n' "$HOME/.local/bin" "$HOME/.local/share/mise/shims" "$HOME/.cargo/bin" "$HOME/go/bin" \
    "$BREW/bin" "$BREW/sbin" /usr/bin /bin)"
assert_eq "$expected" "$(zshenv_path -c)" "zsh -c"
# Login and interactive shells get the same. `mise activate` puts the tools themselves ahead of
# the shims in an interactive shell at its first prompt.
# macOS's path_helper adds system dirs to a login shell's PATH, so compare only these
assert_eq "$expected" "$(zshenv_path -lc | grep -xF -- "$expected")" "zsh -lc with .zshenv"
assert_eq "$expected" "$(zshenv_path -ic)" "zsh -ic with .zshenv"
# A zsh started under a PATH that already has these dirs, as a systemd user service's PATH from
# environment.d does, adds no second copy, nested or not
ZSHENV_PATH="$(tr '\n' : <<< "$expected")/usr/bin:/bin"
assert_eq "" "$(zshenv_path -c | sort | uniq -d)" "PATH entries repeated in zsh -c"
assert_eq "$expected" "$(zshenv_path -c "zsh -c 'print -rl -- \$path'")" "nested zsh -c"
unset ZSHENV_PATH
[ ! -e "$SANDBOX/brew-ran" ] || fail "a shell started through ~/.zshenv ran brew"
rm -r "$HOME/.local/share/mise"
rm "$BREW/bin/brew"
cp "$REPO_DIR/zsh/path.zsh" "$HOME/.zsh/path.zsh"
# A shell started from one that set up Homebrew keeps the PATH it inherits
output="$(env -i HOME="$HOME" HOMEBREW_PREFIX="$BREW" PATH="/first:/usr/bin:/bin" "$ZSH_BIN" -c \
    'print -rl -- $path' < /dev/null 2> /dev/null)"
assert_eq "$(printf '%s\n' /first /usr/bin /bin)" "$output" "zsh -c under a Homebrew shell"

# On Ubuntu, systemd user services, such as the T3 Code service and its agents, get PATH from the
# environment.d file the ubuntu step copies: ~/.local/bin, Cargo's and Go's dirs, then Homebrew's. systemd
# expands ${VAR} there as sh does, so sh stands in for it.
output="$(env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -c '. "$1"; echo "$PATH"' sh \
    "$REPO_DIR/ubuntu/environment.d/99-homebrew.conf" | tr : '\n')"
assert_eq "$(printf '%s\n' "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/go/bin" /home/linuxbrew/.linuxbrew/bin \
    /home/linuxbrew/.linuxbrew/sbin /usr/bin /bin)" "$output" "PATH from environment.d"
test_done
