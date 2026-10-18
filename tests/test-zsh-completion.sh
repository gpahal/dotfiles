#!/bin/bash
set -euo pipefail

# Completion initializes with an insecure directory on fpath, skips its commands, and keeps
# git's g alias working on both the first load and a cached load. An empty dump is rebuilt.
# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
setup_sandbox
command -v zsh &>/dev/null || skip "zsh isn't installed"

mkdir -p "$SANDBOX/secure" "$SANDBOX/insecure"
printf '#compdef git\nreturn 0\n' > "$SANDBOX/secure/_git"
printf '#compdef dotfiles-insecure\nreturn 0\n' > "$SANDBOX/insecure/_dotfiles_insecure"
chmod 777 "$SANDBOX/insecure"

probe() {
    zsh -fc '
        unset HOMEBREW_PREFIX
        fpath=("$1/secure" "$1/insecure" $fpath)
        source "$2/zsh/basic-settings.zsh"
        source "$2/zsh/functions.zsh"
        print -r -- "git=${_comps[git]-missing} g=${_comps[g]-missing} insecure=${_comps[dotfiles-insecure]-missing}"
    ' zsh "$SANDBOX" "$REPO_DIR" 2> "$SANDBOX/stderr"
}

for state in missing cached empty stale; do
    case "$state" in
        empty) : > "$HOME/.zcompdump" ;;
        stale) touch -t 200001010000 "$HOME/.zcompdump" ;;
    esac
    assert_exit 0 probe
    assert_eq "git=_git g=_git insecure=missing" "$RUN_OUTPUT" "completions with a $state dump"
    assert_eq "" "$(cat "$SANDBOX/stderr")" "completion stderr with a $state dump"
    [ -s "$HOME/.zcompdump" ] || fail "the $state dump wasn't populated"
done
test_done
