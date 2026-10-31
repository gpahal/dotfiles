#!/bin/bash
# shellcheck disable=SC2329 # the step calls the functions this test replaces

# The ntfy step. On Ubuntu: Tailscale's prerequisites failing before any change, ntfy from its apt
# repo with its config and drop-in written before it starts, a restart only for a changed config,
# the Funnel published only with the tailnet's capabilities, and status probing the access policy
# without a POST, and Ubuntu Pro's older ntfy replaced through the pin. On macOS: only the notifier, which a temp HOME doesn't load.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq &>/dev/null || skip "jq isn't installed"

HOST=box.example.ts.net
PUBLIC_URL="https://$HOST:8443"

# ts-caps lists the tailnet's capabilities for this machine; ts-state its backend state
tailscale_json() {
    jq -n --arg state "$(cat "$SANDBOX/ts-state")" --arg dns "$(cat "$SANDBOX/ts-dns")" \
        --argjson caps "$(cat "$SANDBOX/ts-caps")" \
        '{BackendState: $state, Self: {DNSName: $dns, CapMap: ($caps | map({(.): null}) | add // {})}}'
}

load_ubuntu() {
    load_script ntfy/install.sh
    as_os ubuntu
    sandbox_paths ntfy/install.sh 'ntfy/lib/*.sh' ubuntu/lib/paths.sh
    stub_sudo_exec
    stub_dpkg_arch
    stub_fetch
    stub_gpg_fpr "$NTFY_KEY_FPR"
    stub sleep
    stub_systemctl_units "$SANDBOX/units"
    replace_fn gnome_session_running 'return 1'
}

stub_ubuntu_machine() {
    echo Running > "$SANDBOX/ts-state"
    echo "$HOST." > "$SANDBOX/ts-dns"
    echo '["https", "funnel"]' > "$SANDBOX/ts-caps"
    echo '{}' > "$SANDBOX/serve.json"
    # status --json from the files above; funnel writes the serve config as Tailscale v1.104.4 does
    stub tailscale "$(declare -f tailscale_json)"'
case "$*" in
    "status --json") tailscale_json ;;
    "funnel status --json") cat "$SANDBOX/serve.json" ;;
    "funnel --bg --yes --https=8443 http://127.0.0.1:2586")
        hp="$(jq -r ".Self.DNSName | rtrimstr(\".\")" <<< "$(tailscale_json)"):8443"
        jq --arg hp "$hp" ".TCP[\"8443\"] = {HTTPS: true} | .Web[\$hp].Handlers[\"/\"].Proxy = \"http://127.0.0.1:2586\" | .AllowFunnel[\$hp] = true" \
            "$SANDBOX/serve.json" > "$SANDBOX/serve.json.new" && mv "$SANDBOX/serve.json.new" "$SANDBOX/serve.json" ;;
    *) exit 1 ;;
esac'
    # The server answers while ntfy.service runs. anon-code is what an anonymous read gets, and
    # config.json what /v1/config returns.
    echo 403 > "$SANDBOX/anon-code"
    echo '{"enable_login":true,"require_login":true,"enable_signup":false}' > "$SANDBOX/config.json"
    stub curl 'url="${!#}"
up=false
[ ! -e "$SANDBOX/units/ntfy.service.active" ] || up=true
case "$url" in
    http://127.0.0.1:2586/v1/health) "$up" && echo "{\"healthy\":true}" || exit 7 ;;
    http://127.0.0.1:2586/v1/config) "$up" && cat "$SANDBOX/config.json" || exit 7 ;;
    http://127.0.0.1:2586/*/json?poll=1) "$up" && cat "$SANDBOX/anon-code" || { echo 000; exit 7; } ;;
    https://cloudflare-dns.com/*) echo "{\"Answer\":[{\"data\":\"203.0.113.1\"}]}" ;;
    *) exit 6 ;;
esac'
    # ntfy-origin is where the installed ntfy came from: apt takes ntfy's repo's only once the pin
    # is in place, since Ubuntu Pro's esm-apps repo, at 510, outranks it
    stub_apt_packages --apt-get "case \" \$* \" in *\" install \"*ntfy*)
    if [ -e $(printf %q "$NTFY_PIN") ]; then echo repo; else echo esm; fi > \"\$SANDBOX/ntfy-origin\" ;;
