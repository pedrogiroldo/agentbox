#!/usr/bin/env bash
#
# agentbox-clean — says what is on the disk, and reclaims the part that is
# only cache, when you ask.
#
# A box that has been used for a month carries gigabytes it never asked for:
# npm's content store, bun's and uv's and pnpm's, npx trees left behind by
# every MCP server ever run once, a Chromium for Playwright, the four previous
# versions of a plugin. All of it rebuilds itself on the next install. None of
# it is listed anywhere an operator on a VPS would look.
#
# So this command is a report first. With no verb it prints what is where,
# what each verb would free, and -- separately, marked as never touched --
# the things that are yours: repositories, worktrees, agent transcripts,
# agent memory, credentials. Verbs reclaim; the report never does.
#
#   agentbox-clean                the report
#   agentbox-clean caches         package-manager and tool caches; nothing breaks
#   agentbox-clean browsers       downloaded browsers; tests break until reinstalled
#   agentbox-clean docker         unreferenced images and stopped containers in
#                                 the box's own daemon
#   agentbox-clean all            the three above
#   agentbox-clean --dry-run <v>  what a verb would remove, without removing it
#
# Every cache is reclaimed by its own tool where the tool has a verb for it,
# because the tool knows which entries are still referenced. Where it has
# none, the rule is written next to the path below, and shows up in the report.
#
# What this never does: delete anything not in the tables below. A path the
# box does not know is not "reclaimable" just because it is big.
#
# AGENTBOX_CLEAN_INTERVAL  seconds between automatic `caches` passes. Default
#                          off; the entrypoint starts the timer when set.
set -uo pipefail

USER_NAME="${AGENTBOX_USER:-dev}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$USER_NAME}"
# Overridable so a test can point it at a seeded directory.
HOME_DIR="${AGENTBOX_CLEAN_HOME:-$HOME_DIR}"
STATE_ROOT="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}"
NPX_MAX_AGE_DAYS="${AGENTBOX_CLEAN_NPX_DAYS:-7}"
TOOL_TIMEOUT="${AGENTBOX_CLEAN_TIMEOUT:-120}"

DRY=0
c_dim=$'\033[2m'; c_b=$'\033[1m'; c_warn=$'\033[33m'; c_off=$'\033[0m'

log()  { printf '[agentbox-clean] %s\n' "$*"; }
warn() { printf '%s[agentbox-clean] %s%s\n' "$c_warn" "$*" "$c_off" >&2; }

# Everything under the home is the user's, and the verbs that call a tool
# have to run as them so the tool finds its own config and cache locations.
as_user() {
    if [ "$(id -un)" = "$USER_NAME" ]; then
        env HOME="$HOME_DIR" "$@"
    else
        runuser -u "$USER_NAME" -- env HOME="$HOME_DIR" \
            PATH="$HOME_DIR/.local/bin:$HOME_DIR/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$@"
    fi
}

# Kilobytes used by a path, 0 when absent. du -s is the honest measure of
# what deleting it gives back (hard links counted once).
kb() {
    local out=""
    [ -e "$1" ] && out="$(du -sk "$1" 2>/dev/null | cut -f1)"
    echo "${out:-0}"
}

human_kb() {
    local k="$1"
    if   [ "$k" -ge 1048576 ]; then printf '%d.%d GB' $((k / 1048576)) $(( (k % 1048576) * 10 / 1048576 ))
    elif [ "$k" -ge 1024 ]; then printf '%d MB' $((k / 1024))
    else printf '%d KB' "$k"; fi
}

