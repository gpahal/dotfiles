#!/bin/bash
# shellcheck disable=SC2016 # backquotes and $ in sed and grep patterns, the uname stub, and inner bash -c scripts
set -euo pipefail

# Check that the docs list each runner's steps as its STEPS has them, on macOS and on Ubuntu:
# - README.md "How setup works": the step table, which holds both OSes' steps in order
# - ai_tools/README.md: "The steps, in order, are ...", less the ones "Ubuntu skips"
# Also check that:
# - README.md "What's included" lists every formula in homebrew/Brewfile, and every App Store app
#   in homebrew/install.sh's MAS_APPS and cask in its CASKS, as a list item's link in the section package_section
#   names, and lists no other package in its "CLI tools" and "Apps" lists
# - README.md "Ubuntu" names the casks in UBUNTU_CASKS, as Mac-only the formulae in the
#   Brewfile's `if OS.mac?` blocks, and in its "System packages." item the apt packages in
#   homebrew/install.sh's UBUNTU_PACKAGES
# - README.md "Maintenance" copies back each file the steps' *_files functions copy, from where
#   the step copies it, and nothing else
# - each Updating section describes every stage of upgrade or upgrade-ai-tools, as stage_doc maps,
#   and each stage runs what stage_code maps
# - README.md and ai_tools/README.md each have the "Manual steps" section for macOS and Ubuntu that
#   the manual-steps scripts print
# - README.md's and ai_tools/README.md's links to local files resolve, down to their #anchors
# `just check` runs it.

REPO_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/markdown.sh
source "$REPO_DIR/scripts/lib/markdown.sh"
# shellcheck source=lib/brew.sh
source "$REPO_DIR/scripts/lib/brew.sh"
# shellcheck source=lib/runners.sh
source "$REPO_DIR/scripts/lib/runners.sh"
errors=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "$1" >&2
    errors=$((errors + 1))
}

# Print the section of a Markdown file under a heading, given with its #s, as md_section does. A
# missing section prints nothing, which the check that reads it reports.
section() {
    md_section "$@" || true
}

# Print the words in list file $1, or, when it's empty, the text the check looked for in the doc
# ($2), so a rewording that hides the list says what to restore
doc_words() {
    if [ -s "$1" ]; then
        tr '\n' ' ' < "$1"
    else
        echo "(nothing found: it looked for $2)"
    fi
}

# Print the backquoted words in a line of text, one per line
backquoted() {
    printf '%s\n' "$1" | { grep -o '`[^`]*`' || true; } | tr -d '`'
}

# Print the lines of the first list that are in the second, in the first's order
in_both() {
    grep -Fxf "$2" "$1" || true
}

# compare <what> <expected file> <actual file> <the text the check looks for in the doc>
compare() {
    if ! cmp -s "$2" "$3"; then
        fail "$1 doesn't match STEPS. STEPS: $(tr '\n' ' ' < "$2")
  The doc: $(doc_words "$3" "$4")"
    fi
}

# A failed --help leaves the list empty, which the loop below reports
runner_steps "$REPO_DIR/setup.sh" Darwin > "$tmp/setup-macos" || true
runner_steps "$REPO_DIR/setup.sh" Linux > "$tmp/setup-ubuntu" || true
runner_steps "$REPO_DIR/ai_tools/setup.sh" Darwin > "$tmp/ai-macos" || true
runner_steps "$REPO_DIR/ai_tools/setup.sh" Linux > "$tmp/ai-ubuntu" || true
for list in setup-macos setup-ubuntu ai-macos ai-ubuntu; do
    [ -s "$tmp/$list" ] || fail "Couldn't read the steps for $list from the runner's --help"
done

# README.md "How setup works": the first cell of each table row under the heading
readme="$REPO_DIR/README.md"
section "$readme" "## Ubuntu" > "$tmp/ubuntu-section"
section "$readme" "## How setup works" | { grep '^| `' || true; } |
    sed 's/^| `\([^`]*\)`.*/\1/' > "$tmp/table"
for os in macos ubuntu; do
    in_both "$tmp/table" "$tmp/setup-$os" > "$tmp/table-$os"
    compare "README.md How setup works's step table, for $os," "$tmp/setup-$os" "$tmp/table-$os" \
        'table rows starting "| `<step>`" under "## How setup works"'