esac"
    stub apt-cache 'grep -qxF ntfy "$SANDBOX/installed" || { echo "ntfy:"; exit 0; }
printf "%s\n" "ntfy:" "  Version table:"
if [ "$(cat "$SANDBOX/ntfy-origin")" == repo ]; then
    printf "%s\n" " *** 2.35.0 600" "        500 https://archive.ntfy.sh/apt stable/main amd64 Packages" \
        "        100 /var/lib/dpkg/status" "     2.11.0-3ubuntu0.26.04.1~esm1 510" \
        "        510 https://esm.ubuntu.com/apps/ubuntu resolute-apps-security/main amd64 Packages"
else
    printf "%s\n" "     2.35.0 500" "        500 https://archive.ntfy.sh/apt stable/main amd64 Packages" \
        " *** 2.11.0-3ubuntu0.26.04.1~esm1 510" \
        "        510 https://esm.ubuntu.com/apps/ubuntu resolute-apps-security/main amd64 Packages" \
        "        100 /var/lib/dpkg/status"
fi'
}

client_config() {
    mkdir -p "$HOME/.config/ntfy"
    printf '%s\n' "default-host: http://127.0.0.1:2586" "default-token: tk_0123456789abcdefghijklmnopqrs" \
        > "$HOME/.config/ntfy/client.yml"
    chmod 600 "$HOME/.config/ntfy/client.yml"
}

# Line number of the first log line matching the pattern
log_line() {
    grep -n -- "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1
}

load_ubuntu
stub_ubuntu_machine

# Prerequisites fail before any change
prerequisites() {
    hide tailscale
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "Run bash setup.sh ubuntu first"
    assert_eq "" "$(machine_changes "$STUB_LOG")" "changes without tailscale"
}
subtest prerequisites
echo NeedsLogin > "$SANDBOX/ts-state"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Tailscale isn't connected. Run sudo tailscale up"
assert_file_not_contains "$STUB_LOG" "sudo"
echo Running > "$SANDBOX/ts-state"
echo "" > "$SANDBOX/ts-dns"
assert_exit 1 main
assert_contains "$RUN_OUTPUT" "Turn on MagicDNS"
assert_file_not_contains "$STUB_LOG" "sudo"
echo "$HOST." > "$SANDBOX/ts-dns"

# A declined sudo question changes nothing and doesn't fail the step
answer no
assert_exit 0 main
assert_contains "$RUN_OUTPUT" "These need sudo:"
assert_contains "$RUN_OUTPUT" "Left unchanged."
assert_file_not_contains "$STUB_LOG" "apt-get"
assert_file_not_contains "$STUB_LOG" "tailscale funnel --bg"
[ ! -e "$NTFY_CONFIG" ] || fail "the config was written without a yes"

# A fresh install: the config and drop-in go in before ntfy first starts, so it never listens on :80
answer yes
assert_exit 0 main
assert_file_contains "$SANDBOX/installed" "ntfy"
assert_eq repo "$(cat "$SANDBOX/ntfy-origin")" "where the installed ntfy came from"
assert_file_contains "$NTFY_PIN" "Pin: origin archive.ntfy.sh"
pin_at="$(log_line "preferences.d/dotfiles-ntfy")"
install_at="$(log_line "install -y ntfy")"
[ -n "$pin_at" ] && [ -n "$install_at" ] && [ "$pin_at" -lt "$install_at" ] ||
    fail "ntfy was installed before the pin was written (lines $pin_at, $install_at)"
assert_eq "$(printf '%s\n' "Types: deb" "URIs: https://archive.ntfy.sh/apt" "Suites: stable" "Components: main" \
    "Architectures: amd64" "Signed-By: $NTFY_KEYRING")" "$(cat "$NTFY_SOURCES")" "ntfy's apt source"
