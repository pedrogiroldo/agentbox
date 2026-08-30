#!/bin/sh
# agentbox-banner — prints the agentbox wordmark, sized to the terminal.
#
# A phone gets 40-ish columns; the full block letters are 69 wide and would
# wrap into confetti. So there are three sizes and the narrowest one still
# fits a watch. Signature text comes from AGENTBOX_BANNER_BY.

by="${AGENTBOX_BANNER_BY:-by Pedro Giroldo}"

cols="${COLUMNS:-}"
if [ -z "$cols" ]; then
    if [ -t 1 ]; then
        cols=$(tput cols 2>/dev/null || echo 80)
    else
        cols=80
    fi
fi
[ "$cols" -gt 0 ] 2>/dev/null || cols=80

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    c_art=$(printf '\033[38;5;39m')      # blue
    c_by=$(printf '\033[38;5;245m')      # grey
    c_off=$(printf '\033[0m')
else
    c_art=''; c_by=''; c_off=''
fi

if [ "$cols" -ge 72 ]; then
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
