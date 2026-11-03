#!/bin/bash
# shellcheck disable=SC2329

# Solaar from its team's pinned PPA, and the MX Master 4's settings and rules for it.
# test-apt-sources.sh covers add_apt_repo's failures.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_script logitech/install.sh
sandbox_paths logitech/install.sh
as_os ubuntu
# The settings edit needs mikefarah's yq, which CI installs
yq --version 2>/dev/null | grep -q mikefarah || skip "mikefarah's yq isn't installed"
# Solaar isn't running
stub pgrep 'exit 1'

OS_RELEASE="$SANDBOX/os-release"
echo "VERSION_CODENAME=resolute" > "$OS_RELEASE"

# The version file holds the installed Solaar's; the PPA's is installed once its source is there
stub dpkg-query 'v="$SANDBOX/solaar-version"
[ -e "$v" ] || exit 1
case "$*" in
    *Status*) printf "install ok installed" ;;
    *Version*) printf "%s" "$(cat "$v")" ;;
esac'
stub apt-get 'if [ "${*: -1}" == solaar ]; then
    if [ -e "$SANDBOX/etc/apt/sources.list.d/solaar.sources" ]; then
        echo "1.1.20+202607061356~ubuntu26.04.1" > "$SANDBOX/solaar-version"
    else
        echo "1.1.19-1" > "$SANDBOX/solaar-version"
    fi
fi'
stub_sudo_exec
# fetch gives the key the step pins
stub_fetch
stub_gpg_fpr "$SOLAAR_KEY_FPR"
stub_http_status
mkdir -p "$(dirname "$SOLAAR_SOURCES")"

assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Only Solaar taken from the Solaar team's PPA"
assert_contains "$RUN_OUTPUT" "missing    The Solaar team's PPA's apt source ($SOLAAR_SOURCES): missing"
assert_contains "$RUN_OUTPUT" "missing    Solaar 1.1.20 or later; older ones fail"

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Install Solaar from the Solaar team's PPA"
assert_file_not_contains "$STUB_LOG" "apt-get"
[ ! -e "$SOLAAR_PIN" ] && [ ! -e "$SOLAAR_SOURCES" ] || fail "the PPA was added though confirm declined"

# Without the pin, apt would take any package from the PPA, so a failed pin stops it being added or used
answer yes
mkdir -p "$SOLAAR_PIN"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$SOLAAR_PIN isn't in place, so the Solaar team's PPA wasn't added."
[ ! -e "$SOLAAR_SOURCES" ] || fail "the PPA was added without its pin"
assert_eq "1.1.19-1" "$(cat "$SANDBOX/solaar-version")" "the Solaar installed without the PPA"
rm "$SANDBOX/solaar-version"
solaar_sources > "$SOLAAR_SOURCES"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "$SOLAAR_PIN isn't in place, so the Solaar team's PPA isn't used."
assert_file_not_contains "$STUB_LOG" "install -y solaar"
rm "$SOLAAR_SOURCES"
rmdir "$SOLAAR_PIN"

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Installed Solaar 1.1.20."
assert_file_contains "$STUB_LOG" "install -y solaar"
assert_exit 0 main --status

assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Solaar 1.1.20 is already installed."
assert_file_not_contains "$STUB_LOG" "sudo"
# Once the PPA is added, neither gpg nor curl is needed
hide gpg curl
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Solaar 1.1.20 is already installed."
stub_gpg_fpr "$SOLAAR_KEY_FPR"
stub_http_status

# Ubuntu's older Solaar is upgraded from the PPA
echo "1.1.19-1" > "$SANDBOX/solaar-version"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    Solaar 1.1.20 or later"
assert_exit 0 main
assert_eq "1.1.20+202607061356~ubuntu26.04.1" "$(cat "$SANDBOX/solaar-version")" "the version after upgrading"

# Before the PPA publishes for a new release, Ubuntu's Solaar stands in, and the next run adds it
echo "VERSION_CODENAME=stonking" > "$OS_RELEASE"
stub_http_status 404
rm -f "$SOLAAR_SOURCES" "$SANDBOX/solaar-version"
# Ubuntu's Solaar needs no gpg
hide gpg
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "hasn't published packages for Ubuntu stonking yet"
assert_eq "1.1.19-1" "$(cat "$SANDBOX/solaar-version")" "the version without the PPA"
[ ! -e "$SOLAAR_SOURCES" ] || fail "the PPA was added before it published for this release"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "sudo"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "hasn't published packages for Ubuntu stonking yet"