# ---------------------------------------------------------------------------
# The tables. One line per item: tier | path | label | how it is reclaimed.
# The report and the verbs both read these, so they cannot disagree.
#
# Reclaim methods:
#   tool:<cmd>   run the tool's own verb as the user (it decides what stays)
#   rm           remove the path outright
#   npx-age      remove entries older than NPX_MAX_AGE_DAYS by mtime
#   plugin-old   remove versions other than the one installed_plugins.json names
#   glob         remove what the path glob matches
# ---------------------------------------------------------------------------
CACHES=(
    "caches|$HOME_DIR/.npm/_cacache|npm content store|tool:npm cache clean --force"
    "caches|$HOME_DIR/.npm/_npx|npx leftovers older than ${NPX_MAX_AGE_DAYS}d|npx-age"
    "caches|$HOME_DIR/.bun/install/cache|bun package cache|tool:bun pm cache rm"
    "caches|$HOME_DIR/.cache/uv|uv cache|tool:uv cache clean"
    "caches|$HOME_DIR/.local/share/pnpm/store|pnpm store (unreferenced)|tool:pnpm store prune"
    "caches|$HOME_DIR/.cache/pip|pip cache|tool:pip3 cache purge"
    "caches|$HOME_DIR/.claude/plugins/cache|superseded plugin versions|plugin-old"
    "caches|$HOME_DIR/.claude.json.tmp.*|leftover temp files|glob"
    "caches|$HOME_DIR/.local/share/Trash|trash|rm"
    "browsers|$HOME_DIR/.cache/ms-playwright|Playwright browsers|rm"
    "browsers|$HOME_DIR/.cache/puppeteer|Puppeteer browsers|rm"
    "browsers|$HOME_DIR/.cache/google-chrome-for-testing-headless|Chrome for Testing|rm"
)

# Reported, never touched. Not a hint: the verbs cannot reach these.
YOURS=(
    "$HOME_DIR/projects|repositories"
    "$HOME_DIR/.herdr/worktrees|herdr worktrees (git worktree list / remove)"
    "$HOME_DIR/.claude/projects|Claude transcripts (what --resume reads)"
    "$HOME_DIR/.claude-mem|agent memory"
    "$HOME_DIR/.codex|Codex state"
    "$HOME_DIR/.config/opencode|opencode state"
    "$HOME_DIR/.ssh|keys"
    "$STATE_ROOT/apt/archives|apt cache in the state volume (offline replay)"
)

# ---------------------------------------------------------------------------
# Measuring
# ---------------------------------------------------------------------------

# What one item would free, in KB. For the rule-based ones, only the part the
# rule would actually take.
measure() {
    local path="$1" method="$2"
    case "$method" in
        npx-age)
            [ -d "$path" ] || { echo 0; return; }
            find "$path" -mindepth 1 -maxdepth 1 -type d -mtime "+$NPX_MAX_AGE_DAYS" -print0 2>/dev/null \
                | xargs -0 -r du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}' ;;
        plugin-old)
            local sum=0 d
            while IFS= read -r d; do sum=$((sum + $(kb "$d"))); done < <(superseded_plugin_dirs)
            echo "$sum" ;;
        glob)
            # Empty files measure 0 and would read as "nothing to do"; count
            # them as a kilobyte so the verb still removes them.
            local sum=0 f
            for f in $path; do
                [ -e "$f" ] || continue
                sum=$((sum + $(kb "$f")))
                [ "$sum" -gt 0 ] || sum=1
            done
            echo "$sum" ;;
        tool:pnpm*)
            # pnpm's prune only drops unreferenced packages; the store as a
            # whole is an upper bound. Say so in the label rather than lie.
            kb "$path" ;;
        *)  kb "$path" ;;
    esac
}

