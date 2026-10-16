#!/bin/bash
set -euo pipefail

# scripts/check-docs.sh passes on the repo's docs, and fails, naming the list, when a doc's step
# list drifts from a runner's STEPS, when README.md "What's included" and the Brewfile and casks
# disagree, when the Ubuntu cask, Mac-only formula, or apt package list, the copy-back list, an
# Updating section, or the just block drifts from the code, when a Manual steps section the
# manual-steps scripts print is missing, and when a README's local link or anchor is broken. Each
# run takes seconds, so each failing copy holds several unrelated edits whose messages differ. Runs
# against a copy of the repo's files.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox

copy="$SANDBOX/repo"
# A copy of the repo's files, tracked or untracked but not ignored, made once
template="$SANDBOX/template"
mkdir -p "$template"
(cd "$REPO_DIR" && git ls-files --cached --others --exclude-standard | while IFS= read -r f; do
    [ ! -e "$f" ] || printf '%s\n' "$f"
done | tar -cf - -T -) | (cd "$template" && tar -xf -)
fresh_copy() {
    rm -rf "$copy"
    cp -R "$template" "$copy"
}
# edit <file> <sed expression>, portably
edit() {
    sed "$2" "$copy/$1" > "$SANDBOX/edited" && mv "$SANDBOX/edited" "$copy/$1"
}

fresh_copy
assert_exit 0 "$BASH" "$copy/scripts/check-docs.sh"
assert_eq "" "$RUN_OUTPUT" "check-docs output on the repo's docs"

fresh_copy
# A row missing from the How setup works table, and a step that isn't in STEPS
edit README.md '/^| `lazygit` |/d; s/^| `vim` |/| `vi` |/'
# The Ubuntu list out of order
edit README.md 's/Ubuntu runs `homebrew runtimes git/Ubuntu runs `homebrew git runtimes/'
# A step missing from ai_tools/README.md's Ubuntu section
edit ai_tools/README.md 's/It runs `claude-code`, `codex`, `t3-code`, /It runs `claude-code`, `t3-code`, /'
# The sentence that lists the steps reworded: the check names the list instead of exiting silently
edit ai_tools/README.md 's/^The steps, in order, are /The steps are /'
# A Brewfile formula, a cask, and an App Store app that README.md "What's included" doesn't list,
# and a formula and a cask it lists that the Brewfile and CASKS don't have
printf 'brew "newtool"\n' >> "$copy/homebrew/Brewfile"
edit homebrew/install.sh 's/^    stats$/    stats\
    newapp/'
edit README.md '/^- \[Dato\]/d'
edit homebrew/Brewfile '/^brew "tokei"$/d'
edit homebrew/install.sh '/^    rectangle$/d'
# The copy-back list missing files steps copy, one only on macOS and one only on Ubuntu, copying
# back to a file no step copies, copying back from the wrong place in $HOME, and running a line
# that isn't a cp. A _files function that runs a command that changes the machine fails the check
# too.
edit vim/install.sh 's|^\(    "$1" "$DOTFILES_DIR/vim/vimrc".*\)$|    sudo true\
\1|'
edit README.md '/^cp ~\/.vimrc vim\/vimrc$/d; /^cp .*dotfiles.ssh-add.plist/d; /^cp .*99-homebrew.conf/d'
edit README.md 's|^cp ~/.editorconfig editorconfig/editorconfig$|cp ~/.editorconfig editorconfig/gone|'
edit README.md 's|^cp ~/.config/tmux/tmux.conf tmux/tmux.conf$|cp ~/.tmux.conf tmux/tmux.conf\
touch "$HOME/ran"|'
# A stage of upgrade that README.md Updating doesn't describe, one check-docs.sh doesn't know, an
# Updating item that describes no stage, and a stage that no longer runs the command its doc quotes
edit README.md 's/^- Rust: `rustup update`$/- Old tool: `old update`/'
edit scripts/upgrade.sh 's/|| _stage_failed uv "$?"$/|| _stage_failed uv "$?"; true || _stage_failed newstage "$?"/; s/mas upgrade || _stage_failed mas/mas update || _stage_failed mas/'
# A justfile recipe the README's just block lacks, and a line that names the wrong script
printf '\n# A new recipe\nfoo:\n    bash foo.sh\n' >> "$copy/justfile"
edit README.md 's|^just git-signing          # bash git/setup-signing.sh|just git-signing          # bash git/other.sh|'
assert_exit 1 "$BASH" "$copy/scripts/check-docs.sh"
for message in \
    "README.md How setup works's step table, for macos," \
    "README.md How setup works's step table, for ubuntu," \
    "has vi, which isn't in STEPS" \
    "README.md Ubuntu's \"Steps.\" item doesn't match STEPS" \
    "ai_tools/README.md Ubuntu's \"It runs\" list doesn't match STEPS" \
    "ai_tools/README.md's step list doesn't match STEPS" \
    "README.md What's included doesn't list the Brewfile's newtool" \
    "README.md What's included doesn't list the cask newapp" \
    "README.md What's included doesn't list the Brewfile's Dato" \
    "README.md What's included lists tokei, which isn't in the Brewfile or CASKS" \
    "README.md What's included lists Rectangle, which isn't in the Brewfile or CASKS" \
    "vim/install.sh copies vim/vimrc, which README.md Maintenance's copy-back list lacks" \
    "ssh/install.sh copies ssh/dotfiles.ssh-add.plist, which README.md Maintenance's copy-back list lacks" \
    "ubuntu/install.sh copies ubuntu/environment.d/99-homebrew.conf, which README.md Maintenance's copy-back list lacks" \
    "README.md Maintenance's copy-back list copies back to editorconfig/gone, which isn't a file a step copies" \
    "README.md Maintenance's copy-back list copies ~/.tmux.conf back to tmux/tmux.conf, which the steps copy to ~/.config/tmux/tmux.conf" \
    "README.md Maintenance's copy-back list has a line that isn't a cp: touch \"\$HOME/ran\"" \
    "Sourcing a step or calling its _files function ran: sudo true" \
    "README.md Updating has an item that describes none of upgrade's stages: - Old tool: \`old update\`" \
    "upgrade's mas stage doesn't run what README.md Updating says: mas upgrade" \
    "README.md Updating doesn't describe upgrade's rustup stage: rustup update" \
    "upgrade has a stage, newstage, that scripts/check-docs.sh doesn't map to its docs" \
    "README.md's just recipes don't match the justfile" \
    "README.md says just git-signing runs git/other.sh, which its recipe doesn't"; do
    assert_contains "$RUN_OUTPUT" "$message"
