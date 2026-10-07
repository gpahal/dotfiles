# List recipes
default:
    @just --list

# Lint shell scripts (including */bin/*, excluding skill templates) and syntax-check zsh files
check:
    git ls-files --cached --others --exclude-standard '*.sh' '*/bin/*' ':!:ai_tools/skills/**/*template*' | xargs shellcheck
    for f in zsh/*.zsh; do zsh -n "$f"; done

# Run setup.sh: every step, or only the named ones (e.g. just setup git zsh)
setup *steps:
    bash setup.sh {{steps}}

# Run ai_tools/setup.sh: every step, or only the named ones (e.g. just setup-ai codex)
setup-ai *steps:
    bash ai_tools/setup.sh {{steps}}

# Sign git commits on this machine with an SSH key
git-signing:
    bash git/setup-signing.sh
