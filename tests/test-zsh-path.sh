#!/bin/bash
set -euo pipefail

# The PATH, fpath, and Homebrew environment that zsh and sh startup files give each kind of shell.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# setup_sandbox hides the real mise behind a sentinel
REAL_MISE="$(command -v mise || true)"
setup_sandbox
ZSH_BIN="$(command -v zsh)" || skip "zsh isn't installed"
stub brew 'exit 1'
stub_login_shell_zsh
assert_exit 0 bash "$REPO_DIR/zsh/install.sh"

BREW="$SANDBOX/brew"
mkdir -p "$BREW/bin" "$BREW/sbin"

# PATH starts with /usr/bin, as path_helper leaves it
nested_path() {
    env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" PATH="/usr/bin:/bin:$BREW/bin:$BREW/sbin" \
        "$ZSH_BIN" "$1" 'print -rl -- $path' < /dev/null 2> /dev/null
}

assert_before() {
    local first second
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
    assert_before "$output" "$HOME/.local/bin" "$BREW/bin" "zsh $flags"
    for dir in "$HOME/.cargo/bin" "$HOME/go/bin"; do
        assert_before "$output" "$HOME/.local/bin" "$dir" "zsh $flags"
        assert_before "$output" "$dir" "$BREW/bin" "zsh $flags"
    done
    assert_eq "" "$(sort <<< "$output" | uniq -d)" "PATH entries repeated in zsh $flags"
done

# mise activate would move its tool dirs ahead of ~/.local/bin at each prompt
if [ -n "$REAL_MISE" ]; then
    # Only mise: its dir may hold real sentinels
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
    mise_shell() {
        env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" \
            PATH="$MISE_BIN:/usr/bin:/bin:$BREW/bin:$BREW/sbin" "$ZSH_BIN" "$1" "$2" \
            < /dev/null 2> /dev/null
    }
    output="$(mise_shell -ic '_mise_hook; cd /; _mise_hook; print -rl -- $path')"
    assert_before "$output" "$HOME/.local/bin" "$MISE_TOOL" "zsh -ic after mise's hook"
    output="$(mise_shell -ic 'zsh -ic "_mise_hook; print -rl -- \$path"')"
    assert_before "$output" "$HOME/.local/bin" "$MISE_TOOL" "nested zsh -ic after mise's hook"
    assert_eq "$(mise_shell -lc 'command -v both-cli')" \
        "$(mise_shell -ic '_mise_hook; command -v both-cli')" "both-cli in login and interactive shells"
    rm -rf "$HOME/.config/mise" "$HOME/.local/bin/both-cli"
else
    skip_rest "the mise checks: mise isn't installed"
fi

# Non-interactive login shells (Codex, T3 Code) get shims without running mise or brew
stub mise 'exit 1'
: > "$STUB_LOG"
# path_helper puts Homebrew ahead of the stubs, so put them back first
cp "$HOME/.zprofile" "$SANDBOX/zprofile" 2> /dev/null || : > "$SANDBOX/zprofile"
printf '%s\n' "path=(\"$STUB_DIR\" \$path)" | cat - "$SANDBOX/zprofile" > "$HOME/.zprofile"
output="$(env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" STUB_LOG="$STUB_LOG" PATH="$STUB_DIR:/usr/bin:/bin" \
    "$ZSH_BIN" -lc 'print -rl -- $path' < /dev/null 2> /dev/null)"
assert_before "$output" "$HOME/.local/bin" "$HOME/.local/share/mise/shims" "zsh -lc"
assert_before "$output" "$HOME/.local/share/mise/shims" "$HOME/.cargo/bin" "zsh -lc"
assert_file_not_contains "$STUB_LOG" "mise"
assert_file_not_contains "$STUB_LOG" "brew"
cp "$SANDBOX/zprofile" "$HOME/.zprofile"

# On macOS too, the checks below need Ubuntu's ~/.zshenv and ~/.profile lines
load_script zsh/install.sh
as_os ubuntu
# shellcheck disable=SC2016 # expanded when it runs
replace_fn login_zsh_path 'echo "$ZSH_BIN"'
assert_exit 0 apply

