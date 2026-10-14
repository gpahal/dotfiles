# shellcheck shell=bash
# The homebrew step's cask listing. homebrew/install.sh sources this file. It only defines
# functions.

# Print each cask brew lists, a tab, and the path of the app it installs, with one brew call for
# them all. The path is empty for a cask with no app, and for every cask off macOS or without jq.
installed_cask_apps() {
    if is_macos && command -v jq &>/dev/null; then
        brew info --json=v2 --installed --cask 2>/dev/null | jq -r ".casks[] | [.token, $CASK_APP_JQ] | @tsv"
    else
        brew list --cask -1 2>/dev/null | awk '{ print $0 "\t" }'
    fi
}