done
cat "$tmp/setup-macos" "$tmp/setup-ubuntu" > "$tmp/setup-all"
while IFS= read -r step; do
    grep -qxF "$step" "$tmp/setup-all" || fail "README.md How setup works's step table has $step, which isn't in STEPS"
done < "$tmp/table"

# ai_tools/README.md: one sentence lists every step, and the next says which Ubuntu skips
ai_readme="$REPO_DIR/ai_tools/README.md"
line="$(grep -m1 '^The steps, in order, are ' "$ai_readme" || true)"
sentence="${line#The steps, in order, are }"
backquoted "${sentence%%.*}" > "$tmp/ai-list"
compare "ai_tools/README.md's step list" "$tmp/ai-macos" "$tmp/ai-list" \
    'a line starting "The steps, in order, are `<step>`, ..." in ai_tools/README.md'
skips="${line#*Ubuntu skips }"
[ "$skips" != "$line" ] || skips=""
backquoted "${skips%%[;.]*}" > "$tmp/ai-skips"
grep -vxFf "$tmp/ai-skips" "$tmp/ai-list" > "$tmp/ai-ubuntu-list" || true
compare "ai_tools/README.md's step list, less what Ubuntu skips," "$tmp/ai-ubuntu" "$tmp/ai-ubuntu-list" \
    '"Ubuntu skips `<step>`" in the line starting "The steps, in order, are " in ai_tools/README.md'

# README.md "What's included" against the Brewfile, MAS_APPS, and CASKS. A package and a name in the README
# match when they're equal lowercased, with all but letters and digits dropped: the README's
# ShellCheck is the formula shellcheck, and Logi Options+ the cask logi-options+. Homebrew names
# some packages apart from their tools: git-delta is delta, a font cask starts with font-, and a
# cask whose name a formula took ends in -app.
canonical() {
    tr '[:upper:]' '[:lower:]' |
        sed -e 's/^git-delta$/delta/' -e 's/^font-//' -e 's/-app$//' -e 's/[^a-z0-9]//g'
}

# Print the ### section of README.md "What's included" that must list a package: CLI tools for a
# formula, Apps for a cask or an App Store app, or the section of the tool it sets up
package_section() {
    case "$1 $2" in
        "formula git") echo git ;;
        "formula vim") echo vim ;;
        "formula tmux") echo tmux ;;
        "formula starship" | "formula zsh-"*) echo zsh ;;
        "cask font-monaspace") echo Fonts ;;
        "cask ghostty") echo Ghostty ;;
        "cask zed") echo Zed ;;
        formula*) echo "CLI tools" ;;
        *) echo Apps ;;
    esac
}

brewfile="$REPO_DIR/homebrew/Brewfile"
{
    brewfile_formulae "$brewfile" | sed 's/^/formula /; s/ [^ ]*$//'
    # MAS_APPS's entries read "<id> <name>", with "optional" after some
    array_entries "$REPO_DIR/homebrew/install.sh" MAS_APPS | sed -E 's/^[0-9]+ /mas /; s/ optional$//'
    cask_list "$REPO_DIR/homebrew/install.sh" CASKS | sed 's/^/cask /'
} > "$tmp/packages"
[ -s "$tmp/packages" ] || fail "Couldn't read the packages from homebrew/Brewfile and homebrew/install.sh"
cut -d' ' -f2- "$tmp/packages" | canonical > "$tmp/package-names"

section "$readme" "## What's included" > "$tmp/included"
[ -s "$tmp/included" ] || fail "README.md has no What's included section"

# Print the link labels in the list items of a ### section of What's included, and its ####
# subsections. A heading or a link in a paragraph doesn't count.
section_entries() {
    awk -v name="$1" '/^#+ / { if (/^### / || /^## /) on = ($0 == "### " name || index($0, "### " name " (") == 1); next }
        on && /^[[:space:]]*- /' "$tmp/included" |
        { grep -oE '\[[^]]+\]\(' || true; } | sed 's/^\[//; s/\]($//' | canonical
}