# Without HOMEBREW_PREFIX, a shell gets brew shellenv's environment without running brew
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
# path_helper sets MANPATH in a login shell, so check a non-login one
assert_eq ":/a::/b" "$(env -i HOME="$HOME" TERM=dumb MANPATH=::/a::/b:: PATH=/usr/bin:/bin "$ZSH_BIN" -c \
    'print -r -- $MANPATH' < /dev/null 2> /dev/null)" "MANPATH"
[ ! -e "$SANDBOX/brew-ran" ] || fail "a shell without HOMEBREW_PREFIX ran brew"
fpath_out="$(env -i HOME="$HOME" TERM=dumb HOMEBREW_PREFIX="$BREW" PATH=/usr/bin:/bin "$ZSH_BIN" -ic \
    'print -rl -- $fpath' < /dev/null 2> /dev/null)"
assert_eq "$BREW/share/zsh/site-functions" "$(head -n 1 <<< "$fpath_out")" "fpath's first dir"
assert_eq 1 "$(grep -cxF "$BREW/share/zsh/site-functions" <<< "$fpath_out")" "copies of Homebrew's dir in fpath"

# sh -lc takes mise's shims dir from MISE_DATA_DIR when it's set
mkdir -p "$HOME/.local/share/mise/shims"
output="$(env -i HOME="$HOME" MISE_DATA_DIR="$SANDBOX/no-mise" PATH="$BREW/bin:/usr/bin:/bin" /bin/sh -lc 'echo "$PATH"' < /dev/null)"
assert_not_contains "$output" "mise" "sh -lc's PATH with MISE_DATA_DIR set to a dir without shims"
# macOS's /etc/profile moves the system dirs first, so compare only the first copy of each
expected="$(printf '%s\n' "$HOME/.local/bin" "$HOME/.local/share/mise/shims" "$HOME/.cargo/bin" "$HOME/go/bin" "$BREW/bin")"
output="$(env -i HOME="$HOME" PATH="$BREW/bin:$HOME/.cargo/bin:$HOME/go/bin:/usr/bin:/bin" /bin/sh -lc 'echo "$PATH"' < /dev/null |
    tr : '\n' | grep -xF -- "$expected" | awk '!seen[$0]++')"
assert_eq "$expected" "$output" "sh -lc's PATH with Homebrew ahead of Cargo's and Go's dirs"
mv "$HOME/.zsh/profile.sh" "$SANDBOX/profile.sh"
assert_eq ok "$(env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -lc 'echo ok' < /dev/null 2> /dev/null)" \
    "sh -lc without profile.sh"
mv "$SANDBOX/profile.sh" "$HOME/.zsh/profile.sh"

# ssh host cmd starts a zsh that's neither login nor interactive, so ~/.zshenv sources path.zsh
zshenv_path() {
    env -i HOME="$HOME" TERM=dumb PATH="${ZSHENV_PATH:-/usr/bin:/bin}" "$ZSH_BIN" "$@" \
        'print -rl -- $path' < /dev/null 2> /dev/null
}
expected="$(printf '%s\n' "$HOME/.local/bin" "$HOME/.local/share/mise/shims" "$HOME/.cargo/bin" "$HOME/go/bin" \
    "$BREW/bin" "$BREW/sbin" /usr/bin /bin)"
assert_eq "$expected" "$(zshenv_path -c)" "zsh -c"
ZSHENV_PATH="$(tr '\n' : <<< "$expected")/usr/bin:/bin"
assert_eq "" "$(zshenv_path -c | sort | uniq -d)" "PATH entries repeated in zsh -c"
assert_eq "$expected" "$(zshenv_path -c "zsh -c 'print -rl -- \$path'")" "nested zsh -c"
unset ZSHENV_PATH
[ ! -e "$SANDBOX/brew-ran" ] || fail "a shell started through ~/.zshenv ran brew"
rm -r "$HOME/.local/share/mise"
rm "$BREW/bin/brew"
cp "$REPO_DIR/zsh/path.zsh" "$HOME/.zsh/path.zsh"
output="$(env -i HOME="$HOME" HOMEBREW_PREFIX="$BREW" PATH="/first:/usr/bin:/bin" "$ZSH_BIN" -c \
    'print -rl -- $path' < /dev/null 2> /dev/null)"
assert_eq "$(printf '%s\n' /first /usr/bin /bin)" "$output" "zsh -c under a Homebrew shell"
test_done
