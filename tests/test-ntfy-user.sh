#!/bin/bash
# shellcheck disable=SC2329 # the script calls the functions this test replaces

# just ntfy-user (ntfy/setup-user.sh): the two users, machine's access and three tokens made once, a
# second run that runs nothing and prints the same tokens, the desktop's client config at mode 600,
# a rotation that replaces one token, a password change that signs out only your sessions, and no
# password or token ever passed as an argument or in the environment.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script ntfy/setup-user.sh
as_os ubuntu
sandbox_paths ntfy/setup-user.sh 'ntfy/lib/*.sh' ubuntu/lib/paths.sh
mkdir -p "$(dirname "$NTFY_CONFIG")"
touch "$NTFY_CONFIG"
# sudo -v only caches credentials
stub_sudo_exec '[ "${1:-}" != -v ] || exit 0'
stub_systemctl_units "$SANDBOX/units"
replace_fn ntfy_healthy 'return 0'
replace_fn is_interactive 'return 0'
replace_fn ntfy_public_url 'echo https://box.example.ts.net:8443'
stub_at "$SANDBOX/setup-alerts.sh" 'echo "just alerts ran"'
# shellcheck disable=SC2034 # the script reads it
SETUP_ALERTS="$SANDBOX/setup-alerts.sh"

# A fake ntfy keeping users, grants, and tokens under $SANDBOX/db, printing ntfy v2.34.0's formats.
# Passwords come on stdin; one in the environment would override them, so that's recorded as a leak.
mkdir -p "$SANDBOX/db"
stub ntfy 'db="$SANDBOX/db"
[ -z "${NTFY_PASSWORD+x}${NTFY_PASSWORD_HASH+x}" ] || echo "NTFY_PASSWORD in the environment" >> "$db/leaks"
cmd="$1"
shift
[ "$1" == --config ] || { echo "no --config before the subcommand" >&2; exit 1; }
shift 2
exists() { [ -e "$db/user-$1" ]; }
missing() { echo "user $1 does not exist" >&2; exit 1; }
case "$cmd ${1:-}" in
    "user add")
        shift
        role=user
        [ "$1" != --role=admin ] || { role=admin; shift; }
        exists "$1" && { echo "user $1 already exists" >&2; exit 1; }
        IFS= read -r p1; IFS= read -r p2
        [ -n "$p1" ] && [ "$p1" == "$p2" ] || { echo "passwords do not match" >&2; exit 1; }
        echo "$role" > "$db/user-$1"
        echo "user $1 added with role $role" ;;
    "user change-pass")
        exists "$2" || missing "$2"
        IFS= read -r p1; IFS= read -r p2
        echo "changed $2" >> "$db/changes" ;;
    "token list")
        exists "$2" || missing "$2"
        if [ -s "$db/tokens-$2" ]; then
            echo "user $2"
            while IFS=" " read -r token label; do
                echo "- $token ($label), never expires, accessed from 0.0.0.0 at 30 Oct 26 12:00 UTC"
            done < "$db/tokens-$2"
        else
            echo "user $2 has no access tokens"
        fi ;;
    "token add")
        label="${2#--label=}"
        exists "$3" || missing "$3"
        n=$(( $(cat "$db/seq" 2> /dev/null || echo 0) + 1 ))
        echo "$n" > "$db/seq"
        token="tk_$(printf "%029d" "$n")"
        echo "$token $label" >> "$db/tokens-$3"
        echo "token $token created for user $3, never expires" ;;
    "token remove")
        grep -v "^$3 " "$db/tokens-$2" > "$db/t" || true
        mv "$db/t" "$db/tokens-$2"
        echo "token $3 for user $2 removed" ;;
    access*)
        exists "$1" || missing "$1"
        if [ $# -eq 3 ]; then
            echo "- $3 access to topic $2" | sed "s/- rw /- read-write /" >> "$db/grants-$1"
            echo "granted $3 access to topic $2"
            exit 0
        fi
        echo "user $1 (role: $(cat "$db/user-$1"), tier: none)"
        if [ "$(cat "$db/user-$1")" == admin ]; then echo "- read-write access to all topics (admin role)"
        elif [ -s "$db/grants-$1" ]; then cat "$db/grants-$1"
        else echo "- no topic-specific permissions"; fi ;;
    *) echo "unexpected ntfy $cmd $*" >&2; exit 1 ;;
esac'
CLIENT="$HOME/.config/ntfy/client.yml"
me="$(id -un)"

assert_exit 2 main extra
assert_exit 2 main --rotate
# Your password is typed twice at ntfy's own prompt, here on stdin
assert_exit 0 main <<< $'my password\nmy password'
assert_eq admin "$(cat "$SANDBOX/db/user-$me")" "your user's role"
assert_eq user "$(cat "$SANDBOX/db/user-machine")" "machine's role"
assert_eq "- read-write access to topic *" "$(cat "$SANDBOX/db/grants-machine")" "machine's access"
assert_eq "desktop macbook web-service" "$(awk '{ print $2 }' "$SANDBOX/db/tokens-machine" | tr '\n' ' ' | sed 's/ $//')" \
    "machine's token labels"
