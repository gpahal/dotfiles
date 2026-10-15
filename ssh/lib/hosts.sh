# shellcheck shell=bash
# The Host blocks of ~/.ssh/config, $SSH_CONFIG, which the sourcing script sets: finding a host's
# block and adding one above the first catch-all. ssh/add-host.sh sources this file for add_block,
# and the ssh step for host_line and SSH_CONFIG_AWK. It only defines functions and that variable.

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

# Awk functions that read a config line as ssh does: the keyword in any case, after leading
# whitespace, then whitespace or an = between it and the arguments, which are split on whitespace,
# with quotes keeping one whole and a backslash escaping the next character. An unquoted # starting
# an argument starts a comment. The programs below prepend them.
# - ssh_keyword(line) returns the keyword in lowercase.
# - host_patterns(line, patterns) fills patterns with a Host line's patterns and returns how many,
#   or returns -1 for any other line.
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

# Print a Host line's patterns, one per line, and nothing for any other line
host_patterns() {
    printf '%s\n' "$1" | awk "$SSH_CONFIG_AWK"'
        { n = host_patterns($0, p); for (i = 1; i <= n; i++) print p[i] }
    '
}

# Succeeds when a Host line in the config lists the pattern, e.g. host_line '*' for `Host *` or
# `Host * !bastion`. ssh matches Host patterns case-sensitively.
host_line() {
    [ -f "$SSH_CONFIG" ] && awk -v host="$1" "$SSH_CONFIG_AWK"'
        { n = host_patterns($0, p); for (i = 1; i <= n; i++) if (p[i] == host) found = 1 }
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

# Add a block to the config above its first catch-all, else at the end. ssh uses the first value
# it finds for each setting, so a catch-all above the block would win over it. Defaults in an
# included file at the top level still win, as ssh reads them in place.
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
    # A failed write_back keeps the new contents, and says so
    write_back "$new" "$SSH_CONFIG"
}
