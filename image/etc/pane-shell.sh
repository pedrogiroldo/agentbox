#!/usr/bin/env bash
#
# agentbox-pane-shell — the SHELL the herdr server opens panes with.
#
# The herdr server is control plane: it lives in the cgroup the box weights
# ahead of the workload, so that it keeps answering when the agents saturate
# the machine. Every pane it opens would inherit that position, and a pane is
# exactly where the workload lives. So the server is handed this script as
# $SHELL, and this script does three things and gets out of the way:
#
#   1. moves itself into the workload group (cgroup membership survives exec,
#      setsid, nohup and daemonising, so the shell and everything it ever
#      starts are workload from here on)
#   2. puts SHELL back to the user's real shell, so nothing inside the pane
#      ever sees this wrapper
#   3. execs that shell with whatever herdr passed
#
# The move needs root -- writing another cgroup's procs file is not something
# the box hands to its user -- so it goes through the passwordless sudo the
# box already grants. When that is unavailable, or the box runs with
# isolation off, the shell still opens: a pane in the wrong group beats a
# pane that does not open.
#
# AGENTBOX_PANE_SHELL  the shell to exec (agentbox-herdr sets it to the
#                      user's passwd shell). Falls back to bash.

real="${AGENTBOX_PANE_SHELL:-}"
if [ -z "$real" ] || [ ! -x "$real" ]; then
    real="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"
fi
[ -n "$real" ] && [ -x "$real" ] || real=/bin/bash

# Quietly: a pane that prints a sudo error on every open is worse than one
# that simply is not isolated.
if [ -x /usr/local/bin/agentbox-cgroup ]; then
    if [ "$(id -u)" = 0 ]; then
        /usr/local/bin/agentbox-cgroup enter work $$ >/dev/null 2>&1 || true
    else
        sudo -n /usr/local/bin/agentbox-cgroup enter work $$ >/dev/null 2>&1 || true
    fi
fi

export SHELL="$real"
unset AGENTBOX_PANE_SHELL
exec "$real" "$@"