# Plugin cache directories whose version is not the installed one. Layout:
# plugins/cache/<marketplace>/<plugin>/<version>/, and installed_plugins.json
# names each plugin's version.
superseded_plugin_dirs() {
    local cache="$HOME_DIR/.claude/plugins/cache" installed="$HOME_DIR/.claude/plugins/installed_plugins.json"
    [ -d "$cache" ] && [ -f "$installed" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$cache" "$installed" <<'PY'
import json, os, sys
cache, installed = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(installed))
except Exception:
    sys.exit(0)
# installed_plugins.json: {"plugins": {"<plugin>@<marketplace>": {"version": ...}}} in
# the shape seen in the wild; be tolerant of other top-level keys.
current = {}
entries = data.get("plugins", data) if isinstance(data, dict) else {}
for key, val in (entries.items() if isinstance(entries, dict) else []):
    if not isinstance(val, dict):
        continue
    ver = val.get("version")
    if not ver or "@" not in key:
        continue
    plugin, market = key.split("@", 1)
    current[(market, plugin)] = str(ver)
for market in sorted(os.listdir(cache)):
    mdir = os.path.join(cache, market)
    if not os.path.isdir(mdir):
        continue
    for plugin in sorted(os.listdir(mdir)):
        pdir = os.path.join(mdir, plugin)
        if not os.path.isdir(pdir):
            continue
        keep = current.get((market, plugin))
        if keep is None:
            # Not installed according to the manifest: keep everything rather
            # than guess. The manifest is the only authority used here.
            continue
        for ver in sorted(os.listdir(pdir)):
            vdir = os.path.join(pdir, ver)
            if os.path.isdir(vdir) and ver != keep:
                print(vdir)
PY
}

# ---------------------------------------------------------------------------
# Reclaiming
# ---------------------------------------------------------------------------

# Run one item's method. Prints what happened; returns 0 even on a skip so
# the tier continues.
reclaim() {
    local path="$1" label="$2" method="$3" before after
    before="$(measure "$path" "$method")"
    [ "$before" -gt 0 ] || { printf '  %-44s %s\n' "$label" "${c_dim}nothing to do${c_off}"; return 0; }

    if [ "$DRY" = 1 ]; then
        printf '  %-44s would free %s\n' "$label" "$(human_kb "$before")"
        return 0
    fi

    case "$method" in
        tool:*)
            local cmd="${method#tool:}" tool="${method#tool:}"; tool="${tool%% *}"
            # Through a shell: `command` is a builtin, and as_user runs env.
            if ! as_user sh -c 'command -v "$1" >/dev/null 2>&1' _ "$tool"; then
                printf '  %-44s %s\n' "$label" "skipped: $tool is not installed"
                return 0
            fi
            # shellcheck disable=SC2086
            if ! as_user timeout "$TOOL_TIMEOUT" $cmd >/dev/null 2>&1; then
                printf '  %-44s %s\n' "$label" "skipped: '$cmd' failed or timed out (busy?)"
                return 0
            fi ;;
        rm)
            rm -rf -- "$path" 2>/dev/null || { printf '  %-44s %s\n' "$label" "skipped: could not remove"; return 0; } ;;
        npx-age)
            find "$path" -mindepth 1 -maxdepth 1 -type d -mtime "+$NPX_MAX_AGE_DAYS" -exec rm -rf -- {} + 2>/dev/null ;;
        plugin-old)
            local d
            while IFS= read -r d; do rm -rf -- "$d" 2>/dev/null; done < <(superseded_plugin_dirs) ;;
        glob)
            local f
            for f in $path; do [ -e "$f" ] && rm -rf -- "$f" 2>/dev/null; done ;;
    esac

    after="$(measure "$path" "$method")"
    printf '  %-44s freed %s\n' "$label" "$(human_kb $((before - after)))"
    echo $((before - after)) >> "$FREED_FILE"
}

run_tier() {
    local tier="$1" line t path label method
    printf '%s%s%s\n' "$c_b" "$tier" "$c_off"
    for line in "${CACHES[@]}"; do
        IFS='|' read -r t path label method <<< "$line"
        [ "$t" = "$tier" ] || continue
        reclaim "$path" "$label" "$method"
    done
}

