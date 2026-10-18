#!/bin/bash
set -euo pipefail

# regex_escape makes a string, such as an app's name or path, match itself literally in an
# extended regex, as pgrep -x and grep -E read it, and nothing else.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
load_script lib/common.sh

for s in 'Logi Options+' '/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code' 'a.b*c?d[e]f{1}|g^h$i\j'; do
    pattern="$(regex_escape "$s")"
    printf '%s\n' "$s" | grep -qxE -- "$pattern" || fail "'$pattern' doesn't match '$s'"
done
# A dot or plus no longer matches what it would as a regex
! printf '%s\n' 'Logi Optionss' | grep -qxE -- "$(regex_escape 'Logi Options+')" ||
    fail "the escaped + still repeats"
! printf '%s\n' 'aXb' | grep -qxE -- "$(regex_escape 'a.b')" || fail "the escaped . still matches any character"
test_done