# Each section's entries are read once, and the names were made canonical in one pass above, line
# for line, since forking per package made this slow
while read -r kind name && read -r canonical_name <&3; do
    section="$(package_section "$kind" "$name")"
    [ -f "$tmp/entries-$section" ] || section_entries "$section" > "$tmp/entries-$section"
    if ! grep -qxF -- "$canonical_name" "$tmp/entries-$section"; then
        case "$kind" in
            cask) fail "README.md What's included doesn't list the cask $name, in its $section section" ;;
            mas) fail "README.md What's included doesn't list the App Store app $name, in its $section section" ;;
            *) fail "README.md What's included doesn't list the Brewfile's $name, in its $section section" ;;
        esac
    fi
done < "$tmp/packages" 3< "$tmp/package-names"
# Each item of the package lists, by its first link
awk '/^### / { in_list = ($0 ~ /^### (CLI tools|Apps)/) } in_list && /^- \[/' "$tmp/included" |
    sed -E 's/^- \[([^]]+)\].*/\1/' > "$tmp/listed"
canonical < "$tmp/listed" > "$tmp/listed-names"
while IFS= read -r label && IFS= read -r canonical_name <&3; do
    grep -qxF -- "$canonical_name" "$tmp/package-names" ||
        fail "README.md What's included lists $label, which isn't in the Brewfile, MAS_APPS, or CASKS"
done < "$tmp/listed" 3< "$tmp/listed-names"

# README.md "Ubuntu": the casks the Packages item says Ubuntu gets "here", against UBUNTU_CASKS
line="$(awk '/Of the casks, Ubuntu gets / { print; exit }' "$tmp/ubuntu-section")"
line="${line#*Of the casks, Ubuntu gets }"
backquoted "${line%% here*}" | sort > "$tmp/ubuntu-casks-doc"
cask_list "$REPO_DIR/homebrew/install.sh" UBUNTU_CASKS | sort > "$tmp/ubuntu-casks"
cmp -s "$tmp/ubuntu-casks" "$tmp/ubuntu-casks-doc" ||
    fail "README.md Ubuntu's cask list doesn't match UBUNTU_CASKS. UBUNTU_CASKS: $(tr '\n' ' ' < "$tmp/ubuntu-casks")
  The doc: $(doc_words "$tmp/ubuntu-casks-doc" '"Of the casks, Ubuntu gets `<cask>` ... here" under "## Ubuntu"')"

# README.md "Ubuntu": the formulae the Packages item calls Mac-only, against the Brewfile's
# `if OS.mac?` blocks
line="$(awk '/except the Mac-only / { print; exit }' "$tmp/ubuntu-section")"
line="${line#*except the Mac-only }"
backquoted "${line%%.*}" | sort > "$tmp/mac-only-doc"
brewfile_formulae "$brewfile" | awk '$2 == "mac" { print $1 }' | sort > "$tmp/mac-only"
cmp -s "$tmp/mac-only" "$tmp/mac-only-doc" ||
    fail "README.md Ubuntu's Mac-only formulae don't match the Brewfile's OS.mac? blocks. The Brewfile: $(tr '\n' ' ' < "$tmp/mac-only")
  The doc: $(doc_words "$tmp/mac-only-doc" '"except the Mac-only `<formula>` ..." under "## Ubuntu"')"

# README.md "Ubuntu": the System packages item's backquoted list, against UBUNTU_PACKAGES
line="$(awk '/^- \*\*System packages\.\*\* / { print; exit }' "$tmp/ubuntu-section")"
line="${line#*installs these apt packages}"
backquoted "$line" | head -1 | tr ' ' '\n' | sort > "$tmp/ubuntu-packages-doc"
sed -n 's/^UBUNTU_PACKAGES="\(.*\)"$/\1/p' "$REPO_DIR/homebrew/install.sh" | tr ' ' '\n' | sort > "$tmp/ubuntu-packages"
[ -s "$tmp/ubuntu-packages" ] || fail "Couldn't read UBUNTU_PACKAGES from homebrew/install.sh"
cmp -s "$tmp/ubuntu-packages" "$tmp/ubuntu-packages-doc" ||
    fail "README.md Ubuntu's System packages item doesn't match UBUNTU_PACKAGES. UBUNTU_PACKAGES: $(tr '\n' ' ' < "$tmp/ubuntu-packages")
  The doc: $(doc_words "$tmp/ubuntu-packages-doc" '"- **System packages.** ... installs these apt packages `<packages>`" under "## Ubuntu"')"

