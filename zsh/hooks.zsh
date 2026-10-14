# Inside tmux, TERM_PROGRAM is "tmux", which hides the real terminal from tools that detect
# it (e.g. Claude Code and Codex desktop notifications). Export the outer terminal's values,
# which tmux refreshes on every attach (see update-environment in tmux.conf). SSH_USER_AUTH
# comes the same way, so the ubuntu step run in a pane sees the attaching SSH login's keys.
# tmux.conf writes a new value to <socket>.attached on every attach and session switch. Comparing
# it, read with $(<file), which zsh does without a fork, limits `tmux show-environment` to a
# pane's first command and the first after each attach. Without a marker, as before the first
# attach, read it before every command.
function _tmux_outer_terminal_preexec {
    [[ -n "${TMUX:-}" ]] || return
    local line marker="${TMUX%%,*}.attached" stamp=""
    [[ -r $marker ]] && stamp="$(<$marker)"
    if [[ -n $stamp ]]; then
        [[ ${_tmux_attach_stamp-} == "$stamp" ]] && return
        typeset -g _tmux_attach_stamp=$stamp
    fi
    for line in "${(@f)$(tmux show-environment 2>/dev/null)}"; do
        case "$line" in
            TERM_PROGRAM=*|TERM_PROGRAM_VERSION=*|SSH_USER_AUTH=*) export "$line" ;;
            # A leading "-" means the attaching client didn't set it
            -TERM_PROGRAM|-TERM_PROGRAM_VERSION|-SSH_USER_AUTH) unset "${line#-}" ;;
        esac
    done
}

autoload -U add-zsh-hook
add-zsh-hook preexec _tmux_outer_terminal_preexec