# --- The MX Master 4's settings and rules ---
answer no
mouse() {
    yq -o json -I=0 "$1" "$SOLAAR_CONFIG"
}

# Without a config, an entry any MX Master 4 matches, after the version Solaar reads first
rm -rf "$SOLAAR_CONFIG_DIR"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Set the MX Master 4's settings in ~/.config/solaar/config.yaml. Open Solaar to apply them."
assert_eq '["1.1.19","B04200000000",1000,1,2]' \
    "$(mouse '[.[0], .[1]._modelId, .[1].dpi, .[1]["divert-keys"][195], .[1]["divert-keys"][416]]')"
# Solaar's keys are integers, which a trip through JSON would make strings
assert_eq '!!int' "$(yq '.[1]["divert-keys"] | keys | .[0] | tag' "$SOLAAR_CONFIG")" "a divert-keys key's type"
assert_not_contains "$(cat "$SOLAAR_CONFIG")" "#" "the config, which shouldn't get the repo's comments"
cmp -s "$MOUSE_RULES" "$SOLAAR_RULES" || fail "the rules weren't copied"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "ok         The MX Master 4's settings in ~/.config/solaar/config.yaml"
assert_contains "$RUN_OUTPUT" "ok         Solaar rules for the MX Master 4's buttons (~/.config/solaar/rules.yaml)"

# Into each MX Master 4 entry Solaar wrote, keeping its other keys and other devices
cat > "$SOLAAR_CONFIG" <<'YAML'
- 1.1.20+202607061356
- _NAME: MX Master 4
  _absent: [hi-res-scroll, onboard_profiles]
  _modelId: B04200000000
  _sensitive: {hires-scroll-mode: ignore, hires-smooth-invert: false}
  _serial: 5C610A0E
  _wpid: B042
  divert-keys: {82: 0, 195: 0, 416: 0}
  dpi: 1600
- _NAME: MX Master 4
  _modelId: B04200000000
  _unitId: 0A0E5C61
  dpi: 800
- _NAME: MX Keys S
  _modelId: B37800000000
  backlight: true
YAML
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The MX Master 4's settings in ~/.config/solaar/config.yaml"
assert_idempotent main
assert_eq '[1000,1000]' "$(mouse '[.[1].dpi, .[2].dpi]')" "the MX Master 4 entries' DPI"
assert_eq '{"82":0,"195":1,"416":2}' "$(mouse '.[1]["divert-keys"]')" "the divert-keys Solaar had"
assert_eq '{"hires-scroll-mode":"ignore","hires-smooth-invert":true}' "$(mouse '.[1]._sensitive')"
assert_eq '["hi-res-scroll","onboard_profiles"]' "$(mouse '.[1]._absent')"
assert_eq '{"_NAME":"MX Keys S","_modelId":"B37800000000","backlight":true}' "$(mouse '.[3]')" "another device's entry"
assert_eq 4 "$(mouse 'length')" "the entries"

# While Solaar runs, which would write its own copy over an edit, the config is left alone, and
# rules are copied for its next start
stub pgrep 'exit 0'
yq -i '.[1].dpi = 1600' "$SOLAAR_CONFIG"
echo "rules of your own" > "$SOLAAR_RULES"
snapshot "$SOLAAR_CONFIG"
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "Solaar is running and would overwrite ~/.config/solaar/config.yaml"
assert_contains "$RUN_OUTPUT" "Solaar reads them when it starts, so quit it from its menu and open it again."
assert_unchanged "$SOLAAR_CONFIG" "while Solaar ran"
cmp -s "$MOUSE_RULES" "$SOLAAR_RULES" || fail "the rules weren't copied while Solaar ran"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The MX Master 4's settings in ~/.config/solaar/config.yaml"
stub pgrep 'exit 1'

# A config that isn't Solaar's list is left as it is, and fails the step
echo "devices: none" > "$SOLAAR_CONFIG"
snapshot "$SOLAAR_CONFIG"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Couldn't edit $SOLAAR_CONFIG with yq"
assert_unchanged "$SOLAAR_CONFIG" "after a failed edit"
test_done