cmp -s "$REPO_DIR/ntfy/server.yml" "$NTFY_CONFIG" || fail "the server config isn't the repo's"
assert_eq 644 "$(file_mode "$NTFY_CONFIG")" "the server config's mode"
assert_file_contains "$NTFY_DROP_IN" "Environment=NTFY_BASE_URL=$PUBLIC_URL"
assert_file_contains "$NTFY_DROP_IN" "ProtectSystem=strict"
# systemd creates the directories Ubuntu's package leaves out, private since they hold the tokens
assert_file_contains "$NTFY_DROP_IN" "StateDirectory=ntfy"
assert_file_contains "$NTFY_DROP_IN" "StateDirectoryMode=0700"
assert_file_contains "$NTFY_DROP_IN" "CacheDirectory=ntfy"
assert_file_contains "$NTFY_DROP_IN" "CacheDirectoryMode=0700"
assert_file_not_contains "$NTFY_DROP_IN" "ReadWritePaths"
assert_file_contains "$NTFY_UNATTENDED_CONF" '"site=archive.ntfy.sh";'
config_at="$(log_line "etc/ntfy/server.yml")"
drop_in_at="$(log_line "ntfy.service.d/dotfiles.conf")"
enable_at="$(log_line "systemctl enable --now ntfy.service")"
[ -n "$config_at" ] && [ -n "$drop_in_at" ] && [ -n "$enable_at" ] &&
    [ "$config_at" -lt "$enable_at" ] && [ "$drop_in_at" -lt "$enable_at" ] ||
    fail "ntfy started before its config and drop-in were written (lines $config_at, $drop_in_at, $enable_at)"
assert_file_not_contains "$STUB_LOG" "systemctl restart ntfy.service"
assert_file_contains "$STUB_LOG" "tailscale funnel --bg --yes --https=8443 http://127.0.0.1:2586"
assert_file_not_contains "$STUB_LOG" "reset"
assert_eq true "$(jq --arg hp "$HOST:8443" '.AllowFunnel[$hp]' "$SANDBOX/serve.json")" "the funnel"
for script in subscribe.sh notify.sh; do
    cmp -s "$REPO_DIR/ntfy/$script" "$HOME/.local/share/dotfiles/ntfy/$script" || fail "$script wasn't copied"
done
assert_file_contains "$HOME/.config/systemd/user/dotfiles-ntfy-notify.service" "WantedBy=graphical-session.target"
assert_file_contains "$HOME/.config/systemd/user/dotfiles-ntfy-notify.service" \
    "ExecStart=/bin/bash \"$HOME/.local/share/dotfiles/ntfy/subscribe.sh\""
assert_contains "$RUN_OUTPUT" "Next: run just ntfy-user"

assert_idempotent main
assert_contains "$RUN_OUTPUT" "ntfy is already installed, configured, and published."

# Status reads only, and never posts: a POST to sign-up would create an account if it were open
client_config
assert_read_only 0 main --status
assert_contains "$RUN_OUTPUT" "ok         ntfy published on Tailscale Funnel ($PUBLIC_URL)"
assert_contains "$RUN_OUTPUT" "ok         ntfy answers on http://127.0.0.1:2586"
assert_contains "$RUN_OUTPUT" "ok         ntfy refuses anyone without a password or token"
assert_contains "$RUN_OUTPUT" "ok         ntfy's sign-up off"
assert_contains "$RUN_OUTPUT" "ok         ntfy's public name resolves on the internet ($HOST)"
assert_contains "$RUN_OUTPUT" "ok         ntfy's users and this machine's token"
assert_contains "$RUN_OUTPUT" "unverified ntfy's desktop notifier running: no desktop session"
if grep '^curl' "$STUB_LOG" | grep -qE -- ' (-X|--request|-d|--data[^ ]*|-F|--form) '; then
    fail "status sent data to the server"
fi
echo 200 > "$SANDBOX/anon-code"
echo '{"enable_signup":true}' > "$SANDBOX/config.json"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    ntfy refusing anyone without a password or token: an anonymous read got 200"
assert_contains "$RUN_OUTPUT" "missing    ntfy's sign-up off"
echo 403 > "$SANDBOX/anon-code"
echo '{"enable_signup":false}' > "$SANDBOX/config.json"
# For the alerts, status skips the public DNS lookup
export DOTFILES_STATUS_FOR_ALERTS=1
assert_exit 0 main --status
assert_contains "$RUN_OUTPUT" "unverified ntfy's public name resolves on the internet: skipped by --for-alerts"
assert_file_not_contains "$STUB_LOG" "cloudflare-dns.com"
unset DOTFILES_STATUS_FOR_ALERTS

