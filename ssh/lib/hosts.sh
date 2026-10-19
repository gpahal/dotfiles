# shellcheck shell=bash

SSH_CONFIG="$HOME/.ssh/config"

# Keeps quoted or escaped hashes
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

# Awk helpers that parse a line as ssh does. host_patterns returns the pattern count, or -1 for a
# non-Host line.
# shellcheck disable=SC2016 # awk code
SSH_CONFIG_AWK='
function ssh_keyword(line) {
    sub(/^[ \t]+/, "", line)
    match(line, /^[^ \t=]*/)
    return tolower(substr(line, 1, RLENGTH))
}
function host_patterns(line, patterns,   n, i, c, word, inword, quote) {
    split("", patterns)
    sub(/\r$/, "", line)
    if (ssh_keyword(line) != "host") return -1
    sub(/^[ \t]*[^ \t=]*[ \t]*=?[ \t]*/, "", line)
    n = 0; word = ""; inword = 0; quote = ""
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (quote != "") {
            if (c == quote) quote = ""; else word = word c
            continue
        }
        if (c == "\\" && i < length(line)) { word = word substr(line, ++i, 1); inword = 1; continue }
        if (c == "\"" || c == sprintf("%c", 39)) { quote = c; inword = 1; continue }
        if (c == " " || c == "\t") {
            if (inword) { patterns[++n] = word; word = ""; inword = 0 }
            continue
        }
        if (c == "#" && !inword) break
        word = word c; inword = 1
    }
    if (inword) patterns[++n] = word
    return n
}
'

# Case-sensitive, as ssh matches
host_line() {
    [ -f "$SSH_CONFIG" ] && awk -v host="$1" "$SSH_CONFIG_AWK"'
        { n = host_patterns($0, p); for (i = 1; i <= n; i++) if (p[i] == host) found = 1 }
        END { exit !found }
    ' "$SSH_CONFIG"
}

# Only `Host *` alone: `Host * !bastion` leaves a host out
host_star_block() {
    [ -f "$SSH_CONFIG" ] && awk "$SSH_CONFIG_AWK"'
        host_patterns($0, p) == 1 && p[1] == "*" { found = 1 }
        END { exit !found }
    ' "$SSH_CONFIG"
}

# Prints the first Host-with-* or Match all line, or the comment right above it, so the comment
# stays with its block
catch_all_line() {
    [ -f "$SSH_CONFIG" ] || return 0
    awk "$SSH_CONFIG_AWK"'
        NR == FNR { stripped[FNR] = $0; next }
        /^[ \t]*#/ { if (!comment) comment = FNR; next }
        {
            line = tolower(stripped[FNR])
            sub(/^[ \t]+/, "", line)
            sub(/\r$/, "", line)
            sub(/[ \t]+$/, "", line)
            found = line ~ /^match([ \t]+|[ \t]*=[ \t]*)("?(canonical|final)"?[ \t]+)?"?all"?$/
            n = host_patterns(stripped[FNR], patterns)
            for (i = 1; i <= n; i++) if (patterns[i] == "*") found = 1
        }
        found {
            print (comment ? comment : FNR)
            exit
        }
        { comment = 0 }
    ' <(strip_ssh_comments "$SSH_CONFIG") "$SSH_CONFIG"
}

# Above the first catch-all, since ssh uses the first value it finds. Top-level Includes still win.
add_block() {
    local at new
    if [ ! -s "$SSH_CONFIG" ]; then
        printf '%s\n' "$1" > "$SSH_CONFIG" || return 1
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
    write_back "$new" "$SSH_CONFIG"
}