# README.md "Maintenance": the copy-back list copies each file a step copies into $HOME, or into
# /etc, back to the repo, from where the step puts it. A step names the files it copies in *_files
# functions that take the action as their first argument. Each step is sourced twice, with uname
# reporting Darwin, then Linux, and an empty HOME, and each such function called with an action that
# records each copy as <repo file> <tab> <destination> <tab> <step>. A command that would change the
# machine or use the network fails the check when sourcing or a *_files function runs it.
copy_home="$tmp/home"
mkdir -p "$copy_home" "$tmp/sentinels"
# shellcheck source=../tests/sentinels.sh
source "$REPO_DIR/tests/sentinels.sh"
# git and sudo too, which tests/lib.sh leaves real or stubs on its own
for cmd in $SENTINELS git sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$cmd" "$tmp/sentinels.log" > "$tmp/sentinels/$cmd"
    chmod +x "$tmp/sentinels/$cmd"
done
# Only the repo's own steps, a new one not yet added included, so an install.sh .gitignore lists,
# such as one under .scratch, isn't sourced. A tracked file deleted from the working tree is
# skipped. Only those with such a function, since sourcing one takes a while.
git -C "$REPO_DIR" ls-files --cached --others --exclude-standard -- '*/install.sh' |
    awk -F/ -v repo="$REPO_DIR" 'NF <= 3 && !/\/skills\// { print repo "/" $0 }' |
    while IFS= read -r f; do [ ! -f "$f" ] || printf '%s\0' "$f"; done |
    xargs -0 grep -lE '^[a-z0-9_]+_files\(\) \{' | sort -u > "$tmp/installs"
for os in Darwin Linux; do
    os_uname_shim "$tmp/$os" "$os"
    env -i HOME="$copy_home" PATH="$tmp/$os:$tmp/sentinels:/usr/bin:/bin" REPO_DIR="$REPO_DIR" "$BASH" -c '
        source "$REPO_DIR/lib/common.sh"
        common="$(compgen -A function)"
        while IFS= read -r install; do
            (
                record() { printf "%s\t%s\t%s\n" "${1#"$REPO_DIR"/}" "$2" "${install#"$REPO_DIR"/}"; }
                source "$install" > /dev/null
                for fn in $(compgen -A function | grep "_files\$"); do
                    ! printf "%s\n" "$common" | grep -qxF "$fn" || continue
                    "$fn" record || echo "FAILED ${install#"$REPO_DIR"/} $fn" >&2
                done
            ) < /dev/null
        done < "$1"' bash "$tmp/installs"
done > "$tmp/copies" 2> "$tmp/copies-errors"
while IFS= read -r line; do
    fail "Recording the files the steps copy failed: $line"
done < "$tmp/copies-errors"
if [ -s "$tmp/sentinels.log" ]; then
    fail "Sourcing a step or calling its _files function ran: $(sort -u "$tmp/sentinels.log" | tr '\n' ';')"
fi
[ -s "$tmp/copies" ] || fail "Couldn't record the files the steps copy"

# The copy-back list, the section's first code block, runs with a cp that records each copy as
# <repo file> <tab> <home file>, from the repo with the same empty HOME. lazygit answers
# --print-config-dir as it does on macOS. Each line must be a cp, or a loop around one, and only
# those lines run.
section "$readme" "## Maintenance" | awk -v fence="$MD_FENCE" '$0 ~ fence { fences++; next } fences == 1' > "$tmp/copy-back"
while IFS= read -r line; do
    case "$line" in
        "cp "* | "for "*"; do cp "*"; done") printf '%s\n' "$line" ;;
        *) fail "README.md Maintenance's copy-back list has a line that isn't a cp: $line" ;;
    esac