# A config changed by hand comes back, and restarts the running server; an unchanged one doesn't
echo "listen-http: \":80\"" > "$NTFY_CONFIG"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    ntfy's server config"
assert_exit 0 main
assert_file_contains "$STUB_LOG" "sudo systemctl restart ntfy.service"
cmp -s "$REPO_DIR/ntfy/server.yml" "$NTFY_CONFIG" || fail "the server config wasn't restored"
assert_exit 0 main
assert_file_not_contains "$STUB_LOG" "restart"

# Without the funnel nodeAttr, the server is set up but not published, and the step fails
echo '{}' > "$SANDBOX/serve.json"
echo '["https"]' > "$SANDBOX/ts-caps"
assert_exit 1 main
assert_file_not_contains "$STUB_LOG" "tailscale funnel --bg"
assert_contains "$RUN_OUTPUT" "give it the funnel nodeAttr"
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    The funnel nodeAttr granted to this machine"
assert_not_contains "$RUN_OUTPUT" "ntfy published on Tailscale Funnel"
echo '["https", "funnel"]' > "$SANDBOX/ts-caps"

# Before just ntfy-user, status says to run it
rm "$HOME/.config/ntfy/client.yml"
assert_exit 0 main
assert_exit 3 main --status
assert_contains "$RUN_OUTPUT" "missing    ntfy's users and this machine's token: run just ntfy-user"

# Ubuntu Pro's older ntfy, installed before the pin, counts as missing and is replaced
ubuntu_pro_ntfy() {
    rm "$NTFY_PIN"
    echo esm > "$SANDBOX/ntfy-origin"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    ntfy taken from ntfy's apt repo"
    assert_contains "$RUN_OUTPUT" "missing    ntfy from ntfy's apt repo"
    assert_exit 0 main
    assert_eq repo "$(cat "$SANDBOX/ntfy-origin")" "where the installed ntfy came from"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "ok         ntfy from ntfy's apt repo"
}
subtest ubuntu_pro_ntfy

# --- macOS: only the notifier ---
macos() {
    load_script ntfy/install.sh
    as_os macos
    sandbox_paths ntfy/install.sh 'ntfy/lib/*.sh' ubuntu/lib/paths.sh
    stub ntfy
    stub terminal-notifier
    # A temp HOME isn't the account's home, so the agent isn't loaded
    stub dscl 'echo "NFSHomeDirectory: /Users/someone-else"'
    stub launchctl '[ "$1" != print ] || exit 1'
    assert_idempotent main
    assert_contains "$FIRST_OUTPUT" "isn't loaded. Load it with:"
    assert_contains "$FIRST_OUTPUT" "once just ntfy-device saves this Mac's token"
    cmp -s "$REPO_DIR/ntfy/dotfiles.ntfy-subscribe.plist" "$HOME/Library/LaunchAgents/dotfiles.ntfy-subscribe.plist" ||
        fail "the LaunchAgent wasn't copied"
    [ -e "$HOME/.local/share/dotfiles/ntfy/notify.sh" ] || fail "notify.sh wasn't copied"
    printf '%s\n' "$FIRST_LOG" | grep -qE '^(sudo|apt-get|systemctl|tailscale|launchctl bootstrap)' &&
        fail "the macOS notifier touched the server's parts or loaded the agent"
    assert_read_only 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    The dotfiles.ntfy-subscribe LaunchAgent loaded"
    assert_contains "$RUN_OUTPUT" "missing    This Mac's ntfy token: run just ntfy-device"
    mkdir -p "$HOME/.local/state/dotfiles/ntfy"
    echo "macOS doesn't allow terminal-notifier's notifications; allow them" > "$HOME/.local/state/dotfiles/ntfy/notify-error"
    assert_exit 3 main --status
    assert_contains "$RUN_OUTPUT" "missing    ntfy's desktop notifications showing: macOS doesn't allow terminal-notifier's notifications"
    hide terminal-notifier
    assert_exit 1 main
    assert_contains "$RUN_OUTPUT" "terminal-notifier isn't installed. Run bash setup.sh homebrew first."
}
subtest macos

test_done
