# Runs before showing the prompt
function _termsupport_precmd {
    [[ "${DISABLE_AUTO_TITLE:-}" == true ]] && return
    title $ZSH_THEME_TERM_TAB_TITLE_IDLE $ZSH_THEME_TERM_TITLE_IDLE
}

# Runs before executing the command
function _termsupport_preexec {
    [[ "${DISABLE_AUTO_TITLE:-}" == true ]] && return

    emulate -L zsh

    # split command into array of arguments
    local -a cmdargs
    cmdargs=("${(z)2}")
    # if running fg, extract the command from the job description
    if [[ "${cmdargs[1]}" = fg ]]; then
        # get the job id from the first argument passed to the fg command
        local job_id jobspec="${cmdargs[2]#%}"
        # logic based on jobs arguments:
        # http://zsh.sourceforge.net/Doc/Release/Jobs-_0026-Signals.html#Jobs
        # https://www.zsh.org/mla/users/2007/msg00704.html
        case "$jobspec" in
            <->) # %number argument:
                # use the same <number> passed as an argument
                job_id=${jobspec} ;;
            ""|%|+) # empty, %% or %+ argument:
                # use the current job, which appears with a + in $jobstates:
                # suspended:+:5071=suspended (tty output)
                job_id=${(k)jobstates[(r)*:+:*]} ;;
            -) # %- argument:
                # use the previous job, which appears with a - in $jobstates:
                # suspended:-:6493=suspended (signal)
                job_id=${(k)jobstates[(r)*:-:*]} ;;
            [?]*) # %?string argument:
                # use $jobtexts to match for a job whose command *contains* <string>
                job_id=${(k)jobtexts[(r)*${(Q)jobspec}*]} ;;
            *) # %string argument:
                # use $jobtexts to match for a job whose command *starts with* <string>
                job_id=${(k)jobtexts[(r)${(Q)jobspec}*]} ;;
        esac

        # override preexec function arguments with job command
        if [[ -n "${jobtexts[$job_id]}" ]]; then
            1="${jobtexts[$job_id]}"
            2="${jobtexts[$job_id]}"
        fi
    fi

    # cmd name only, or if this is sudo or ssh, the next cmd
    local CMD=${1[(wr)^(*=*|sudo|ssh|mosh|rake|-*)]:gs/%/%%}
    local LINE="${2:gs/%/%%}"

    title '$CMD' '%100>...>$LINE%<<'
}

# Inside tmux, TERM_PROGRAM is "tmux", which hides the real terminal from tools that detect
# it (e.g. Claude Code and Codex desktop notifications). Export the outer terminal's values,
# which tmux refreshes on every attach (see update-environment in tmux.conf).
function _tmux_outer_terminal_preexec {
    [[ -n "${TMUX:-}" ]] || return
    local line
    for line in "${(@f)$(tmux show-environment 2>/dev/null)}"; do
        case "$line" in
            TERM_PROGRAM=*|TERM_PROGRAM_VERSION=*) export "$line" ;;
        esac
    done
}

autoload -U add-zsh-hook
add-zsh-hook precmd _termsupport_precmd
add-zsh-hook preexec _termsupport_preexec
add-zsh-hook preexec _tmux_outer_terminal_preexec
