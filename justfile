# Run every recipe line with -e, so a loop fails when any iteration does, not only the last, and
# with pipefail, so a failing command before a pipe, such as git ls-files in check, fails it too.
# Arguments reach a recipe quoted, or as "$@" with [positional-arguments], so the shell never runs
# them as code.
set shell := ["bash", "-euo", "pipefail", "-c"]

# List recipes
default:
    @just --list

# Lint shell scripts (including */bin/*), and check they use no bash 4 features, since they target /bin/bash 3.2, and on macOS that its /bin/bash 3.2 parses them, syntax-check zsh files, check the docs against the code they describe, check the skills' metadata, links, and paths, and check the keys the claude-code step writes against the known Claude Code settings
check:
    #!/bin/bash
    set -euo pipefail
    # The shell scripts, including */bin/*, NUL-separated, listed once for shellcheck, the bash 4
    # grep, and bash -n. A file deleted but not yet staged is still listed by git, so it's skipped.
    files="$(mktemp)"
    trap 'rm -f "$files"' EXIT
    git ls-files -z --cached --others --exclude-standard '*.sh' '*/bin/*' | while IFS= read -r -d '' f; do [ ! -f "$f" ] || printf '%s\0' "$f"; done > "$files"
    xargs -0 -n 8 -P "$(getconf _NPROCESSORS_ONLN)" shellcheck < "$files"
    bad="$(xargs -0 grep -nE '\b(mapfile|readarray|coproc)\b|\b(declare|local|typeset) +-[a-zA-Z]*[An]|\[\[ -v |\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^|,)|\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAaUuLK]\}|&>>|;;&|\|&|\bwait +-n\b|\bEPOCH(SECONDS|REALTIME)\b' /dev/null < "$files")" || true
    [ -z "$bad" ] || { printf '%s\n' "$bad" "These need bash 4; the scripts target /bin/bash 3.2." >&2; exit 1; }
    [ "$(uname -s)" != Darwin ] || xargs -0 -n 1 /bin/bash -n < "$files"
    for f in zsh/*.zsh; do zsh -n "$f"; done
    bash scripts/check-docs.sh
    bash scripts/check-skills.sh
    bash scripts/check-claude-keys.sh > /dev/null

# Run the tests in tests/: every one, or only the named ones (e.g. just test vim), in parallel. The scripts target /bin/bash 3.2 on macOS, so the tests run under it.
[positional-arguments]
test *tests:
    /bin/bash tests/run.sh "$@"

# Run setup.sh and ai_tools/setup.sh in a throwaway OrbStack Ubuntu machine, restart it, check --status and the T3 Code service, then delete it. Needs OrbStack.
test-ubuntu:
    bash scripts/test-ubuntu.sh

# Move the pinned vim and tmux plugins, and the vendored vim-plug, to their latest versions in this repo, for review
bump-plugins:
    bash scripts/bump-plugins.sh

# Run setup.sh: every step, or only the named ones (e.g. just setup git zsh)
[positional-arguments]
setup *steps:
    bash setup.sh "$@"

# Run ai_tools/setup.sh: every step, or only the named ones (e.g. just setup-ai codex)
[positional-arguments]
setup-ai *steps:
    bash ai_tools/setup.sh "$@"

# Report what every step of setup.sh and ai_tools/setup.sh has set up, changing nothing. With quick, skip the slowest checks (--quick). Exits 1 when a step failed, 3 when one needs attention.
status mode="":
    @case {{quote(mode)}} in "") f="" ;; quick) f=--quick ;; *) echo "Usage: just status [quick]" >&2; exit 2 ;; esac; a=0; bash setup.sh --status $f || a=$?; echo; b=0; bash ai_tools/setup.sh --status $f || b=$?; for s in $a $b; do [ $s -eq 0 ] || [ $s -eq 3 ] || exit 1; done; [ $a -ne 3 ] && [ $b -ne 3 ] || exit 3

# Sign git commits on this machine with an SSH key
git-signing:
    bash git/setup-signing.sh

# Turn on Touch ID for sudo on macOS, in /etc/pam.d/sudo_local
touch-id:
    bash macos/setup-touch-id-sudo.sh

# On Ubuntu, ask for a ntfy topic, or its URL, and push the disk warnings, UPS events, daily health alert, and boot notice to it, with a test push, or with test, run the disk warning and UPS hooks with test events
alerts mode="":
    @case {{quote(mode)}} in "") bash ubuntu/setup-alerts.sh ;; test) bash ubuntu/setup-alerts.sh --test ;; *) echo "Usage: just alerts [test]" >&2; exit 2 ;; esac

# Add a block for a host you SSH to, such as the Ubuntu machine, to ~/.ssh/config (e.g. just ssh-host box box.tail1234.ts.net)
ssh-host alias hostname="":
    bash ssh/add-host.sh {{quote(alias)}} {{quote(hostname)}}
