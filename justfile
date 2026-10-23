# just's default sh -cu ignores a failure before ; or | within a recipe line.
set shell := ["bash", "-euo", "pipefail", "-c"]

# List recipes
default:
    @just --list

# Lint scripts, check bash 3.2 compatibility, docs, skills, and Claude settings keys
check:
    #!/bin/bash
    set -euo pipefail
    tmp="$(mktemp -d)"
    trap 'kill $(jobs -p) 2> /dev/null || true; rm -rf "$tmp"' EXIT
    # The docs, skills, and keys checks run while shellcheck does, and print after it
    bash scripts/check-docs.sh > "$tmp/docs" 2>&1 &
    docs=$!
    bash scripts/check-skills.sh > "$tmp/skills" 2>&1 &
    skills=$!
    bash scripts/check-claude-keys.sh > /dev/null 2> "$tmp/keys" &
    keys=$!
    # Scripts by name, or by a bash shebang. git still lists a deleted but unstaged file, so skip it.
    files="$tmp/files"
    git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        case "$f" in
            *.sh | */bin/*) ;;
            *) head -n 1 "$f" | grep -qE '^#!(/usr)?/bin/(env +)?bash\b' || continue ;;
        esac
        printf '%s\0' "$f"
    done > "$files"
    # One job per physical core: more is slower
    if [ "$(uname -s)" == Darwin ]; then
        cores="$(sysctl -n hw.physicalcpu 2> /dev/null || true)"
    else
        cores="$( (lscpu -p=socket,core | grep -v '^#' | sort -u | wc -l | tr -d ' ') 2> /dev/null || true)"
    fi
    case "$cores" in '' | 0 | *[!0-9]*) cores="$(getconf _NPROCESSORS_ONLN)" ;; esac
    xargs -0 -n 8 -P "$cores" shellcheck < "$files"
    bad="$(xargs -0 grep -nE '\b(mapfile|readarray|coproc)\b|\b(declare|local|typeset) +-[a-zA-Z]*[Ang]|\[\[ -v |(\btest|\[) +-v |\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^|,)|\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAaUuLK]\}|&>>|;;&|(^|[^;]);&([[:space:]]|$)|\|&|\bwait +-n\b|\bEPOCH(SECONDS|REALTIME)\b|\$\{?BASHPID\b|\bprintf .*%\([^)]*\)T|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]|\bshopt .*\b(globstar|lastpipe)\b' /dev/null < "$files")" || true
    [ -z "$bad" ] || { printf '%s\n' "$bad" "These need bash 4; the scripts target /bin/bash 3.2." >&2; exit 1; }
    [ "$(uname -s)" != Darwin ] || xargs -0 -n 1 /bin/bash -n < "$files"
    for f in zsh/*.zsh; do zsh -n "$f"; done
    failed=0
    for check in docs skills keys; do
        wait "${!check}" || failed=1
        cat "$tmp/$check" >&2
    done
    exit "$failed"

# Run all tests, or the named ones, under /bin/bash (3.2 on macOS)
[positional-arguments]
test *tests:
    /bin/bash tests/run.sh "$@"

# Run a full setup in a throwaway OrbStack Ubuntu machine
test-ubuntu:
    bash scripts/test-ubuntu.sh

# Bump pinned vim and tmux plugins and vim-plug
bump-plugins:
    bash scripts/bump-plugins.sh

# Copy changed installed configs back into the repo (dry-run: list only)
copy-back mode="":
    @case {{quote(mode)}} in "") bash scripts/copy-back.sh ;; dry-run) bash scripts/copy-back.sh --dry-run ;; *) echo "Usage: just copy-back [dry-run]" >&2; exit 2 ;; esac

# List build and download caches with their sizes, then clear them (dry-run: list only)
clean-caches mode="":
    @case {{quote(mode)}} in "") bash scripts/clean-caches.sh ;; dry-run) bash scripts/clean-caches.sh --dry-run ;; *) echo "Usage: just clean-caches [dry-run]" >&2; exit 2 ;; esac

# Run setup.sh: all steps, or the named ones
[positional-arguments]
setup *steps:
    bash setup.sh "$@"

# Run ai_tools/setup.sh: all steps, or the named ones
[positional-arguments]
setup-ai *steps:
    bash ai_tools/setup.sh "$@"

# Report setup status; exits 1 on failure, 3 on attention
status:
    #!/bin/bash
    set -uo pipefail
    # The AI report runs beside setup's, into files, and prints after it
    dir="$(mktemp -d)" || exit 1
    bash ai_tools/setup.sh --status > "$dir/out" 2> "$dir/err" &
    ai=$!
    # A background job ignores SIGINT, so stop it, then die of the signal as a runner does
    stop() { kill "$ai" 2> /dev/null; wait "$ai"; rm -rf "$dir"; trap - "$1"; kill -s "$1" $$; }
    trap 'stop INT' INT
    trap 'stop TERM' TERM
    trap 'stop HUP' HUP
    a=0; bash setup.sh --status || a=$?
    b=0; wait "$ai" || b=$?
    trap - INT TERM HUP
    echo
    cat "$dir/out"
    cat "$dir/err" >&2
    rm -rf "$dir"
    for s in $a $b; do [ $s -eq 0 ] || [ $s -eq 3 ] || exit 1; done
    [ $a -ne 3 ] && [ $b -ne 3 ] || exit 3

# Sign git commits and tags with an SSH key
git-signing:
    bash git/setup-signing.sh

# Turn on Touch ID for sudo on macOS
touch-id:
    bash macos/setup-touch-id-sudo.sh

# Point the monitor at the machine the USB switch serves (no arguments: list devices and codes)
[positional-arguments]
monitor-input *args:
    bash monitor-input/setup.sh "$@"

# Set up Ubuntu ntfy health alerts (test: fire test events)
alerts mode="":
    @case {{quote(mode)}} in "") bash ubuntu/setup-alerts.sh ;; test) bash ubuntu/setup-alerts.sh --test ;; *) echo "Usage: just alerts [test]" >&2; exit 2 ;; esac

# Add an SSH host block to ~/.ssh/config
ssh-host alias hostname="":
    bash ssh/add-host.sh {{quote(alias)}} {{quote(hostname)}}
