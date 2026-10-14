# shellcheck shell=bash
# The Host blocks of ~/.ssh/config, $SSH_CONFIG, which the sourcing script sets: finding a host's
# block and adding one above the first catch-all. ssh/add-host.sh sources this file for add_block,
# and the ssh step for host_line. It only defines functions.

# Comments may mention hosts or settings. Keep hashes inside quotes or escaped with a backslash.
strip_ssh_comments() {
    awk '
        {
            quote = ""; escaped = 0
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (escaped) { escaped = 0; continue }
                if (c == "\\") { escaped = 1; continue }
                if (quote != "") { if (c == quote) quote = ""; continue }
                if (c == "\"" || c == sprintf("%c", 39)) { quote = c; continue }
                if (c == "#") { $0 = substr($0, 1, i - 1); break }
            }
            print
        }
    ' "$1"
}

# Succeeds when a Host line in the config lists the pattern, e.g. host_line '*' for `Host *` or
# `Host * !bastion`. ssh matches Host patterns case-sensitively.
host_line() {
    [ -f "$SSH_CONFIG" ] && awk -v host="$1" '
        tolower($1) == "host" { for (i = 2; i <= NF && $i !~ /^#/; i++) if ($i == host) found = 1 }
        END { exit !found }
    ' "$SSH_CONFIG"
}

# Print the line number of the main config's first catch-all: a Host line that lists the pattern
# *, such as `Host *` or `Host * !bastion`, or a Match all, `Match canonical all`, or `Match final
# all`. A comment right above it counts as part of it, so the comment stays with its block. Reads
# lines without their comments (strip_ssh_comments). Prints nothing when there's no catch-all.
catch_all_line() {
    [ -f "$SSH_CONFIG" ] || return 0
    # The stripped copy has a line for each of the config's, so line numbers stay the config's
    awk '
        NR == FNR { stripped[FNR] = $0; next }
        /^[ \t]*#/ { if (!comment) comment = FNR; next }
        {
            line = tolower(stripped[FNR])
            sub(/^[ \t]+/, "", line)
            sub(/\r$/, "", line)
            sub(/[ \t]+$/, "", line)
            found = line ~ /^match([ \t]+|[ \t]*=[ \t]*)("?(canonical|final)"?[ \t]+)?"?all"?$/
        }
        line ~ /^host([ \t]|[ \t]*=)/ {
            sub(/^host[ \t]*=?[ \t]*/, "", line)
            n = split(line, patterns, /[ \t]+/)
            for (i = 1; i <= n; i++) {
                gsub(/"/, "", patterns[i])
                if (patterns[i] == "*") found = 1
            }
        }
        found {
            print (comment ? comment : FNR)
            exit
        }
        { comment = 0 }
    ' <(strip_ssh_comments "$SSH_CONFIG") "$SSH_CONFIG"
}

# Add a block to the config above its first catch-all, else at the end. ssh uses the first value
# it finds for each setting, so a catch-all above the block would win over it. Defaults in an
# included file at the top level still win, as ssh reads them in place.
add_block() {
    local at new
    if [ ! -s "$SSH_CONFIG" ]; then
        printf '%s\n' "$1" > "$SSH_CONFIG"
        return 0
    fi
    at="$(catch_all_line)"
    new="$(mktemp)" || return 1
    if ! BLOCK="$1" awk -v at="${at:-0}" '
        function put() {
            if (NR > 1 && prev !~ /^[ \t]*$/) print ""
            print ENVIRON["BLOCK"]
        }
        NR == at { put(); print "" }
        { print; prev = $0 }
        END { if (at == 0) put() }
    ' "$SSH_CONFIG" > "$new"; then
        rm -f "$new"
        return 1
    fi
    # A failed write_back keeps the new contents, and says so
    write_back "$new" "$SSH_CONFIG"
}