desktop="$(awk '$2 == "desktop" { print $1 }' "$SANDBOX/db/tokens-machine")"
macbook="$(awk '$2 == "macbook" { print $1 }' "$SANDBOX/db/tokens-machine")"
web="$(awk '$2 == "web-service" { print $1 }' "$SANDBOX/db/tokens-machine")"
assert_eq 600 "$(file_mode "$CLIENT")" "the client config's mode"
assert_file_contains "$CLIENT" "default-host: http://127.0.0.1:2586"
assert_file_contains "$CLIENT" "default-token: $desktop"
assert_file_contains "$CLIENT" "  - topic: http://127.0.0.1:2586/alerts"
assert_file_contains "$CLIENT" "  - topic: http://127.0.0.1:2586/agenda"
assert_file_contains "$CLIENT" "default-command: '/bin/bash \"\$HOME/.local/share/dotfiles/ntfy/notify.sh\"'"
assert_contains "$RUN_OUTPUT" "just alerts ran"
assert_contains "$RUN_OUTPUT" "$macbook"
assert_contains "$RUN_OUTPUT" "$web"
assert_contains "$RUN_OUTPUT" "https://box.example.ts.net:8443/agenda"
assert_not_contains "$RUN_OUTPUT" "$desktop"
[ ! -e "$SANDBOX/db/leaks" ] || fail "a password went through the environment: $(cat "$SANDBOX/db/leaks")"
if grep -v '^ntfy token remove' "$STUB_LOG" | grep -qE "tk_[0-9]{29}|my password"; then
    fail "a token or password was an argument"
fi

# A second run changes nothing, and prints the same tokens. Its sudo runs only ntfy's reads,
# which assert_idempotent would count as changes, so the files are compared instead.
state() { (cd "$SANDBOX" && cksum db/* "$CLIENT"); }
before="$(state)"
assert_exit 0 main < /dev/null
assert_eq "$before" "$(state)" "ntfy's users, tokens, and the client config after a second run"
assert_contains "$RUN_OUTPUT" "$macbook"
assert_contains "$RUN_OUTPUT" "$web"
if grep -qE '^ntfy (user add|access machine \*|token add)' "$STUB_LOG"; then
    fail "the second run changed ntfy's users: $(grep -E '^ntfy (user add|access|token add)' "$STUB_LOG")"
fi

# A grant from before is reported, not removed
echo "- read-only access to topic old" >> "$SANDBOX/db/grants-machine"
assert_exit 0 main < /dev/null
assert_contains "$RUN_OUTPUT" "machine also has, from before:"
assert_contains "$RUN_OUTPUT" "- read-only access to topic old"

# A rotation replaces one token; the desktop's goes to the client config and the alerts again
assert_exit 0 main --rotate macbook
assert_file_not_contains "$SANDBOX/db/tokens-machine" "$macbook"
assert_file_contains "$SANDBOX/db/tokens-machine" "$desktop desktop"
assert_file_contains "$SANDBOX/db/tokens-machine" "$web web-service"
assert_contains "$RUN_OUTPUT" "Run just ntfy-device on the Mac and paste the new token"
assert_not_contains "$RUN_OUTPUT" "just alerts ran"
assert_exit 0 main --rotate desktop
assert_file_not_contains "$SANDBOX/db/tokens-machine" "$desktop"
new_desktop="$(awk '$2 == "desktop" { print $1 }' "$SANDBOX/db/tokens-machine")"
assert_file_contains "$CLIENT" "default-token: $new_desktop"
assert_contains "$RUN_OUTPUT" "just alerts ran"
assert_exit 2 main --rotate nonsense
assert_contains "$RUN_OUTPUT" "The labels are: desktop macbook web-service."

# A password change signs out your web sessions, and leaves machine's tokens
echo "tk_$(printf '%029d' 900) web-session" > "$SANDBOX/db/tokens-$me"
before="$(cat "$SANDBOX/db/tokens-machine")"
assert_exit 0 main --change-pass <<< $'new password\nnew password'
assert_file_contains "$SANDBOX/db/changes" "changed $me"
assert_eq "" "$(cat "$SANDBOX/db/tokens-$me")" "your tokens after a password change"
assert_eq "$before" "$(cat "$SANDBOX/db/tokens-machine")" "machine's tokens after a password change"
assert_contains "$RUN_OUTPUT" "Update the password in the Android app"

# The server comes first, and nothing runs without a terminal
replace_fn ntfy_healthy 'return 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run bash setup.sh ntfy first."
assert_file_not_contains "$STUB_LOG" "ntfy"
replace_fn ntfy_healthy 'return 0'
replace_fn is_interactive 'return 1'
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Run just ntfy-user from a terminal"
assert_file_not_contains "$STUB_LOG" "sudo"
as_os macos
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "On a Mac, run just ntfy-device."

test_done