run_docker_tier() {
    printf '%s%s%s\n' "$c_b" "docker" "$c_off"
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        printf '  %-44s %s\n' "images and containers" "${c_dim}no daemon in this box${c_off}"
        return 0
    fi
    if [ "$DRY" = 1 ]; then
        docker system df 2>/dev/null | sed 's/^/  /'
        printf '  %s\n' "would run: docker system prune -f (unreferenced images, stopped containers, unused networks)"
        return 0
    fi
    # No -a and no --volumes: images a stopped container still uses, and every
    # named volume, are the operator's to decide about.
    docker system prune -f 2>/dev/null | tail -1 | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

report() {
    local line t path label method size tier_sum home_kb
    home_kb="$(kb "$HOME_DIR")"

    printf '%shome%s   %s at %s\n' "$c_b" "$c_off" "$(human_kb "$home_kb")" "$HOME_DIR"
    printf '%sstate%s  %s at %s\n\n' "$c_b" "$c_off" "$(human_kb "$(kb "$STATE_ROOT")")" "$STATE_ROOT"

    for tier in caches browsers; do
        tier_sum=0
        printf '%sagentbox-clean %s%s\n' "$c_b" "$tier" "$c_off"
        for line in "${CACHES[@]}"; do
            IFS='|' read -r t path label method <<< "$line"
            [ "$t" = "$tier" ] || continue
            size="$(measure "$path" "$method")"
            [ "$size" -gt 0 ] || continue
            printf '  %-44s %10s   %s%s%s\n' "$label" "$(human_kb "$size")" "$c_dim" "${method#tool:}" "$c_off"
            tier_sum=$((tier_sum + size))
        done
        if [ "$tier_sum" -eq 0 ]; then
            printf '  %s\n' "${c_dim}nothing to reclaim${c_off}"
        else
            printf '  %-44s %10s\n' "would free about" "$(human_kb "$tier_sum")"
        fi
        [ "$tier" = browsers ] && [ "$tier_sum" -gt 0 ] \
            && printf '  %s\n' "${c_dim}reinstall with: npx playwright install${c_off}"
        echo
    done

    printf '%sagentbox-clean docker%s\n' "$c_b" "$c_off"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        docker system df 2>/dev/null | sed 's/^/  /'
    else
        printf '  %s\n' "${c_dim}no daemon in this box${c_off}"
    fi
    echo

    printf '%syours — never touched by this command%s\n' "$c_b" "$c_off"
    for line in "${YOURS[@]}"; do
        IFS='|' read -r path label <<< "$line"
        size="$(kb "$path")"
        [ "$size" -gt 0 ] || continue
        printf '  %-44s %10s\n' "$label" "$(human_kb "$size")"
    done
    echo
    printf '%s%s%s\n' "$c_dim" "a verb reclaims: agentbox-clean caches | browsers | docker | all   (--dry-run first, if you like)" "$c_off"
}

# The reclaimable figure the greeting reads, refreshed by the persist watcher
# rather than by a du at every login. Two numbers in KB: home, rebuildable.
cmd_measure() {
    local line t path label method sum=0 size
    for line in "${CACHES[@]}"; do
        IFS='|' read -r t path label method <<< "$line"
        size="$(measure "$path" "$method")"
        sum=$((sum + size))
    done
    printf '%s %s\n' "$(kb "$HOME_DIR")" "$sum"
}

usage() {
    cat <<'USAGE'
agentbox-clean — what is on the disk, and what of it is only cache

  (no verb)            the report; deletes nothing
  caches               package-manager and tool caches (nothing breaks)
  browsers             downloaded browsers (tests break until reinstalled)
  docker               unreferenced images and stopped containers in the box
  all                  the three above
  --dry-run <verb>     what a verb would remove
USAGE
}

FREED_FILE="$(mktemp)"
trap 'rm -f "$FREED_FILE"' EXIT

main() {
    [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
    case "${1:-}" in
        "")       report ;;
        caches)   run_tier caches ;;
        browsers) run_tier browsers ;;
        docker)   run_docker_tier ;;
        all)      run_tier caches; run_tier browsers; run_docker_tier ;;
        measure)  cmd_measure; return 0 ;;
        -h|--help|help) usage; return 0 ;;
        *) warn "unknown verb: $1"; usage; return 2 ;;
    esac
    if [ "$DRY" = 0 ] && [ -s "$FREED_FILE" ]; then
        printf '\nfreed %s\n' "$(human_kb "$(awk '{s+=$1} END {print s+0}' "$FREED_FILE")")"
    fi
}

main "$@"