done < "$tmp/copy-back" > "$tmp/copy-back-cp"
env -i HOME="$copy_home" PATH=/usr/bin:/bin "$BASH" -c '
    cd "$1" || exit 1
    cp() {
        local dest="${!#}" src
        for src in "${@:1:$#-1}"; do
            case "$dest" in
                */) printf "%s\t%s\n" "$dest${src##*/}" "$src" ;;
                *) printf "%s\t%s\n" "$dest" "$src" ;;
            esac
        done
    }
    lazygit() { echo "$HOME/Library/Application Support/lazygit"; }
    source "$2"' bash "$REPO_DIR" "$tmp/copy-back-cp" > "$tmp/copied-back" ||
    fail "README.md Maintenance's copy-back list failed to run"

# Print a path with HOME as ~
tilde() {
    # shellcheck disable=SC2088 # shown, not expanded
    case "$1" in "$copy_home"/*) echo "~/${1#"$copy_home"/}" ;; *) echo "$1" ;; esac
}
cut -f1 "$tmp/copied-back" | sort -u > "$tmp/copied-back-files"
while IFS=$'\t' read -r file _ install; do
    [ -e "$REPO_DIR/$file" ] || fail "$install copies $file, which doesn't exist"
    grep -qxF -- "$file" "$tmp/copied-back-files" ||
        fail "$install copies $file, which README.md Maintenance's copy-back list lacks"
done < <(sort -u "$tmp/copies")
while IFS=$'\t' read -r file home; do
    dests="$(awk -F '\t' -v f="$file" '$1 == f { print $2 }' "$tmp/copies" | sort -u)"
    if [ -z "$dests" ]; then
        fail "README.md Maintenance's copy-back list copies back to $file, which isn't a file a step copies"
    elif ! printf '%s\n' "$dests" | grep -qxF -- "$home"; then
        fail "README.md Maintenance's copy-back list copies $(tilde "$home") back to $file, which the steps copy to $(printf '%s\n' "$dests" | while IFS= read -r d; do tilde "$d"; done | paste -sd, - | sed 's/,/, /g')"
    fi
done < "$tmp/copied-back"

# README.md and ai_tools/README.md "Updating" against the stages of upgrade and upgrade-ai-tools in
# scripts/upgrade.sh, whose functions are upgrade and upgrade_ai_tools: each name a stage adds to
# failed, directly or through _stage_failed, must map to text its Updating section has (stage_doc),
# and to code the function's body has (stage_code). Each item of the section's first list must
# describe a stage. A new stage goes in the map.
# stage_doc's text is what a user sees, such as the command they'd run or what the stage updates,
# so the docs can leave out how the script runs it.
stage_doc() {
    case "$1:$2" in
        upgrade:apt) echo 'apt packages' ;;
        upgrade:brew) echo 'brew upgrade' ;;
        "upgrade:brew bundle") echo 'formulae added to the Brewfile' ;;
        upgrade:casks) echo 'casks added to the homebrew step' ;;
        "upgrade:brew cleanup") echo 'brew cleanup' ;;
        upgrade:fc-cache) echo 'font cache' ;;
        "upgrade:self-updating casks") echo 'Casks that update themselves' ;;
        upgrade:mas) echo 'mas upgrade' ;;
        "upgrade:vim plugins" | "upgrade:tmux plugins") echo 'vim and tmux plugins' ;;
        upgrade:mise) echo 'mise upgrade' ;;
        "upgrade:mise hook-env") echo 'the Node `mise upgrade` installed' ;;
        upgrade:npm) echo 'npm update -g' ;;
        upgrade:uv) echo 'uv tool upgrade --all' ;;
        upgrade:rustup) echo 'rustup update' ;;
        upgrade:upgrade-ai-tools) echo 'upgrade-ai-tools' ;;
        "upgrade-ai-tools:claude update") echo 'claude update' ;;
        "upgrade-ai-tools:desktop apps") echo 'Desktop apps' ;;
        "upgrade-ai-tools:codex cask") echo 'Codex CLI' ;;
        "upgrade-ai-tools:claude marketplaces") echo 'claude plugin marketplace update' ;;
        'upgrade-ai-tools:claude plugin $id') echo 'claude plugin update' ;;
        "upgrade-ai-tools:claude plugin list") echo 'claude plugin list' ;;
        "upgrade-ai-tools:t3 update") echo 't3 update' ;;
        "upgrade-ai-tools:codex marketplaces") echo 'codex plugin marketplace upgrade' ;;
        *) return 1 ;;
    esac
}

# The text in the function's body that runs a stage, where it isn't what stage_doc quotes
stage_code() {
    case "$1:$2" in
        upgrade:apt) echo 'apt_get_update && sudo apt' ;;
        upgrade:brew) echo 'brew update && HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1 brew upgrade' ;;
        "upgrade:brew bundle") echo '_install_new_formulae' ;;
        upgrade:casks) echo '_install_new_casks' ;;
        upgrade:fc-cache) echo 'fc-cache -f' ;;
        upgrade:rustup) echo '.cargo/bin/rustup update' ;;
        "upgrade:self-updating casks") echo '_upgrade_self_updating_casks upgrade ' ;;
        "upgrade:vim plugins") echo 'PlugUpdate' ;;
        "upgrade:tmux plugins") echo 'sync_tmux_plugins' ;;
        "upgrade:mise hook-env") echo 'mise hook-env' ;;
        "upgrade-ai-tools:desktop apps") echo '_upgrade_self_updating_casks upgrade-ai-tools claude ' ;;
        "upgrade-ai-tools:codex cask") echo '_upgrade_self_updating_casks upgrade-ai-tools codex ' ;;
        *) stage_doc "$1" "$2" ;;
    esac
}
for fn in upgrade upgrade-ai-tools; do
    doc=README.md
    [ "$fn" == upgrade ] || doc=ai_tools/README.md
    section "$REPO_DIR/$doc" "## Updating" > "$tmp/updating"
    awk -v fn="${fn//-/_}() {" '$0 == fn { on = 1 } on { print } on && /^\}/ { exit }' "$REPO_DIR/scripts/upgrade.sh" > "$tmp/body"
    stages="$({ grep -oE 'failed\+=\([^)]+\)|_stage_failed ("[^"]+"|[^ "]+)' "$tmp/body" || true; } |
        sed -E 's/^failed\+=\(//; s/\)$//; s/^_stage_failed //; s/^"//; s/"$//' | awk '!seen[$0]++')"
    [ -n "$stages" ] || fail "Couldn't read $fn's stages from scripts/upgrade.sh"
    : > "$tmp/stage-texts"
    while IFS= read -r stage; do
        [ -n "$stage" ] || continue
        if ! text="$(stage_doc "$fn" "$stage")"; then
            fail "$fn has a stage, $stage, that scripts/check-docs.sh doesn't map to its docs"
            continue
        fi
        printf '%s\n' "$text" >> "$tmp/stage-texts"
        grep -qF -- "$text" "$tmp/updating" || fail "$doc Updating doesn't describe $fn's $stage stage: $text"
        code="$(stage_code "$fn" "$stage")"
        grep -qF -- "$code" "$tmp/body" || fail "$fn's $stage stage doesn't run what $doc Updating says: $code"
    done <<< "$stages"
    # The first list's items, each with its continuation lines
    awk '/^- / { item = 1 } item && !/^(- |  )/ { exit } item' "$tmp/updating" |
        awk '/^- / && NR > 1 { print "" } { printf "%s ", $0 } END { print "" }' > "$tmp/items"
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        grep -qFf "$tmp/stage-texts" <<< "$item" ||
            fail "$doc Updating has an item that describes none of $fn's stages: ${item:0:60}"
    done < "$tmp/items"
done

# The manual-steps scripts print these sections with print_doc_section, which fails when one is
# missing or empty
for doc in README.md ai_tools/README.md; do
    for os in macOS Ubuntu; do
        md_section "$REPO_DIR/$doc" "## Manual steps" "### $os" > /dev/null ||
            fail "$doc has no \"### $os\" under \"## Manual steps\", which the manual-steps scripts print"
    done
done

for doc in README.md ai_tools/README.md; do
    while IFS= read -r problem; do
        fail "$doc: $problem"
    done < <(broken_links "$REPO_DIR/$doc")
done

[ "$errors" -eq 0 ]
