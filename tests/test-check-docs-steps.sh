#!/bin/bash
set -euo pipefail

# check-docs.sh fails on a README step table whose OS marks disagree with the runners' step lists.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

repo="$SANDBOX/repo"
mkdir -p "$repo/lib" "$repo/scripts/lib" "$repo/ai_tools"
cp "$REPO_DIR/lib/common.sh" "$repo/lib/"
cp "$REPO_DIR/scripts/check-docs.sh" "$repo/scripts/"
cp "$REPO_DIR"/scripts/lib/*.sh "$repo/scripts/lib/"

# runner <path> <steps dir> <macOS steps> <Ubuntu steps>
runner() {
    local up=""
    [ "${1%/*}" == "$1" ] || up=/..
    printf '%s\n' '#!/bin/bash' 'set -euo pipefail' '' '# Set up the test machine.' '' \
        "source \"\$(CDPATH='' cd -- \"\$(dirname \"\${BASH_SOURCE[0]}\")$up\" && pwd)/lib/common.sh\"" \
        "MACOS_STEPS=($3)" "UBUNTU_STEPS=($4)" "STEPS_DIR=\"\$DOTFILES_DIR$2\"" \
        'runner_main test "" "$@"' > "$repo/$1"
}
step() {
    mkdir -p "$repo/$1"
    printf '%s\n' '#!/bin/bash' "# Set up ${1##*/}." > "$repo/$1/install.sh"
}
runner setup.sh "" "hammerspoon editorconfig" "editorconfig ubuntu"
runner ai_tools/setup.sh /ai_tools "claude-code codex" "claude-code"
step hammerspoon
step editorconfig
step ubuntu
step ai_tools/claude-code
step ai_tools/codex

manual_steps() {
    printf '%s\n' '## Manual steps' '' '### macOS' '' '1. Log in.' '' '### Ubuntu' '' '1. Log in.'
}
{
    printf '%s\n' '# Dotfiles' '' '## How setup works' '' '| Step | What it does |' '| :- | :- |' \
        '| `hammerspoon` | Copies the config. macOS only |' '| `editorconfig` | Copies `~/.editorconfig` |' \
        '| `ubuntu` | Sets up the system. Ubuntu only |' ''
    manual_steps
} > "$repo/README.md"
{
    printf '%s\n' '# AI tools' '' \
        'The steps, in order, are `claude-code` and `codex`. Ubuntu skips `codex`.' ''
    manual_steps
} > "$repo/ai_tools/README.md"

sed -i.bak -e '/^| `hammerspoon`/s/ macOS only |$/ |/' -e '/^| `editorconfig`/s/ |$/. Ubuntu only |/' \
    "$repo/README.md"
assert_exit 1 /bin/bash "$repo/scripts/check-docs.sh"
assert_contains "$RUN_OUTPUT" 'step table should mark hammerspoon "macOS only", the only OS whose STEPS have it'
assert_contains "$RUN_OUTPUT" 'step table marks editorconfig "Ubuntu only", but both OSes'"'"' STEPS have it'
test_done