done

fresh_copy
# A new step in ai_tools/setup.sh's UBUNTU_STEPS that the docs don't list: only the Ubuntu
# comparison fails
edit ai_tools/setup.sh 's/STEPS=(claude-code codex t3-code skills manual-steps)/STEPS=(claude-code codex t3-code skills extra manual-steps)/'
# README.md's Ubuntu step list reworded
edit README.md 's/^- \*\*Steps\.\*\* Ubuntu runs `/- **Steps.** Ubuntu has `/'
# The git, vim, and tmux package entries deleted while their headings stay: a heading doesn't
# count as the entry
edit README.md '/^- \[Git\](/d; /^- \[Vim\](/d; /^- \[tmux\](/d'
# A formula named only in prose, outside a list entry
edit README.md '/^- \[tokei\](/d'
edit README.md 's/^\*\*Networking:\*\*$/**Networking, unlike [tokei](https:\/\/example.com):**/'
# A new file in a step's list of the files it copies, which the copy-back list lacks
edit vim/install.sh 's|^\(    "$1" "$DOTFILES_DIR/vim/vimrc".*\)$|\1\
    "$1" "$DOTFILES_DIR/vim/extra.vim" "$HOME/.vim/extra.vim"|'
# A stage of upgrade-ai-tools that ai_tools/README.md doesn't describe, a cask added to
# UBUNTU_CASKS that README.md Ubuntu doesn't list, a Brewfile Mac-only formula README.md Ubuntu
# doesn't call Mac-only, and ai_tools/README.md's Ubuntu manual steps renamed
edit ai_tools/README.md 's/`t3 update`/`t3 upgrade`/'
edit homebrew/install.sh 's/^UBUNTU_CASKS=($/UBUNTU_CASKS=(\
    ghostty/'
edit README.md 's/except the Mac-only `macmon`, /except the Mac-only /'
edit ai_tools/README.md '/^## Manual steps$/,$ s/^### Ubuntu$/### Linux/'
# A package added to UBUNTU_PACKAGES that README.md Ubuntu's System packages item lacks, a broken
# anchor in README.md, and a link in ai_tools/README.md to a file that doesn't exist
edit homebrew/install.sh 's/^UBUNTU_PACKAGES="build-essential /UBUNTU_PACKAGES="build-essential wget /'
edit README.md 's|See \[Ubuntu\](#ubuntu-1) for|See [Ubuntu](#ubuntuu) for|'
edit ai_tools/README.md 's|(./claude-code/statusline.sh)|(./claude-code/statusline-x.sh)|'
assert_exit 1 "$BASH" "$copy/scripts/check-docs.sh"
for message in \
    "ai_tools/README.md's step list, less what Ubuntu skips," \
    "README.md Ubuntu's \"Steps.\" item doesn't match STEPS" \
    "README.md What's included doesn't list the Brewfile's git, in its git section" \
    "README.md What's included doesn't list the Brewfile's vim, in its vim section" \
    "README.md What's included doesn't list the Brewfile's tmux, in its tmux section" \
    "README.md What's included doesn't list the Brewfile's tokei, in its CLI tools section" \
    "vim/install.sh copies vim/extra.vim, which README.md Maintenance's copy-back list lacks" \
    "ai_tools/README.md Updating doesn't describe upgrade-ai-tools's t3 update stage: t3 update" \
    "README.md Ubuntu's cask list doesn't match UBUNTU_CASKS" \
    "README.md Ubuntu's Mac-only formulae don't match the Brewfile's OS.mac? blocks" \
    "ai_tools/README.md has no \"### Ubuntu\" under \"## Manual steps\"" \
    "README.md Ubuntu's System packages item doesn't match UBUNTU_PACKAGES" \
    "README.md: broken anchor in #ubuntuu" \
    "ai_tools/README.md: broken link to ./claude-code/statusline-x.sh"; do
    assert_contains "$RUN_OUTPUT" "$message"
done
assert_not_contains "$RUN_OUTPUT" "ai_tools/README.md's step list doesn't"
assert_not_contains "$RUN_OUTPUT" "ai_tools/README.md has no \"### macOS\""
test_done
