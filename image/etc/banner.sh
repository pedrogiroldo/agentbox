#!/bin/sh
# agentbox-banner — prints the agentbox wordmark, sized to the terminal.
#
# A phone gets 40-ish columns; the full block letters are 69 wide and would
# wrap into confetti. So there are three sizes and the narrowest one still
# fits a watch. Signature text comes from AGENTBOX_BANNER_BY.
#
# The sizes are picked with room to spare, not with a ruler. 69 columns of
# block letters technically fit an 80-column terminal, but 80 columns on a
# phone is a tiny font on a four-inch screen, and it is also what a client
# that never measured anything reports out of habit. A terminal that is
# genuinely wide says far more than 80, so that is where the big one starts.

by="${AGENTBOX_BANNER_BY:-by Pedro Giroldo}"

# How wide is this terminal? Ask everyone who might know, in order of how
# likely they are to be right:
#
#   AGENTBOX_BANNER_COLS  a straight answer, for testing and for stubborn cases
#   COLUMNS               the shell's own count — greet.sh hands us its copy,
#                         since bash keeps COLUMNS to itself and never exports it
#   stty size             the tty driver, which was told by the kernel
#   tput cols             terminfo, which first needs a TERM the box recognises
#
# Every one of these can come back empty or as garbage, so nothing is trusted
# until it has proven to be a plain positive number.
cols=""
for candidate in "${AGENTBOX_BANNER_COLS:-}" "${COLUMNS:-}"; do
    case "$candidate" in
        ''|*[!0-9]*) ;;
        *) [ "$candidate" -gt 0 ] && { cols="$candidate"; break; } ;;
    esac
done

if [ -z "$cols" ] && [ -t 1 ]; then
    cols=$(stty size 2>/dev/null </dev/tty | cut -d' ' -f2)
    case "$cols" in ''|*[!0-9]*|0) cols=$(tput cols 2>/dev/null) ;; esac
    case "$cols" in ''|*[!0-9]*|0) cols="" ;; esac
fi

# Still nothing. A terminal that will not say how wide it is is far more often
# a phone than a workstation, and a wordmark that came out too small is a
# much smaller insult than six wrapped lines of confetti on a 40-column screen.
# Output that is not a terminal at all (a pipe, a log) has no width to respect,
# so that one gets the full-size letters.
if [ -z "$cols" ]; then
    if [ -t 1 ]; then cols=40; else cols=80; fi
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    c_art=$(printf '\033[38;5;39m')      # blue
    c_by=$(printf '\033[38;5;245m')      # grey
    c_off=$(printf '\033[0m')
else
    c_art=''; c_by=''; c_off=''
fi

if [ "$cols" -ge 90 ]; then
    art_width=69
    art=$(cat <<'ART'
 █████╗  ██████╗ ███████╗███╗   ██╗████████╗██████╗  ██████╗ ██╗  ██╗
██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝██╔══██╗██╔═══██╗╚██╗██╔╝
███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║   ██████╔╝██║   ██║ ╚███╔╝
██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║   ██╔══██╗██║   ██║ ██╔██╗
██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║   ██████╔╝╚██████╔╝██╔╝ ██╗
╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚═════╝  ╚═════╝ ╚═╝  ╚═╝
ART
)
elif [ "$cols" -ge 40 ]; then
    art_width=37
    art=$(cat <<'ART'
                   _   _
 __ _ __ _ ___ _ _| |_| |__  _____ __
/ _` / _` / -_) ' \  _| '_ \/ _ \ \ /
\__,_\__, \___|_||_\__|_.__/\___/_\_\
     |___/
ART
)
elif [ "$cols" -ge 25 ]; then
    art_width=22
    art=$(cat <<'ART'
 _. _  _ .__|_|_  _
(_|(_|(/_| ||_|_)(_)><
    _|
ART
)
else
    art_width=8
    art="agentbox"
fi

# Centre the signature under the wordmark, never past the left margin.
pad=$(( (art_width - ${#by}) / 2 ))
[ "$pad" -lt 0 ] && pad=0

printf '\n%s%s%s\n' "$c_art" "$art" "$c_off"
printf '%*s%s%s%s\n\n' "$pad" '' "$c_by" "$by" "$c_off"
