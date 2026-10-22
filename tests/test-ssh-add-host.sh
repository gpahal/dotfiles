#!/bin/bash
set -euo pipefail

# ssh/add-host.sh: one Host block per alias, above any catch-all so its settings don't win.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v ssh &>/dev/null || skip "ssh isn't installed"
add_host() {
    bash "$REPO_DIR/ssh/add-host.sh" "$@"
}
config="$HOME/.ssh/config"

# The block's ControlMaster socket lives in ~/.ssh, so only you may use it
mkdir -m 755 "$HOME/.ssh"
assert_exit 0 add_host box box.example.ts.net
assert_eq drwx------ "$(/bin/ls -ld "$HOME/.ssh" | cut -c1-10)" "the mode of ~/.ssh"
assert_eq -rw------- "$(/bin/ls -l "$config" | cut -c1-10)" "the config's mode"
assert_contains "$RUN_OUTPUT" "ssh -O exit box closes it"
assert_file_contains "$config" "Host box"
assert_file_contains "$config" "  HostName box.example.ts.net"
cp "$config" "$SANDBOX/config-before"
assert_exit 0 add_host box box.example.ts.net
assert_contains "$RUN_OUTPUT" "already has a block for box"
cmp -s "$SANDBOX/config-before" "$config" || fail "a second run changed the config"

for bad in "my box" "*" "box#1" "$(printf 'a\nb')"; do
    assert_exit 2 add_host "$bad"
    assert_contains "$RUN_OUTPUT" "can't contain"
    assert_exit 2 add_host ok "$bad"
done
cmp -s "$SANDBOX/config-before" "$config" || fail "a rejected alias changed the config"

# ssh matches Host patterns case-sensitively
assert_exit 0 add_host Box
assert_file_contains "$config" "Host Box"
assert_file_contains "$config" "Host box"

cat > "$config" << 'EOF'
Host github.com
  HostName github.com

# Every host
Host *
  ServerAliveInterval 60
EOF
assert_exit 0 add_host box2
assert_eq "github.com box2 *" "$(awk '$1 == "Host" { printf "%s%s", sep, $2; sep = " " }' "$config")" \
    "the Host lines' order"
expected="Host github.com
  HostName github.com

Host box2
  HostName box2
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 1m

# Every host
Host *
  ServerAliveInterval 60"
assert_eq "$expected" "$(cat "$config")" "the config with a Host * block"
assert_exit 0 ssh -G -F "$config" box2
assert_contains "$RUN_OUTPUT" "serveraliveinterval 30"

for star in 'Host * !bastion' 'Host foo *' 'Host "*"' "$(printf 'Host *\r')" 'host=*'; do
    printf 'Host github.com\n  HostName github.com\n\n%s\n  ServerAliveInterval 60\n' "$star" > "$config"
    assert_exit 0 add_host box3
    assert_eq "github.com box3" "$(awk '$1 == "Host" && NR < 9 { printf "%s%s", sep, $2; sep = " " }' "$config")" \
        "the Host lines above $star"
    assert_eq "$star" "$(sed -n 11p "$config")" "the catch-all after the block"
done

# Match all, and Host * with an included file, are catch-alls too
printf 'Host *\n  ServerAliveInterval 6\n' > "$SANDBOX/star.conf"
# ssh refuses an included file others can write
chmod 644 "$SANDBOX/star.conf"
for fixture in "Host other\n  User other\n\nHost *\n  Include $SANDBOX/star.conf" \
    "Host other\n  User other\n\nMatch all\n  ServerAliveInterval 5"; do
    # shellcheck disable=SC2059 # the fixtures hold \n
    printf "$fixture\n" > "$config"
    other_before="$(ssh -G -F "$config" other 2>&1)"
    assert_exit 0 add_host box5 box5.example.ts.net
    assert_exit 0 ssh -G -F "$config" box5
    assert_contains "$RUN_OUTPUT" "serveraliveinterval 30"
    assert_contains "$RUN_OUTPUT" "hostname box5.example.ts.net"
    assert_eq "$other_before" "$(ssh -G -F "$config" other 2>&1)" "another host with: $fixture"
    cp "$config" "$SANDBOX/config-before"
    assert_exit 0 add_host box5 box5.example.ts.net
    cmp -s "$SANDBOX/config-before" "$config" || fail "a second run changed the config with: $fixture"
done

for existing in 'Host=box7' 'Host = box7' 'Host "box7"' 'host box7'; do
    printf '%s\n  User me\n\nHost *\n  ServerAliveInterval 60\n' "$existing" > "$config"
    cp "$config" "$SANDBOX/config-before"
    assert_exit 0 add_host box7
    assert_contains "$RUN_OUTPUT" "already has a block for box7"
    cmp -s "$SANDBOX/config-before" "$config" || fail "add-host added a block next to: $existing"
    assert_exit 0 ssh -G -F "$config" box7
    assert_contains "$RUN_OUTPUT" "user me"
done

if [ "$(id -u)" -ne 0 ]; then
    : > "$config"
    chmod 444 "$config"
    assert_exit 1 add_host box8
    assert_not_contains "$RUN_OUTPUT" "Added"
    chmod 600 "$config"
fi

printf 'Host *\n  ServerAliveInterval 60\n' > "$SANDBOX/real-config"
rm "$config"
ln -s "$SANDBOX/real-config" "$config"
assert_exit 0 add_host box4
[ -L "$config" ] || fail "add-host replaced the symlinked config"
assert_eq "Host box4" "$(head -n 1 "$SANDBOX/real-config")" "the first line of the linked config"
assert_file_contains "$SANDBOX/real-config" "Host *"
test_done
