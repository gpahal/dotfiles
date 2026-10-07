# Set terminal window and tab/icon title
#
# usage: title short_tab_title [long_window_title]
#
# See: http://www.faqs.org/docs/Linux-mini/Xterm-Title.html#ss3.1
# Fully supports screen and probably most modern xterm and rxvt
# (In screen, only short_tab_title is used)
title() {
    emulate -L zsh
    setopt prompt_subst

    [[ "$EMACS" == *term* ]] && return

    # if $2 is unset use $1 as default
    # if it is set and empty, leave it as is
    : ${2=$1}

    case "$TERM" in
        xterm*|putty*|rxvt*|konsole*|ansi|mlterm*|alacritty|st*)
            print -Pn "\e]2;${2:q}\a" # set window name
            print -Pn "\e]1;${1:q}\a" # set tab name
            ;;
        screen*|tmux*)
            print -Pn "\ek${1:q}\e\\" # set screen hardstatus
            ;;
        *)
            # Try to use terminfo to set the title
            # If the feature is available set title
            if [[ -n "$terminfo[fsl]" ]] && [[ -n "$terminfo[tsl]" ]]; then
                echoti tsl
                print -Pn "$1"
                echoti fsl
            fi
            ;;
    esac
}

ZSH_THEME_TERM_TAB_TITLE_IDLE="%15<..<%~%<<"
ZSH_THEME_TERM_TITLE_IDLE="%~"
