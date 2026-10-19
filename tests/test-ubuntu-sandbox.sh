#!/bin/bash
set -euo pipefail

# ubuntu_sandbox_paths ignores system paths inside the repo, so tests pass from a /var checkout.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
COPY="$(mktemp -d /var/tmp/dotfiles-test.XXXXXX)"
# shellcheck disable=SC2016 # expanded when the trap runs
on_exit 'rm -rf "$COPY"'
cp -R "$REPO_DIR/lib" "$REPO_DIR/tests" "$REPO_DIR/ubuntu" "$COPY/"
cat > "$COPY/tests/test-var-checkout.sh" << 'TEST'
#!/bin/bash
set -euo pipefail
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
source "$TESTS_DIR/ubuntu-sandbox.sh"
setup_sandbox
load_script ubuntu/install.sh
ubuntu_sandbox_paths
# A system path outside the repo still fails it
[ "${1:-}" != system ] || { SMARTD_HOOK=/var/lib/x; _ubuntu_system_paths_left; }
test_done
TEST
assert_exit 0 "$BASH" "$COPY/tests/test-var-checkout.sh"
assert_not_contains "$RUN_OUTPUT" "left these"
assert_exit 1 "$BASH" "$COPY/tests/test-var-checkout.sh" system
assert_contains "$RUN_OUTPUT" "ubuntu_sandbox_paths left these on the real machine: SMARTD_HOOK=/var/lib/x"
test_done
