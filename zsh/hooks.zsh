# In tmux, TERM_PROGRAM is "tmux", hiding the real terminal from tools that detect it. Import
# the attaching client's values (update-environment in tmux.conf). tmux.conf stamps
# <socket>.attached on each attach, so show-environment runs only after one.
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
            # "-": the attaching client didn't set it
            -TERM_PROGRAM|-TERM_PROGRAM_VERSION|-SSH_USER_AUTH) unset "${line#-}" ;;
        esac
    done
}

add-zsh-hook preexec _tmux_outer_terminal_preexec
