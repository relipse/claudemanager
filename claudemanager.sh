#!/usr/bin/env bash
# claudemanager - Colorful TUI for managing Claude project directories
# Copyright (C) 2026 Kinsman Software LLC. All rights reserved.
# All TUI I/O goes through /dev/tty so the wrapper function can capture stdout signals.
#
# Usage:
#   claudemanager              — open the TUI
#   claudemanager --install    — install/update the shell wrapper function
#   claudemanager --refresh    — re-write the shell wrapper (after an update)
#   claudemanager <query>      — quick-open if match score ≥ threshold, else pre-fill search
#   claudemanager -o <query>   — force-open the best match (no threshold gate)

set -uo pipefail

CLAUDE_BASE="${CLAUDE_BASE:-$HOME/.claudemanager}"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
EXTRA_DIRS_FILE="$CLAUDE_BASE/.claudemanager_dirs"
IGNORE_FILE="$CLAUDE_BASE/.claudemanager_ignore"
CACHE_FILE="$CLAUDE_BASE/.claudemanager_cache"
CACHE_SCHEMA="7"  # bump when _compute_title/_compute_* output format changes
BUILD_DATE=$(stat -f '%Sm' -t '%Y-%m-%d' "${BASH_SOURCE[0]}" 2>/dev/null || date '+%Y-%m-%d')
DIRLIST_CACHE="$CLAUDE_BASE/.claudemanager_dirlist"
PREFS_FILE="$CLAUDE_BASE/.claudemanager_prefs"
HISTORY_FILE="$CLAUDE_BASE/.claudemanager_history"
GROUPS_FILE="$CLAUDE_BASE/.claudemanager_groups"

# ── Colors ────────────────────────────────────────────────────────
reset=$'\e[0m'
bold=$'\e[1m'
dim=$'\e[2m'
italic=$'\e[3m'

black=$'\e[30m'
red=$'\e[31m'
green=$'\e[32m'
yellow=$'\e[33m'
blue=$'\e[34m'
magenta=$'\e[35m'
cyan=$'\e[36m'
white=$'\e[37m'

bred=$'\e[91m'
bgreen=$'\e[92m'
byellow=$'\e[93m'
bblue=$'\e[94m'
bmagenta=$'\e[95m'
bcyan=$'\e[96m'
bwhite=$'\e[97m'

bg_red=$'\e[41m'
bg_green=$'\e[42m'
bg_yellow=$'\e[43m'
bg_cyan=$'\e[46m'
bg_magenta=$'\e[45m'
bg_gray=$'\e[100m'
bg_bblue=$'\e[104m'
bg_sel=$'\e[48;5;24m'

# ── All TUI output goes to /dev/tty ──────────────────────────────
tput_lines() { tput lines 2>/dev/tty; }
tput_cols()  { tput cols  2>/dev/tty; }

tui() {
    printf "$@" > /dev/tty
}

hide_cursor()  { tui '\e[?25l'; }

# Mouse SGR tracking: button-events + extended coords (works in iTerm/Terminal.app/xterm)
enable_mouse()  { tui '\e[?1000h\e[?1006h'; }
disable_mouse() { tui '\e[?1006l\e[?1000l'; }

# Layout snapshot from last draw() — used to map mouse clicks back to items
_mouse_list_start=0
_mouse_row_height=1
_mouse_grid_cols=1
_mouse_cell_width=24
_mouse_cell_height=2
_mouse_display_mode=""
_mouse_btn_rows=()
_mouse_btn_starts=()
_mouse_btn_ends=()
_mouse_btn_keys=()
_mouse_list_cols=1
_mouse_list_max_rows=1
_mouse_right_col_start=9999
_btn_col=0
_btn_row=2
_btn_max_col=9999

# Render a clickable keybinding chip, wrapping to the next row when needed.
# Args: letter, description, key-to-dispatch, bg-color, fg-color
_draw_btn() {
    local letter="$1" desc="$2" key="$3" bg="$4" fg="$5"
    local chip=" $letter "
    local tail=" $desc  "
    local btn_width=$(( ${#chip} + ${#tail} ))
    # Wrap to next row when this button would overflow the terminal width
    if (( _btn_col + btn_width > _btn_max_col && _btn_col > 2 )); then
        (( _btn_row++ ))
        _btn_col=2
    fi
    move_to "$_btn_row" "$_btn_col"
    tui '%s%s%s%s%s%s' "$bg" "$fg" "$chip" "${reset}${dim}" "$tail" "${reset}"
    local start_col=$_btn_col
    local end_col=$(( _btn_col + btn_width - 1 ))
    _mouse_btn_rows+=("$_btn_row")
    _mouse_btn_starts+=("$start_col")
    _mouse_btn_ends+=("$end_col")
    _mouse_btn_keys+=("$key")
    _btn_col=$(( end_col + 1 ))
}
show_cursor()  { tui '\e[?25h'; }
move_to()      { tui '\e[%d;%dH' "$1" "$2"; }
clear_screen() { tui '\e[2J\e[H'; }
clear_line()   { tui '\e[2K'; }

# ── State ─────────────────────────────────────────────────────────
selected=0
scroll_offset=0
action=""
open_dir=""
open_agent_override=""
open_force_run=false
status_msg=""
status_color="$green"
search_query=""
sort_mode="date"       # date | modified | recent | name | language
view_mode="local"      # local | all
display_mode="compact"  # compact | full | grid
title_mode="scroll_region" # none | window_title | tmux_split | tmux_status | scroll_region | prompt
auto_claude="on"       # on | off
agent="claude"         # AI agent to launch: claude opencode copilot amp cursor-agent aider gemini codex
match_threshold=95     # 0-100, minimum similarity % for quick-open
demo_mode="off"        # off | on — anonymize project names/paths for screenshots
hide_empty="on"        # on | off — hide folders with no files
_load_prefs() {
    [[ -f "$PREFS_FILE" ]] || return 0
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            view_mode)    view_mode="$val" ;;
            display_mode) display_mode="$val" ;;
            sort_mode)    sort_mode="$val" ;;
            title_mode)   title_mode="$val" ;;
            auto_claude)      auto_claude="$val" ;;
            agent)            agent="$val" ;;
            match_threshold)  match_threshold="$val" ;;
            demo_mode)        demo_mode="$val" ;;
            hide_empty)       hide_empty="$val" ;;
        esac
    done < "$PREFS_FILE"
}

_save_prefs() {
    printf 'view_mode=%s\ndisplay_mode=%s\nsort_mode=%s\ntitle_mode=%s\nauto_claude=%s\nmatch_threshold=%s\ndemo_mode=%s\nagent=%s\nhide_empty=%s\n' \
        "$view_mode" "$display_mode" "$sort_mode" "$title_mode" "$auto_claude" "$match_threshold" "$demo_mode" "$agent" "$hide_empty" > "$PREFS_FILE"
}

_load_prefs

# ── Demo mode: anonymize sensitive data for screenshots ──────────
declare -A _demo_map=()
_demo_counter=0

# Word pools for generating fake project names
_demo_animals=(Falcon Eagle Panther Wolf Tiger Cobra Raven Phoenix Dragon Hawk
               Viper Lynx Bear Orca Puma Jaguar Osprey Fox Bison Crane)
_demo_adjectives=(Swift Bright Vivid Silent Rapid Bold Agile Prime Noble Spark
                  Crimson Azure Neon Iron Frost Solar Storm Cloud Echo Zen)
_demo_nouns=(Tracker Builder Vault Engine Relay Forge Nexus Beacon Pulse Signal
             Matrix Portal Bridge Runner Studio Scope Craft Harbor Anchor Grid)

_demo_name() {
    # Deterministic anonymized name for a given input string
    local input="$1"
    if [[ -n "${_demo_map[$input]:-}" ]]; then
        printf '%s' "${_demo_map[$input]}"
        return
    fi
    local adj_i=$(( _demo_counter % ${#_demo_adjectives[@]} ))
    local noun_i=$(( _demo_counter / ${#_demo_adjectives[@]} % ${#_demo_nouns[@]} ))
    local name="${_demo_adjectives[$adj_i]}${_demo_nouns[$noun_i]}"
    _demo_map["$input"]="$name"
    (( _demo_counter++ ))
    printf '%s' "$name"
}

_demo_path() {
    # Anonymize a path, keeping structure but replacing leaf names
    local p="$1"
    local base="${p##*/}"
    local anon_base
    anon_base=$(_demo_name "$base")
    printf '~/projects/%s' "$anon_base"
}

_demo_desc() {
    # Anonymize a description
    local desc="$1"
    [[ -z "$desc" ]] && return
    local anon
    anon=$(_demo_name "$desc")
    printf '%s project files' "$anon"
}

_demo_group() {
    # Anonymize a group name
    local g="$1"
    [[ -z "$g" ]] && return
    local animal_i
    animal_i=$(( $(printf '%s' "$g" | cksum | cut -d' ' -f1) % ${#_demo_animals[@]} ))
    printf 'Client %s' "${_demo_animals[$animal_i]}"
}

_apply_demo_mode() {
    # Replace cache arrays with anonymized versions. Call after load_dirs + _apply_groups_to_cache.
    [[ "$demo_mode" != "on" ]] && return
    _demo_map=()
    _demo_counter=0

    local total=${#dirs[@]}
    for (( i = 0; i < total; i++ )); do
        cache_title[$i]="$(_demo_name "${cache_title[$i]}")"
        cache_base[$i]="$(_demo_name "${cache_base[$i]}")"
        cache_desc[$i]="$(_demo_desc "${cache_desc[$i]}")"
        cache_fullpath[$i]="$(_demo_path "${cache_fullpath[$i]}")"
        if [[ -n "${cache_group[$i]:-}" ]]; then
            cache_group[$i]="$(_demo_group "${cache_group[$i]}")"
        fi
    done

    # Also anonymize group_map display (groups screen reads from this)
    local -A new_group_map=()
    for path in "${!group_map[@]}"; do
        local anon_g
        anon_g=$(_demo_group "${group_map[$path]}")
        new_group_map["$path"]="$anon_g"
    done
    for path in "${!group_map[@]}"; do
        group_map["$path"]="${new_group_map[$path]}"
    done
}

# ── Open history (last-opened timestamps per directory) ──────────
declare -A open_history=()

_load_history() {
    open_history=()
    [[ -f "$HISTORY_FILE" ]] || return 0
    while IFS=$'\t' read -r ts path; do
        [[ -z "$ts" || "$ts" == \#* ]] && continue
        open_history["$path"]="$ts"
    done < "$HISTORY_FILE"
}

_save_history() {
    {
        printf '# claudemanager open history\n'
        for path in "${!open_history[@]}"; do
            printf '%s\t%s\n' "${open_history[$path]}" "$path"
        done
    } > "$HISTORY_FILE"
}

_record_open() {
    local dir="$1"
    open_history["$dir"]="$(date '+%s')"
    _save_history
}

_load_history

# ── Groups / client persistence ──────────────────────────────────
_load_groups() {
    # Reset associative array without converting to indexed
    for _k in "${!group_map[@]}"; do unset 'group_map[$_k]'; done
    cache_group=()
    [[ -f "$GROUPS_FILE" ]] || return 0
    while IFS=$'\t' read -r gname gpath; do
        [[ -z "$gname" || "$gname" == \#* ]] && continue
        group_map["$gpath"]="$gname"
    done < "$GROUPS_FILE"
}

_apply_groups_to_cache() {
    # Call after load_dirs to populate cache_group[] from group_map[]
    cache_group=()
    local total=${#dirs[@]}
    for (( i = 0; i < total; i++ )); do
        local rp
        rp=$(realpath "${dirs[$i]}" 2>/dev/null) || rp="${dirs[$i]}"
        cache_group+=("${group_map[$rp]:-}")
    done
}

_save_groups() {
    {
        printf '# claudemanager groups - auto-generated\n'
        for path in "${!group_map[@]}"; do
            printf '%s\t%s\n' "${group_map[$path]}" "$path"
        done
    } > "$GROUPS_FILE"
}

_set_project_group() {
    local idx="$1" gname="$2"
    local rp
    rp=$(realpath "${dirs[$idx]}" 2>/dev/null) || rp="${dirs[$idx]}"
    if [[ -z "$gname" ]]; then
        unset 'group_map[$rp]'
        cache_group[$idx]=""
    else
        group_map["$rp"]="$gname"
        cache_group[$idx]="$gname"
    fi
    _save_groups
}

_get_all_group_names() {
    local -A seen=()
    for g in "${group_map[@]}"; do
        [[ -n "$g" ]] && seen["$g"]=1
    done
    for g in "${!seen[@]}"; do
        printf '%s\n' "$g"
    done | sort
}

_suggest_groups_for() {
    # Suggest groups for project at index $1, best first.
    local idx="$1"
    local title="${cache_title[$idx]}"
    local title_lower="${title,,}"
    local total=${#dirs[@]}

    local -A scored=()

    # Score existing groups by prefix similarity with their member titles
    local -A group_titles=()
    for (( i = 0; i < total; i++ )); do
        local g="${cache_group[$i]}"
        [[ -z "$g" ]] && continue
        group_titles["$g"]+="${cache_title[$i],,}"$'\n'
    done

    for g in "${!group_titles[@]}"; do
        local best=0
        while IFS= read -r member_title; do
            [[ -z "$member_title" ]] && continue
            local plen=0
            local ml=${#member_title} tl=${#title_lower}
            local maxl=$(( ml < tl ? ml : tl ))
            for (( c = 0; c < maxl; c++ )); do
                [[ "${title_lower:$c:1}" == "${member_title:$c:1}" ]] || break
                (( plen++ ))
            done
            local denom=$(( ml > tl ? ml : tl ))
            (( denom == 0 )) && continue
            local score=$(( plen * 100 / denom ))
            (( score > best )) && best=$score
        done <<< "${group_titles[$g]}"
        (( best >= 40 )) && scored["$g"]=$best
    done

    local -a sorted=()
    for g in "${!scored[@]}"; do
        sorted+=("$(printf '%03d\t%s' "${scored[$g]}" "$g")")
    done
    if (( ${#sorted[@]} > 0 )); then
        IFS=$'\n' sorted=($(sort -rn <<< "${sorted[*]}")); unset IFS
        for entry in "${sorted[@]}"; do
            printf '%s\n' "${entry#*	}"
        done
    fi
}

# ── Cache arrays (parallel to dirs[]) ────────────────────────────
declare -a dirs=()
declare -a cache_title=()      # prominent app name
declare -a cache_base=()       # directory basename
declare -a cache_date=()
declare -a cache_reldate=()
declare -a cache_desc=()       # contents description
declare -a cache_files=()
declare -a cache_lang=()
declare -a cache_langcolor=()
declare -a cache_framework=()
declare -a cache_source=()     # "local" | "external" | "discovered"
declare -a cache_fullpath=()   # full path for display on external dirs
declare -a cache_mtime=()      # directory mtime (for save without re-stat)
declare -a cache_recent=()     # max mtime of any file in the tree (for "modified" sort)
declare -a cache_group=()      # group/client name per project

# ── Active harness sessions ────────────────────────────────────────
declare -A _session_status=()   # cwd -> status string ("waiting"|"running"|"idle")
declare -A _session_waiting=()  # cwd -> waitingFor string (if any)

_refresh_sessions() {
    _session_status=()
    _session_waiting=()
    local sessions_dir="$HOME/.claude/sessions"
    [[ -d "$sessions_dir" ]] || return 0
    local jf
    for jf in "$sessions_dir"/*.json; do
        [[ -f "$jf" ]] || continue
        local cwd="" status="" waitingFor="" pid=""
        # Parse JSON fields with awk (no jq dependency)
        while IFS= read -r line; do
            [[ "$line" =~ \"cwd\":\"([^\"]+)\" ]]        && cwd="${BASH_REMATCH[1]}"
            [[ "$line" =~ \"status\":\"([^\"]+)\" ]]     && status="${BASH_REMATCH[1]}"
            [[ "$line" =~ \"waitingFor\":\"([^\"]+)\" ]] && waitingFor="${BASH_REMATCH[1]}"
            [[ "$line" =~ \"pid\":([0-9]+) ]]            && pid="${BASH_REMATCH[1]}"
        done < "$jf"
        [[ -z "$cwd" || -z "$status" ]] && continue
        # Verify process is actually alive
        [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && continue
        _session_status["$cwd"]="$status"
        _session_waiting["$cwd"]="$waitingFor"
    done
}
declare -A group_map=()        # group_map["path"] = "group_name"

_load_groups

# ── Filtered view (indices into dirs[]) ──────────────────────────
declare -a filtered=()

apply_filter() {
    filtered=()
    local i
    for (( i = 0; i < ${#dirs[@]}; i++ )); do
        if [[ "$hide_empty" == "on" && "${cache_desc[$i]}" == "(empty project)" ]]; then
            continue
        fi
        if [[ -z "$search_query" ]]; then
            filtered+=("$i")
        else
            local haystack="${cache_title[$i]}|${cache_desc[$i]}|${cache_lang[$i]}|${cache_framework[$i]}|${cache_base[$i]}|${cache_fullpath[$i]}"
            local query_lower="${search_query,,}"
            local haystack_lower="${haystack,,}"
            if [[ "$haystack_lower" == *"$query_lower"* ]]; then
                filtered+=("$i")
            fi
        fi
    done
}

# ── Compute helpers (called once per dir at load time) ────────────

# Auto-detect the "app title" - the main project name
_compute_title() {
    local dir="$1"
    # 1. If .name file exists, use it
    if [[ -f "$dir/.name" ]]; then
        cat "$dir/.name"
        return
    fi
    local _ct_base="${dir##*/}"
    # 2. Look for a single prominent subdirectory (skip .hidden, xcodeproj, etc)
    local app_dirs=()
    for f in "$dir"/*/; do
        [[ -d "$f" ]] || continue
        local name
        name=$(basename "$f")
        [[ "$name" == .* || "$name" == "build" || "$name" == ".build" ]] && continue
        [[ "$name" == *.xcodeproj || "$name" == *.xcworkspace ]] && continue
        [[ "$name" == *.godot || "$name" == .godot ]] && continue
        app_dirs+=("$name")
    done
    if (( ${#app_dirs[@]} == 1 )); then
        local _ct_name="${app_dirs[0]}"
        # If the subdir name is short, qualify it with the parent project dir for clarity (e.g. "pub" → "truthinjesus/pub")
        if (( ${#_ct_name} <= 4 )) && [[ -n "$_ct_base" ]]; then
            printf '%s/%s' "$_ct_base" "$_ct_name"
        else
            printf '%s' "$_ct_name"
        fi
        return
    fi
    # 2b. Multiple dirs: find longest common prefix (e.g. BobcatHunter, BobcatHunter-Godot → BobcatHunter)
    if (( ${#app_dirs[@]} > 1 )); then
        local prefix="${app_dirs[0]}"
        for name in "${app_dirs[@]:1}"; do
            while [[ "${name}" != "${prefix}"* && -n "$prefix" ]]; do
                prefix="${prefix%?}"
            done
        done
        # Strip trailing separators and require a meaningful prefix (3+ chars)
        prefix="${prefix%-}"
        prefix="${prefix%_}"
        if (( ${#prefix} >= 3 )); then
            if (( ${#prefix} <= 4 )) && [[ -n "$_ct_base" ]]; then
                printf '%s/%s' "$_ct_base" "$prefix"
            else
                printf '%s' "$prefix"
            fi
            return
        fi
    fi
    # 2c. Timestamped scratch dir with no clear subdir name → pretty date "Mon DD HH:MM"
    if [[ "$_ct_base" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})[_-]([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
        local _ct_pretty
        _ct_pretty=$(date -j -f '%Y%m%d%H%M%S' \
            "${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}" \
            '+%b %d %H:%M' 2>/dev/null)
        if [[ -n "$_ct_pretty" ]]; then
            printf '%s' "$_ct_pretty"
            return
        fi
    fi
    # 3. Fall back to directory basename — qualify with parent dir if too short
    local _ct_self="${dir##*/}"
    if (( ${#_ct_self} <= 4 )); then
        local _ct_parent="${dir%/*}"
        _ct_parent="${_ct_parent##*/}"
        if [[ -n "$_ct_parent" && "$_ct_parent" != "$_ct_self" ]]; then
            printf '%s/%s' "$_ct_parent" "$_ct_self"
            return
        fi
    fi
    printf '%s' "$_ct_self"
}

_compute_date() {
    local base
    base=$(basename "$1")
    if [[ "$base" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
        printf '%s-%s-%s %s:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
    elif [[ "$base" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{6})$ ]]; then
        local t="${BASH_REMATCH[4]}"
        printf '%s-%s-%s %s:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${t:0:2}" "${t:2:2}"
    else
        stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null || echo "unknown"
    fi
}

_compute_reldate() {
    local dir="$1"
    local base
    base=$(basename "$dir")
    local then_epoch=""

    if [[ "$base" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
        local y="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" d="${BASH_REMATCH[3]}"
        then_epoch=$(date -j -f '%Y%m%d' "${y}${m}${d}" '+%s' 2>/dev/null) || { echo ""; return; }
    elif [[ "$base" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{6})$ ]]; then
        local y="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" d="${BASH_REMATCH[3]}"
        then_epoch=$(date -j -f '%Y%m%d' "${y}${m}${d}" '+%s' 2>/dev/null) || { echo ""; return; }
    else
        then_epoch=$(stat -f '%m' "$dir" 2>/dev/null) || { echo ""; return; }
    fi

    [[ -z "$then_epoch" ]] && { echo ""; return; }
    local now_epoch diff_days
    now_epoch=$(date '+%s')
    diff_days=$(( (now_epoch - then_epoch) / 86400 ))
    if (( diff_days == 0 )); then
        printf 'today'
    elif (( diff_days == 1 )); then
        printf 'yesterday'
    elif (( diff_days < 7 )); then
        printf '%dd ago' "$diff_days"
    elif (( diff_days < 30 )); then
        printf '%dw ago' $(( diff_days / 7 ))
    elif (( diff_days < 365 )); then
        printf '%dmo ago' $(( diff_days / 30 ))
    else
        printf '%dy ago' $(( diff_days / 365 ))
    fi
}

_compute_desc() {
    local dir="$1"
    if [[ -f "$dir/.description" ]]; then
        cat "$dir/.description"
        return
    fi
    local projects=()
    for f in "$dir"/*/; do
        [[ -d "$f" ]] || continue
        local name
        name=$(basename "$f")
        [[ "$name" == .* || "$name" == "build" || "$name" == ".build" ]] && continue
        [[ "$name" == *.xcodeproj || "$name" == *.godot || "$name" == .godot ]] && continue
        projects+=("$name")
    done
    if (( ${#projects[@]} > 0 )); then
        local IFS=", "
        printf '%s' "${projects[*]}"
    else
        local files=()
        for f in "$dir"/*; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f")
            [[ "$name" == .* ]] && continue
            files+=("$name")
        done
        if (( ${#files[@]} > 0 )); then
            local IFS=", "
            printf '%s' "${files[*]}"
        else
            printf '(empty project)'
        fi
    fi
}

_compute_filecount() {
    find "$1" -maxdepth 4 -type f \
        -not -path '*/.git/*' -not -path '*/.build/*' \
        -not -path '*/build/*' -not -path '*/.godot/*' \
        -not -path '*/node_modules/*' \
        -not -name '.DS_Store' -not -name '*.o' \
        2>/dev/null | wc -l | tr -d ' '
}


# Max mtime of any file in the tree (for "modified" sort)
_compute_recent() {
    local maxv
    maxv=$(find "$1" -maxdepth 4 -type f \
        -not -path '*/.git/*' -not -path '*/.build/*' \
        -not -path '*/build/*' -not -path '*/.godot/*' \
        -not -path '*/node_modules/*' \
        -not -name '.DS_Store' -not -name '*.o' \
        -print0 2>/dev/null \
        | xargs -0 stat -f '%m' 2>/dev/null \
        | sort -nr | head -1)
    printf '%s' "${maxv:-0}"
}

# Top-N most-recently-modified files (relative path, mtime) — for details panel
_compute_recent_files() {
    local d="$1" n="${2:-5}"
    find "$d" -maxdepth 4 -type f \
        -not -path '*/.git/*' -not -path '*/.build/*' \
        -not -path '*/build/*' -not -path '*/.godot/*' \
        -not -path '*/node_modules/*' \
        -not -name '.DS_Store' -not -name '*.o' \
        -print0 2>/dev/null \
        | xargs -0 stat -f '%m %N' 2>/dev/null \
        | sort -nr | head -n "$n"
}
_compute_language() {
    local dir="$1"
    local swift_count=0 py_count=0 js_count=0 ts_count=0 html_count=0
    local go_count=0 rs_count=0 rb_count=0 gd_count=0 sh_count=0
    local php_count=0 css_count=0

    while IFS= read -r f; do
        case "$f" in
            *.swift)      (( swift_count++ )) ;;
            *.py)         (( py_count++ )) ;;
            *.js|*.jsx)   (( js_count++ )) ;;
            *.ts|*.tsx)   (( ts_count++ )) ;;
            *.html)       (( html_count++ )) ;;
            *.go)         (( go_count++ )) ;;
            *.rs)         (( rs_count++ )) ;;
            *.rb)         (( rb_count++ )) ;;
            *.gd)         (( gd_count++ )) ;;
            *.sh)         (( sh_count++ )) ;;
            *.php)        (( php_count++ )) ;;
            *.css|*.scss) (( css_count++ )) ;;
        esac
    done < <(find "$dir" -maxdepth 4 -type f \
        -not -path '*/.git/*' -not -path '*/build/*' \
        -not -path '*/.build/*' -not -path '*/.godot/*' \
        -not -path '*/node_modules/*' 2>/dev/null)

    local max=0 lang="" lcolor=""
    if (( swift_count > max )); then max=$swift_count; lang="Swift"; lcolor="${bred}"; fi
    if (( py_count > max )); then max=$py_count; lang="Python"; lcolor="${byellow}"; fi
    if (( js_count > max )); then max=$js_count; lang="JavaScript"; lcolor="${byellow}"; fi
    if (( ts_count > max )); then max=$ts_count; lang="TypeScript"; lcolor="${bblue}"; fi
    if (( html_count > max )); then max=$html_count; lang="HTML"; lcolor="${bred}"; fi
    if (( go_count > max )); then max=$go_count; lang="Go"; lcolor="${bcyan}"; fi
    if (( rs_count > max )); then max=$rs_count; lang="Rust"; lcolor="${bred}"; fi
    if (( rb_count > max )); then max=$rb_count; lang="Ruby"; lcolor="${red}"; fi
    if (( gd_count > max )); then max=$gd_count; lang="GDScript"; lcolor="${bblue}"; fi
    if (( php_count > max )); then max=$php_count; lang="PHP"; lcolor="${bmagenta}"; fi
    if (( css_count > max )); then max=$css_count; lang="CSS"; lcolor="${bcyan}"; fi
    if (( sh_count > max && max == 0 )); then max=$sh_count; lang="Shell"; lcolor="${bgreen}"; fi

    local has_xcodeproj=false has_godot=false
    [[ -n $(find "$dir" -maxdepth 2 -name "*.xcodeproj" -print -quit 2>/dev/null) ]] && has_xcodeproj=true
    [[ -n $(find "$dir" -maxdepth 2 -name "project.godot" -print -quit 2>/dev/null) ]] && has_godot=true
    [[ -n $(find "$dir" -maxdepth 1 -type d -name "*Godot*" -print -quit 2>/dev/null) ]] && has_godot=true

    if [[ -z "$lang" ]]; then
        if $has_xcodeproj; then lang="Swift"; lcolor="${bred}"; fi
        if $has_godot; then lang="Godot"; lcolor="${bblue}"; fi
    fi

    local framework=""
    if $has_xcodeproj && [[ "$lang" == "Swift" ]]; then
        if grep -rql "UIKit\|UIApplication" "$dir" --include="*.swift" 2>/dev/null; then
            framework="iOS"
        elif grep -rql "AppKit\|NSApplication" "$dir" --include="*.swift" 2>/dev/null; then
            framework="macOS"
        elif grep -rql "SwiftUI" "$dir" --include="*.swift" 2>/dev/null; then
            framework="SwiftUI"
        else
            framework="Xcode"
        fi
    fi
    if $has_godot; then
        [[ -n "$framework" ]] && framework="$framework + Godot" || framework="Godot"
    fi

    _lang_name="$lang"
    _lang_color="$lcolor"
    _framework="$framework"
}

# ── Sorting ──────────────────────────────────────────────────────

sort_dirs() {
    local n=${#dirs[@]}
    (( n <= 1 )) && return

    # Build sortable keys
    local -a sort_keys=()
    local i
    for (( i = 0; i < n; i++ )); do
        case "$sort_mode" in
            date)
                # Use date string (reverse = newest first)
                sort_keys+=("${cache_date[$i]}|$i")
                ;;
            recent)
                # Use last-opened timestamp (reverse = most recent first)
                local opened="${open_history[${dirs[$i]}]:-0}"
                sort_keys+=("$(printf '%020d' "$opened")|$i")
                ;;
            name)
                sort_keys+=("${cache_title[$i],,}|$i")
                ;;
            language)
                local lk="${cache_lang[$i]}"
                [[ -z "$lk" ]] && lk="zzz"
                sort_keys+=("${lk,,}|$i")
                ;;
            modified)
                local rec="${cache_recent[$i]:-0}"
                sort_keys+=("$(printf '%020d' "$rec")|$i")
                ;;
        esac
    done

    # Sort and rebuild arrays
    local -a sorted_indices=()
    if [[ "$sort_mode" == "date" || "$sort_mode" == "recent" || "$sort_mode" == "modified" ]]; then
        while IFS= read -r line; do
            sorted_indices+=("${line##*|}")
        done < <(printf '%s\n' "${sort_keys[@]}" | sort -r)
    else
        while IFS= read -r line; do
            sorted_indices+=("${line##*|}")
        done < <(printf '%s\n' "${sort_keys[@]}" | sort)
    fi

    # Rebuild all parallel arrays in sorted order
    local -a new_dirs=() new_title=() new_base=() new_date=() new_reldate=()
    local -a new_desc=() new_files=() new_lang=() new_langcolor=() new_framework=()
    local -a new_source=() new_fullpath=() new_epoch=() new_mtime=() new_recent=()
    for i in "${sorted_indices[@]}"; do
        new_dirs+=("${dirs[$i]}")
        new_title+=("${cache_title[$i]}")
        new_base+=("${cache_base[$i]}")
        new_date+=("${cache_date[$i]}")
        new_reldate+=("${cache_reldate[$i]}")
        new_desc+=("${cache_desc[$i]}")
        new_files+=("${cache_files[$i]}")
        new_lang+=("${cache_lang[$i]}")
        new_langcolor+=("${cache_langcolor[$i]}")
        new_framework+=("${cache_framework[$i]}")
        new_source+=("${cache_source[$i]}")
        new_fullpath+=("${cache_fullpath[$i]}")
        new_epoch+=("${cache_epoch[$i]}")
        new_mtime+=("${cache_mtime[$i]:-}")
        new_recent+=("${cache_recent[$i]:-0}")
    done
    dirs=("${new_dirs[@]}")
    cache_title=("${new_title[@]}")
    cache_base=("${new_base[@]}")
    cache_date=("${new_date[@]}")
    cache_reldate=("${new_reldate[@]}")
    cache_desc=("${new_desc[@]}")
    cache_files=("${new_files[@]}")
    cache_lang=("${new_lang[@]}")
    cache_langcolor=("${new_langcolor[@]}")
    cache_framework=("${new_framework[@]}")
    cache_source=("${new_source[@]}")
    cache_fullpath=("${new_fullpath[@]}")
    cache_epoch=("${new_epoch[@]}")
    cache_mtime=("${new_mtime[@]}")
    cache_recent=("${new_recent[@]}")
}

# ── Disk cache for fast startup ──────────────────────────────────
declare -A disk_cache=()
declare -A _recent_files_memo=()

_get_recent_files_cached() {
    local d="$1"
    if [[ -z "${_recent_files_memo[$d]+x}" ]]; then
        _recent_files_memo["$d"]="$(_compute_recent_files "$d" 3)"
    fi
    printf '%s' "${_recent_files_memo[$d]}"
}
declare -a cache_epoch=()

# Sets $_lcolor variable (no subshell)
_set_lang_color() {
    case "$1" in
        Swift)      _lcolor="${bred}" ;;
        Python)     _lcolor="${byellow}" ;;
        JavaScript) _lcolor="${byellow}" ;;
        TypeScript) _lcolor="${bblue}" ;;
        HTML)       _lcolor="${bred}" ;;
        Go)         _lcolor="${bcyan}" ;;
        Rust)       _lcolor="${bred}" ;;
        Ruby)       _lcolor="${red}" ;;
        GDScript|Godot) _lcolor="${bblue}" ;;
        PHP)        _lcolor="${bmagenta}" ;;
        CSS)        _lcolor="${bcyan}" ;;
        Shell)      _lcolor="${bgreen}" ;;
        *)          _lcolor="" ;;
    esac
}

# Pure arithmetic reldate from epoch (sets $_reldate, no subshell)
_epoch_to_reldate() {
    local then_epoch="$1" now_epoch="$2"
    if [[ -z "$then_epoch" || "$then_epoch" == "0" ]]; then
        _reldate=""
        return
    fi
    local diff=$(( now_epoch - then_epoch ))
    if (( diff < 0 )); then _reldate=""
    elif (( diff < 60 )); then _reldate="just now"
    elif (( diff < 3600 )); then _reldate="$(( diff / 60 ))min ago"
    elif (( diff < 86400 )); then _reldate="$(( diff / 3600 ))hr ago"
    else
        local diff_days=$(( diff / 86400 ))
        if   (( diff_days == 1 )); then _reldate="yesterday"
        elif (( diff_days < 7 ));  then _reldate="${diff_days}d ago"
        elif (( diff_days < 30 )); then _reldate="$(( diff_days / 7 ))w ago"
        elif (( diff_days < 365 )); then _reldate="$(( diff_days / 30 ))mo ago"
        else _reldate="$(( diff_days / 365 ))y ago"
        fi
    fi
}

# Get epoch for a directory (subshell — only called on cache miss)
_compute_epoch() {
    local base="${1##*/}"
    if [[ "$base" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})[_-] ]]; then
        date -j -f '%Y%m%d' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}" '+%s' 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo "0"
    else
        stat -f '%m' "$1" 2>/dev/null || echo "0"
    fi
}

# ── Directory list cache (avoids slow find+realpath on "all" view) ─
_save_dirlist_cache() {
    local i
    {
        printf '# claudemanager dirlist cache - auto-generated\n'
        printf '# timestamp: %s\n' "$(date '+%s')"
        for (( i = 0; i < ${#tmp_dirs_saved[@]}; i++ )); do
            printf '%s\t%s\n' "${tmp_dirs_saved[$i]}" "${tmp_sources_saved[$i]}"
        done
    } > "$DIRLIST_CACHE"
}

_load_dirlist_cache() {
    cached_dirs=()
    cached_sources=()
    cached_dirlist_age=999999
    [[ -f "$DIRLIST_CACHE" ]] || return 1
    local now_epoch
    now_epoch=$(date '+%s')
    while IFS= read -r line; do
        if [[ "$line" == "# timestamp: "* ]]; then
            local ts="${line#\# timestamp: }"
            cached_dirlist_age=$(( now_epoch - ts ))
            continue
        fi
        [[ -z "$line" || "$line" == \#* ]] && continue
        local d src
        IFS=$'\t' read -r d src <<< "$line"
        # In local mode, skip non-local dirs from the cache
        if [[ "$view_mode" == "local" && "$src" != "local" && "$src" != "external" ]]; then
            continue
        fi
        cached_dirs+=("$d")
        cached_sources+=("$src")
    done < "$DIRLIST_CACHE"
    (( ${#cached_dirs[@]} > 0 ))
}

_load_disk_cache() {
    disk_cache=()
    [[ -f "$CACHE_FILE" ]] || return 0
    # Skip cache if schema version differs (forces a clean recompute when logic changes)
    local _cache_schema
    _cache_schema=$(awk -F': ' '/^# schema:/{print $2; exit}' "$CACHE_FILE")
    if [[ "$_cache_schema" != "$CACHE_SCHEMA" ]]; then
        return 0
    fi
    while IFS=$'\x1f' read -r c_path c_mtime c_title c_date c_desc c_files c_lang c_framework c_epoch c_recent; do
        [[ -z "$c_path" || "$c_path" == \#* ]] && continue
        disk_cache["$c_path"]="${c_mtime}"$'\x1f'"${c_title}"$'\x1f'"${c_date}"$'\x1f'"${c_desc}"$'\x1f'"${c_files}"$'\x1f'"${c_lang}"$'\x1f'"${c_framework}"$'\x1f'"${c_epoch}"$'\x1f'"${c_recent:-0}"
    done < "$CACHE_FILE"
}

_save_disk_cache() {
    local i
    {
        printf '# claudemanager cache - auto-generated\n'
        printf '# schema: %s\n' "$CACHE_SCHEMA"
        for (( i = 0; i < ${#dirs[@]}; i++ )); do
            local d="${dirs[$i]}"
            local mtime="${cache_mtime[$i]:-}"
            [[ -z "$mtime" ]] && mtime=$(stat -f '%m' "$d" 2>/dev/null || echo "0")
            local t="${cache_title[$i]//$'\x1f'/ }"
            local dt="${cache_date[$i]//$'\x1f'/ }"
            local ds="${cache_desc[$i]//$'\x1f'/ }"
            local f="${cache_files[$i]}"
            local l="${cache_lang[$i]}"
            local fw="${cache_framework[$i]//$'\x1f'/ }"
            local ep="${cache_epoch[$i]}"
            local rec="${cache_recent[$i]:-0}"
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$d" "$mtime" "$t" "$dt" "$ds" "$f" "$l" "$fw" "$ep" "$rec"
        done
    } > "$CACHE_FILE"
}

# ── Load & cache a single directory ──────────────────────────────
_cache_one_dir() {
    local d="$1" source="$2" use_cache="$3" dir_mtime="$4" now_epoch="$5"
    dirs+=("$d")
    cache_base+=("${d##*/}")   # builtin basename
    cache_source+=("$source")
    cache_fullpath+=("$d")
    cache_mtime+=("$dir_mtime")

    # Try disk cache (mtime-based invalidation; timestamp-named dirs are immutable identity → skip mtime check)
    local _ts_dir=false
    [[ "${d##*/}" =~ ^[0-9]{8}[_-][0-9]{6}$ ]] && _ts_dir=true
    if [[ "$use_cache" == "true" && ( -n "$dir_mtime" || "$_ts_dir" == "true" ) ]]; then
        local cached="${disk_cache[$d]:-}"
        if [[ -n "$cached" ]]; then
            local c_mtime c_title c_date c_desc c_files c_lang c_framework c_epoch c_recent
            IFS=$'\x1f' read -r c_mtime c_title c_date c_desc c_files c_lang c_framework c_epoch c_recent <<< "$cached"
            if [[ "$_ts_dir" == "true" || "$c_mtime" == "$dir_mtime" ]]; then
                cache_title+=("$c_title")
                cache_date+=("$c_date")
                local _eff_ep="$c_epoch"
                (( ${c_recent:-0} > _eff_ep )) && _eff_ep="${c_recent:-0}"
                _epoch_to_reldate "$_eff_ep" "$now_epoch"
                cache_reldate+=("$_reldate")
                cache_desc+=("$c_desc")
                cache_files+=("$c_files")
                cache_lang+=("$c_lang")
                _set_lang_color "$c_lang"
                cache_langcolor+=("$_lcolor")
                cache_framework+=("$c_framework")
                cache_epoch+=("$c_epoch")
                cache_recent+=("${c_recent:-0}")
                return
            fi
        fi
    fi

    # Cache miss - compute everything
    cache_title+=("$(_compute_title "$d")")
    cache_date+=("$(_compute_date "$d")")
    local ep rec
    ep=$(_compute_epoch "$d")
    cache_epoch+=("$ep")
    rec=$(_compute_recent "$d")
    cache_recent+=("$rec")
    local _eff_ep="$ep"
    (( ${rec:-0} > _eff_ep )) && _eff_ep="$rec"
    _epoch_to_reldate "$_eff_ep" "$now_epoch"
    cache_reldate+=("$_reldate")
    cache_desc+=("$(_compute_desc "$d")")
    cache_files+=("$(_compute_filecount "$d")")

    _lang_name="" _lang_color="" _framework=""
    _compute_language "$d"
    cache_lang+=("$_lang_name")
    cache_langcolor+=("$_lang_color")
    cache_framework+=("$_framework")
}

# ── Load & cache everything ───────────────────────────────────────
load_dirs() {
    local force="${1:-false}"
    dirs=()
    cache_title=()
    cache_base=()
    cache_date=()
    cache_reldate=()
    cache_desc=()
    cache_files=()
    cache_lang=()
    cache_langcolor=()
    cache_framework=()
    cache_source=()
    cache_fullpath=()
    cache_mtime=()
    cache_epoch=()
    cache_recent=()

    # Load disk cache for fast startup
    if [[ "$force" == "false" ]]; then
        _load_disk_cache
    else
        disk_cache=()
    fi

    # Collect all directories to scan
    local tmp_dirs=()
    local tmp_sources=()
    local used_dirlist_cache="false"

    # Try dirlist cache for instant startup (skip slow find+realpath)
    if [[ "$force" == "false" ]]; then
        local -a cached_dirs=()
        local -a cached_sources=()
        local cached_dirlist_age=999999
        if _load_dirlist_cache; then
            # Verify dirs still exist (fast: just stat, no realpath)
            for (( _ci = 0; _ci < ${#cached_dirs[@]}; _ci++ )); do
                if [[ -d "${cached_dirs[$_ci]}" ]]; then
                    tmp_dirs+=("${cached_dirs[$_ci]}")
                    tmp_sources+=("${cached_sources[$_ci]}")
                fi
            done
            if (( ${#tmp_dirs[@]} > 0 )); then
                used_dirlist_cache="true"
            fi
        fi
    fi

    # Full directory scan (no cache or force refresh)
    if [[ "$used_dirlist_cache" == "false" ]]; then
        tmp_dirs=()
        tmp_sources=()

        # 1. Local ~/util/claude dirs
        while IFS= read -r d; do
            [[ -d "$d" ]] || continue
            local base
            base=$(basename "$d")
            [[ "$base" == "claudemanager.sh" ]] && continue
            [[ "$base" == .* ]] && continue
            tmp_dirs+=("$d")
            tmp_sources+=("local")
        done < <(find "$CLAUDE_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)

        # 2. Always discover from ~/.claude/projects (cache stores superset)
        if [[ -d "$CLAUDE_PROJECTS_DIR" ]]; then
            local -A seen=()
            # Mark local dirs as seen (by realpath)
            for d in "${tmp_dirs[@]}"; do
                local rp
                rp=$(realpath "$d" 2>/dev/null) || rp="$d"
                seen["$rp"]=1
            done

            while IFS= read -r proj_dir; do
                [[ -d "$proj_dir" ]] || continue
                # Decode path: -Users-foo-bar => /Users/foo/bar
                # Claude Code encodes both "/" and "_" as "-" → walk the FS to disambiguate.
                local decoded_path=""
                # Preferred: read cwd from any session JSONL (authoritative — handles "_" in name)
                local _jf
                for _jf in "$proj_dir"/*.jsonl; do
                    [[ -f "$_jf" ]] || continue
                    decoded_path=$(grep -m1 -o '"cwd":"[^"]*"' "$_jf" 2>/dev/null | head -1 | sed 's/^"cwd":"//;s/"$//')
                    [[ -n "$decoded_path" ]] && break
                done
                # Fallback: lossy hyphen-to-slash decoding
                if [[ -z "$decoded_path" ]]; then
                    decoded_path=$(basename "$proj_dir" | sed 's/^-/\//; s/-/\//g')
                fi
                # Verify directory exists and isn't inside CLAUDE_BASE
                if [[ -n "$decoded_path" && -d "$decoded_path" ]]; then
                    local rp
                    rp=$(realpath "$decoded_path" 2>/dev/null) || rp="$decoded_path"
                    # Skip if already in local list
                    if [[ -z "${seen[$rp]:-}" ]]; then
                        # Skip CLAUDE_BASE itself and its parents
                        local cb_rp
                        cb_rp=$(realpath "$CLAUDE_BASE" 2>/dev/null) || cb_rp="$CLAUDE_BASE"
                        if [[ "$rp" != "$cb_rp" && "$rp" != "$cb_rp/"* ]]; then
                            seen["$rp"]=1
                            tmp_dirs+=("$decoded_path")
                            tmp_sources+=("discovered")
                        fi
                    fi
                fi
            done < <(find "$CLAUDE_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
        fi

        # 3. Extra dirs from .claudemanager_dirs
        if [[ -f "$EXTRA_DIRS_FILE" ]]; then
            local -A seen_extra=()
            for d in "${tmp_dirs[@]}"; do
                local rp
                rp=$(realpath "$d" 2>/dev/null) || rp="$d"
                seen_extra["$rp"]=1
            done
            while IFS= read -r line; do
                [[ -z "$line" || "$line" == \#* ]] && continue
                # Parent-scan: line ending in /* expands to direct subdirs
                if [[ "$line" == */\* ]]; then
                    local parent="${line%/\*}"
                    [[ -d "$parent" ]] || continue
                    local child
                    while IFS= read -r child; do
                        [[ -d "$child" ]] || continue
                        local cbase
                        cbase="${child##*/}"
                        [[ "$cbase" == .* ]] && continue
                        local crp
                        crp=$(realpath "$child" 2>/dev/null) || crp="$child"
                        if [[ -z "${seen_extra[$crp]:-}" ]]; then
                            seen_extra["$crp"]=1
                            tmp_dirs+=("$child")
                            tmp_sources+=("external")
                        fi
                    done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
                    continue
                fi
                if [[ -d "$line" ]]; then
                    local rp
                    rp=$(realpath "$line" 2>/dev/null) || rp="$line"
                    if [[ -z "${seen_extra[$rp]:-}" ]]; then
                        seen_extra["$rp"]=1
                        tmp_dirs+=("$line")
                        tmp_sources+=("external")
                    fi
                fi
            done < "$EXTRA_DIRS_FILE"
        fi
    fi

    # Save dirlist cache for next startup (only when we did a full scan)
    if [[ "$used_dirlist_cache" == "false" ]]; then
        local -a tmp_dirs_saved=("${tmp_dirs[@]}")
        local -a tmp_sources_saved=("${tmp_sources[@]}")
        _save_dirlist_cache
    fi

    # Apply ignore list (paths hidden via delete-prompt without "confirm")
    if [[ -f "$IGNORE_FILE" ]]; then
        local -A _ignore=()
        while IFS= read -r _il; do
            [[ -z "$_il" || "$_il" == \#* ]] && continue
            _ignore["$_il"]=1
        done < "$IGNORE_FILE"
        if (( ${#_ignore[@]} > 0 )); then
            local -a _fd=() _fs=()
            for (( _ig = 0; _ig < ${#tmp_dirs[@]}; _ig++ )); do
                if [[ -z "${_ignore[${tmp_dirs[$_ig]}]:-}" ]]; then
                    _fd+=("${tmp_dirs[$_ig]}")
                    _fs+=("${tmp_sources[$_ig]}")
                fi
            done
            tmp_dirs=("${_fd[@]}")
            tmp_sources=("${_fs[@]}")
        fi
    fi

    # Filter to current view_mode (dirlist cache stores superset)
    if [[ "$view_mode" == "local" ]]; then
        local -a filtered_dirs=() filtered_sources=()
        for (( _fi = 0; _fi < ${#tmp_dirs[@]}; _fi++ )); do
            case "${tmp_sources[$_fi]}" in
                local|external) filtered_dirs+=("${tmp_dirs[$_fi]}"); filtered_sources+=("${tmp_sources[$_fi]}") ;;
            esac
        done
        tmp_dirs=("${filtered_dirs[@]}")
        tmp_sources=("${filtered_sources[@]}")
    fi

    local use_cache="true"
    [[ "$force" == "true" ]] && use_cache="false"

    # Batch stat call: get all mtimes in one process
    local -a all_mtimes=()
    if [[ "$use_cache" == "true" && ${#tmp_dirs[@]} -gt 0 ]]; then
        while IFS= read -r mt; do
            all_mtimes+=("$mt")
        done < <(stat -f '%m' "${tmp_dirs[@]}" 2>/dev/null)
    fi

    # Get "now" once for all reldate computations
    local now_epoch
    now_epoch=$(date '+%s')

    # Pre-check: count expected cache misses
    local miss_count=0
    if [[ "$use_cache" == "false" ]]; then
        miss_count=${#tmp_dirs[@]}
    else
        for (( idx = 0; idx < ${#tmp_dirs[@]}; idx++ )); do
            local d="${tmp_dirs[$idx]}"
            local mt="${all_mtimes[$idx]:-}"
            local cached="${disk_cache[$d]:-}"
            local _ts_check=false
            [[ "${d##*/}" =~ ^[0-9]{8}[_-][0-9]{6}$ ]] && _ts_check=true
            if [[ -z "$cached" ]]; then
                (( miss_count++ ))
            elif [[ "$_ts_check" == "true" ]]; then
                : # timestamp dirs: any cached entry counts as a hit
            elif [[ -z "$mt" ]]; then
                (( miss_count++ ))
            else
                local c_mtime
                IFS=$'\x1f' read -r c_mtime _ <<< "$cached"
                if [[ "$c_mtime" != "$mt" ]]; then
                    (( miss_count++ ))
                fi
            fi
        done
    fi

    # Only show loading screen for many misses (>5) or force refresh
    local show_loading="false"
    if (( miss_count > 5 )) || [[ "$force" == "true" ]]; then
        show_loading="true"
        _stop_spinner
        clear_screen
        move_to 1 1
        local load_label="Loading"
        [[ "$force" == "true" ]] && load_label="Refreshing"
        tui '%s  %s %d projects...%s' "${bold}${cyan}" "$load_label" "${#tmp_dirs[@]}" "${reset}"
    fi

    local idx=0
    for (( idx = 0; idx < ${#tmp_dirs[@]}; idx++ )); do
        local d="${tmp_dirs[$idx]}"
        local src="${tmp_sources[$idx]}"
        local mt="${all_mtimes[$idx]:-}"

        _cache_one_dir "$d" "$src" "$use_cache" "$mt" "$now_epoch"

        # Show progress only when loading screen is visible
        if [[ "$show_loading" == "true" ]]; then
            if (( idx % 5 == 0 )) || (( idx == ${#tmp_dirs[@]} - 1 )); then
                move_to 2 1
                clear_line
                tui '  %s[%d/%d]%s %s' "${dim}" "$(( idx + 1 ))" "${#tmp_dirs[@]}" "${reset}" "${cache_title[-1]}"
            fi
        fi
    done

    sort_dirs
    apply_filter
    # Only save caches when something changed
    if (( miss_count > 0 )); then
        _save_disk_cache
    fi
}

refresh_cache() {
    local idx="$1"
    local d="${dirs[$idx]}"
    cache_title[$idx]="$(_compute_title "$d")"
    cache_base[$idx]="$(basename "$d")"
    cache_desc[$idx]="$(_compute_desc "$d")"
    cache_recent[$idx]="$(_compute_recent "$d")"
    unset '_recent_files_memo[$d]'
}

# ── Drawing ───────────────────────────────────────────────────────
draw() {
    _refresh_sessions
    local term_lines term_cols
    term_lines=$(tput_lines)
    term_cols=$(tput_cols)

    _mouse_display_mode="$display_mode"
    # Details panel reserves N lines at the bottom for the selected item
    local details_height=8
    if (( ${#filtered[@]} == 0 )); then details_height=0; fi
    if (( term_lines < 24 )); then details_height=0; fi
    local effective_lines=$(( term_lines - details_height ))

    clear_screen

    # ── Header ──
    move_to 1 1
    tui '%s' "${bg_bblue}${bold}${white}"
    tui '                              '
    move_to 1 1
    tui '%s  C L A U D E   M A N A G E R  %s' "${bg_bblue}${bold}${white}" "${reset}"
    tui '  %sv2.5.5 · %s%s' "${dim}" "$BUILD_DATE" "${reset}"
    local count_label="${#filtered[@]}"
    if [[ -n "$search_query" ]]; then
        count_label="${#filtered[@]}/${#dirs[@]}"
    fi
    tui '  %s%s projects%s' "${dim}" "$count_label" "${reset}"

    # View + sort indicators
    local view_label="local"
    [[ "$view_mode" == "all" ]] && view_label="all projects"
    local mode_label=""
    [[ "$display_mode" != "full" ]] && mode_label=" | $display_mode"
    tui '  %s[%s | sort:%s%s]%s' "${dim}${italic}" "$view_label" "$sort_mode" "$mode_label" "${reset}"

    # Keybindings bar — drawn via _draw_btn so clicks map back to keys
    # Wraps to a second line automatically when terminal is too narrow.
    _mouse_btn_rows=(); _mouse_btn_starts=(); _mouse_btn_ends=(); _mouse_btn_keys=()
    _btn_row=2
    _btn_col=2
    _btn_max_col=$(( term_cols - 1 ))
    _draw_btn "enter"  "open"      ""  "${bg_gray}"    "${bwhite}${bold}"
    _draw_btn "A"      "open with" "A" "${bg_magenta}" "${white}${bold}"
    _draw_btn "/"      "search"    "/" "${bg_bblue}"   "${white}${bold}"
    _draw_btn "n"      "new"       "n" "${bg_green}"   "${black}${bold}"
    _draw_btn "N"      "new with"  "N" "${bg_green}"   "${black}${bold}"
    _draw_btn "p"      "all"       "p" "${bg_cyan}"    "${black}${bold}"
    _draw_btn "t"      "sort"      "t" "${bg_yellow}"  "${black}${bold}"
    _draw_btn "c"      "view"      "c" "${bg_yellow}"  "${black}${bold}"
    _draw_btn "a"      "add"       "a" "${bg_green}"   "${black}${bold}"
    _draw_btn "R"      "rename"    "R" "${bg_cyan}"    "${black}${bold}"
    _draw_btn "f"      "refresh"   "f" "${bg_magenta}" "${white}${bold}"
    _draw_btn "g"      "group"     "g" "${bg_green}"   "${black}${bold}"
    _draw_btn "#"      "auto-grp"  "#" "${bg_magenta}" "${white}${bold}"
    _draw_btn "S"      "stats"     "S" "${bg_cyan}"    "${black}${bold}"
    _draw_btn "d"      "del"       "d" "${bg_red}"     "${white}${bold}"
    _draw_btn ","      "settings"  "," "${bg_gray}"    "${bwhite}${bold}"
    _draw_btn "?"      "about"     "?" "${bg_gray}"    "${bwhite}${bold}"
    _draw_btn "q"      "quit"      "q" "${bg_gray}"    "${bwhite}${bold}"

    # header_end = row after the last button row (= separator row)
    local _sep_row=$(( _btn_row + 1 ))
    local header_end="$_sep_row"

    # Search bar (if active)
    if [[ -n "$search_query" ]]; then
        move_to "$_sep_row" 1
        tui '  %s/%s %s%s%s' "${bblue}${bold}" "${reset}" "${bwhite}${bold}" "$search_query" "${reset}"
        (( header_end++ ))
        move_to "$header_end" 1
    else
        move_to "$_sep_row" 1
    fi

    # Separator
    local sep_len=$(( term_cols - 4 ))
    (( sep_len > 90 )) && sep_len=90
    tui '  %s%s%s' "${dim}${cyan}" "$(printf '%*s' "$sep_len" '' | tr ' ' '-')" "${reset}"

    # ── List area ──
    local list_start=$(( header_end + 1 ))
    _mouse_list_start="$list_start"

    if [[ "$display_mode" == "grid" ]]; then
        # ── GRID MODE ──
        local cell_width=24
        local cell_height=2
        local grid_cols=$(( (term_cols - 2) / cell_width ))
        (( grid_cols < 1 )) && grid_cols=1
        _mouse_cell_width="$cell_width"
        _mouse_cell_height="$cell_height"
        _mouse_grid_cols="$grid_cols"
        local grid_rows=$(( (effective_lines - list_start - 2) / cell_height ))
        (( grid_rows < 1 )) && grid_rows=1
        local max_items=$(( grid_cols * grid_rows ))

        # Snap scroll to row boundaries for clean grid rendering
        if (( selected < scroll_offset )); then
            scroll_offset=$(( (selected / grid_cols) * grid_cols ))
        elif (( selected >= scroll_offset + max_items )); then
            local sel_row=$(( selected / grid_cols ))
            local top_row=$(( sel_row - grid_rows + 1 ))
            (( top_row < 0 )) && top_row=0
            scroll_offset=$(( top_row * grid_cols ))
        fi

        if (( ${#filtered[@]} == 0 )); then
            move_to "$list_start" 4
            if [[ -n "$search_query" ]]; then
                tui '%sNo matches for "%s"%s' "${dim}${yellow}" "$search_query" "${reset}"
            else
                tui '%sNo projects found%s' "${dim}" "${reset}"
            fi
        fi

        local i
        for (( i = 0; i < max_items && i + scroll_offset < ${#filtered[@]}; i++ )); do
            local fidx=$(( i + scroll_offset ))
            local idx="${filtered[$fidx]}"
            local title="${cache_title[$idx]}"
            local lang_name="${cache_lang[$idx]}"
            local lang_color="${cache_langcolor[$idx]}"

            local grid_r=$(( i / grid_cols ))
            local grid_c=$(( i % grid_cols ))
            local row=$(( list_start + grid_r * cell_height ))
            local col=$(( 2 + grid_c * cell_width ))

            # Truncate title to fit cell
            local max_title=$(( cell_width - 4 ))
            local disp_title="$title"
            if (( ${#disp_title} > max_title )); then
                disp_title="${disp_title:0:$((max_title - 1))}…"
            fi

            move_to "$row" "$col"
            if (( fidx == selected )); then
                tui '%s %s %s' "${bg_sel}${bwhite}${bold}" "$disp_title" "${reset}"
            else
                tui ' %s%s%s' "${bold}${bwhite}" "$disp_title" "${reset}"
            fi

            # Second row: language tag
            move_to $(( row + 1 )) "$col"
            if [[ -n "$lang_name" ]]; then
                local disp_lang="$lang_name"
                if (( ${#disp_lang} > max_title )); then
                    disp_lang="${disp_lang:0:$((max_title - 1))}…"
                fi
                tui ' %s%s%s' "${lang_color}${dim}" "$disp_lang" "${reset}"
            else
                tui ' %s--%s' "${dim}" "${reset}"
            fi
        done

        # Scroll indicators for grid
        if (( scroll_offset > 0 )); then
            move_to $(( list_start - 1 )) 3
            tui '%s^ more above%s' "${byellow}${bold}" "${reset}"
        fi
        if (( scroll_offset + max_items < ${#filtered[@]} )); then
            local bottom_row=$(( list_start + grid_rows * cell_height ))
            (( bottom_row > effective_lines - 1 )) && bottom_row=$(( effective_lines - 1 ))
            move_to "$bottom_row" 3
            tui '%sv more below%s' "${byellow}${bold}" "${reset}"
        fi
    else
        # ── LIST MODES (compact / full) ──
        local row_height=3
        [[ "$display_mode" == "compact" ]] && row_height=1
        _mouse_row_height="$row_height"
        local max_rows=$(( (effective_lines - list_start - 2) / row_height ))
        (( max_rows < 1 )) && max_rows=1

        # Two-column layout for compact mode when terminal is wide enough
        local use_two_cols=false
        local col_width=$term_cols
        local right_col_start=1
        if [[ "$display_mode" == "compact" && term_cols -ge 120 ]]; then
            use_two_cols=true
            col_width=$(( term_cols / 2 - 1 ))
            right_col_start=$(( col_width + 2 ))
        fi

        local max_items=$max_rows
        [[ "$use_two_cols" == "true" ]] && max_items=$(( max_rows * 2 ))

        _mouse_list_cols=1
        _mouse_list_max_rows=$max_rows
        _mouse_right_col_start=9999
        if [[ "$use_two_cols" == "true" ]]; then
            _mouse_list_cols=2
            _mouse_right_col_start=$right_col_start
        fi

        if (( selected < scroll_offset )); then
            scroll_offset=$selected
        elif (( selected >= scroll_offset + max_items )); then
            scroll_offset=$(( selected - max_items + 1 ))
        fi

        if (( ${#filtered[@]} == 0 )); then
            move_to "$list_start" 4
            if [[ -n "$search_query" ]]; then
                tui '%sNo matches for "%s"%s' "${dim}${yellow}" "$search_query" "${reset}"
            else
                tui '%sNo projects found%s' "${dim}" "${reset}"
            fi
        fi

        local i
        for (( i = 0; i < max_items && i + scroll_offset < ${#filtered[@]}; i++ )); do
            local fidx=$(( i + scroll_offset ))
            local idx="${filtered[$fidx]}"
            local title="${cache_title[$idx]}"
            local base="${cache_base[$idx]}"
            local date="${cache_date[$idx]}"
            local rel_date="${cache_reldate[$idx]}"
            local desc="${cache_desc[$idx]}"
            local file_count="${cache_files[$idx]}"
            local lang_name="${cache_lang[$idx]}"
            local lang_color="${cache_langcolor[$idx]}"
            local framework="${cache_framework[$idx]}"
            local source="${cache_source[$idx]}"
            local fullpath="${cache_fullpath[$idx]}"

            local row col_start
            if [[ "$use_two_cols" == "true" ]]; then
                local _col=$(( i / max_rows ))
                local _row_in_col=$(( i % max_rows ))
                row=$(( list_start + _row_in_col ))
                col_start=$(( _col == 0 ? 1 : right_col_start ))
            else
                row=$(( list_start + i * row_height ))
                col_start=1
            fi

            # Source badge for non-local dirs
            local source_badge=""
            if [[ "$source" == "discovered" ]]; then
                source_badge="${dim}${bcyan} [claude]${reset}"
            elif [[ "$source" == "external" ]]; then
                source_badge="${dim}${bcyan} [added]${reset}"
            fi

            if [[ "$display_mode" == "compact" ]]; then
                # ── COMPACT MODE: single row per project ──
                # Truncate title to fit within column
                local max_title=$(( col_width - 30 ))
                (( max_title < 8 )) && max_title=8
                local display_title="$title"
                if (( ${#display_title} > max_title )); then
                    display_title="${display_title:0:$(( max_title - 1 ))}…"
                fi
                move_to "$row" "$col_start"
                if (( fidx == selected )); then
                    tui '  %s>%s ' "${bgreen}${bold}" "${reset}"
                    tui '%s %s %s' "${bg_sel}${bwhite}${bold}" "$display_title" "${reset}"
                else
                    tui '  %s>%s ' "${dim}" "${reset}"
                    tui '%s%s%s' "${bold}${bwhite}" "$display_title" "${reset}"
                fi
                if [[ -n "$lang_name" ]]; then
                    tui '  %s%s%s' "${lang_color}" "$lang_name" "${reset}"
                fi
                if [[ -n "$framework" ]]; then
                    tui ' %s%s%s' "${dim}${italic}" "$framework" "${reset}"
                fi
                tui '  %s%s%s' "${dim}" "$rel_date" "${reset}"
                tui '%s' "$source_badge"
                if [[ -n "${cache_group[$idx]:-}" ]]; then
                    tui '  %s{%s}%s' "${dim}${bmagenta}" "${cache_group[$idx]}" "${reset}"
                fi
                # Harness status badge
                local _sess_stat="${_session_status[$fullpath]:-}"
                if [[ -n "$_sess_stat" ]]; then
                    local _sess_wait="${_session_waiting[$fullpath]:-}"
                    case "$_sess_stat" in
                        waiting) tui '  %s●%s %s%s' "${byellow}${bold}" "${reset}${dim}" "${_sess_wait:-waiting}" "${reset}" ;;
                        running) tui '  %s●%s %srunning%s' "${bgreen}${bold}" "${reset}${dim}" "" "${reset}" ;;
                        idle)    tui '  %s●%s %sidle%s'    "${dim}"         "${reset}${dim}" "" "${reset}" ;;
                        *)       tui '  %s●%s %s%s'        "${dim}"         "${reset}${dim}" "$_sess_stat" "${reset}" ;;
                    esac
                fi
            else
                # ── FULL MODE: 3 rows per project ──

                # Truncate desc
                local max_desc_len=$(( term_cols - 10 ))
                (( max_desc_len > 70 )) && max_desc_len=70
                if (( ${#desc} > max_desc_len )); then
                    desc="${desc:0:$((max_desc_len - 3))}..."
                fi

                # Check if base is a timestamp (all digits + underscore)
                local base_is_ts=false
                [[ "$base" =~ ^[0-9_]+$ ]] && base_is_ts=true

                # For external dirs, show path instead of base
                local display_path="$base"
                if [[ "$source" != "local" ]]; then
                    display_path="${fullpath/#$HOME/~}"
                fi

                # Compute harness badge once for both selected/unselected
                local _sess_badge=""
                local _fp_stat="${_session_status[$fullpath]:-}"
                if [[ -n "$_fp_stat" ]]; then
                    local _fp_wait="${_session_waiting[$fullpath]:-}"
                    case "$_fp_stat" in
                        waiting) _sess_badge="  ${byellow}${bold}●${reset}${dim} ${_fp_wait:-waiting}${reset}" ;;
                        running) _sess_badge="  ${bgreen}${bold}●${reset}${dim} running${reset}" ;;
                        idle)    _sess_badge="  ${dim}● idle${reset}" ;;
                        *)       _sess_badge="  ${dim}● ${_fp_stat}${reset}" ;;
                    esac
                fi

                if (( fidx == selected )); then
                    # ── SELECTED ──
                    move_to "$row" 1
                    tui '  %s>%s ' "${bgreen}${bold}" "${reset}"
                    tui '%s %s %s' "${bg_sel}${bwhite}${bold}" "$title" "${reset}"

                    if [[ -n "$lang_name" ]]; then
                        tui '  %s%s%s' "${lang_color}${bold}" "$lang_name" "${reset}"
                    fi
                    if [[ -n "$framework" ]]; then
                        tui ' %s%s%s' "${dim}${italic}" "$framework" "${reset}"
                    fi
                    tui '%s' "$source_badge"
                    [[ -n "$_sess_badge" ]] && tui '%s' "$_sess_badge"

                    move_to $(( row + 1 )) 1
                    if [[ "$desc" != "$title" ]]; then
                        tui '      %s%s%s' "${cyan}" "$desc" "${reset}"
                    fi

                    move_to $(( row + 2 )) 1
                    if $base_is_ts; then
                        tui '      %s%s%s' "${dim}${yellow}" "$display_path" "${reset}"
                    else
                        tui '      %s%s%s' "${dim}" "$display_path" "${reset}"
                    fi
                    tui '  %s%s%s' "${bold}${yellow}" "$rel_date" "${reset}"
                    tui '  %s%s  %s files%s' "${dim}" "$date" "$file_count" "${reset}"

                else
                    # ── UNSELECTED ──
                    move_to "$row" 1
                    tui '  %s>%s ' "${dim}" "${reset}"
                    tui '%s%s%s' "${bold}${bwhite}" "$title" "${reset}"

                    if [[ -n "$lang_name" ]]; then
                        tui '  %s%s%s' "${lang_color}${bold}" "$lang_name" "${reset}"
                    fi
                    if [[ -n "$framework" ]]; then
                        tui ' %s%s%s' "${dim}${italic}" "$framework" "${reset}"
                    fi
                    tui '%s' "$source_badge"
                    [[ -n "$_sess_badge" ]] && tui '%s' "$_sess_badge"

                    move_to $(( row + 1 )) 1
                    if [[ "$desc" != "$title" ]]; then
                        tui '      %s%s%s' "${dim}" "$desc" "${reset}"
                    fi

                    move_to $(( row + 2 )) 1
                    if $base_is_ts; then
                        tui '      %s%s%s' "${dim}" "$display_path" "${reset}"
                    else
                        tui '      %s%s%s' "${dim}" "$display_path" "${reset}"
                    fi
                    tui '  %s%s  %s  %s files%s' "${dim}" "$rel_date" "$date" "$file_count" "${reset}"
                fi
            fi
        done

        if [[ "$use_two_cols" == "true" ]]; then
            local _srow _sep_col=$(( col_width + 1 ))
            for ((_srow = list_start; _srow < list_start + max_rows; _srow++)); do
                move_to "$_srow" "$_sep_col"
                tui '%s│%s' "${dim}" "${reset}"
            done
        fi

        # Scroll indicators
        if (( scroll_offset > 0 )); then
            move_to $(( list_start - 1 )) 3
            tui '%s^ more above%s' "${byellow}${bold}" "${reset}"
        fi
        if (( scroll_offset + max_items < ${#filtered[@]} )); then
            local bottom_row=$(( list_start + max_rows * row_height ))
            (( bottom_row > effective_lines - 1 )) && bottom_row=$(( effective_lines - 1 ))
            move_to "$bottom_row" 3
            tui '%sv more below%s' "${byellow}${bold}" "${reset}"
        fi
    fi

    # ── Details panel for selected item ──
    if (( details_height > 0 && ${#filtered[@]} > 0 && selected < ${#filtered[@]} )); then
        local _dp_idx="${filtered[$selected]}"
        local _dp_row=$(( effective_lines + 1 ))
        local _dp_inner_w=$(( term_cols - 4 ))
        (( _dp_inner_w > 120 )) && _dp_inner_w=120

        # Top separator
        move_to "$_dp_row" 1
        tui '  %s%s%s' "${dim}${cyan}" "$(printf '%*s' "$_dp_inner_w" '' | tr ' ' '─')" "${reset}"

        local _dp_title="${cache_title[$_dp_idx]}"
        local _dp_base="${cache_base[$_dp_idx]}"
        local _dp_path="${cache_fullpath[$_dp_idx]}"
        local _dp_rel="${cache_reldate[$_dp_idx]}"
        local _dp_lang="${cache_lang[$_dp_idx]}"
        local _dp_lcolor="${cache_langcolor[$_dp_idx]}"
        local _dp_fw="${cache_framework[$_dp_idx]}"
        local _dp_src="${cache_source[$_dp_idx]}"
        local _dp_files="${cache_files[$_dp_idx]}"
        local _dp_desc="${cache_desc[$_dp_idx]}"
        local _dp_grp="${cache_group[$_dp_idx]:-}"

        # Line 1: title + reldate + source
        move_to $(( _dp_row + 1 )) 3
        tui '%s%s%s' "${bold}${bwhite}" "$_dp_title" "${reset}"
        [[ -n "$_dp_rel" ]] && tui '  %s%s%s' "${dim}" "$_dp_rel" "${reset}"
        [[ -n "$_dp_grp" ]] && tui '  %s{%s}%s' "${dim}${bmagenta}" "$_dp_grp" "${reset}"
        if [[ "$_dp_src" == "discovered" ]]; then
            tui '  %s[claude]%s' "${dim}${bcyan}" "${reset}"
        elif [[ "$_dp_src" == "external" ]]; then
            tui '  %s[added]%s' "${dim}${bcyan}" "${reset}"
        fi

        # Line 2: path
        move_to $(( _dp_row + 2 )) 3
        local _dp_path_show="$_dp_path"
        local _dp_home="$HOME"
        _dp_path_show="${_dp_path_show/#$_dp_home/~}"
        if (( ${#_dp_path_show} > _dp_inner_w - 2 )); then
            _dp_path_show="…${_dp_path_show: -$(( _dp_inner_w - 3 ))}"
        fi
        tui '%s%s%s' "${dim}" "$_dp_path_show" "${reset}"

        # Line 3: meta (files, lang, framework, base if differs)
        move_to $(( _dp_row + 3 )) 3
        tui '%s%s files%s' "${dim}" "$_dp_files" "${reset}"
        if [[ -n "$_dp_lang" ]]; then
            tui '  %s%s%s' "${_dp_lcolor}" "$_dp_lang" "${reset}"
        fi
        if [[ -n "$_dp_fw" ]]; then
            tui '  %s%s%s%s' "${dim}" "${italic}" "$_dp_fw" "${reset}"
        fi
        if [[ "$_dp_base" != "$_dp_title" ]]; then
            tui '  %s(%s)%s' "${dim}" "$_dp_base" "${reset}"
        fi

        # Line 4: description (truncated)
        if [[ -n "$_dp_desc" ]]; then
            move_to $(( _dp_row + 4 )) 3
            local _dp_dmax=$(( _dp_inner_w - 2 ))
            local _dp_dshow="$_dp_desc"
            (( ${#_dp_dshow} > _dp_dmax )) && _dp_dshow="${_dp_dshow:0:$((_dp_dmax-1))}…"
            tui '%s%s%s' "${dim}${italic}" "$_dp_dshow" "${reset}"
        fi

        # Lines 5-7: recent files
        local _dp_rf
        _dp_rf=$(_get_recent_files_cached "$_dp_path")
        if [[ -n "$_dp_rf" ]]; then
            move_to $(( _dp_row + 5 )) 3
            tui '%srecent:%s' "${dim}${bold}" "${reset}"
            local _dp_rfi=0
            local _dp_now
            _dp_now=$(date '+%s')
            while IFS= read -r _dp_line; do
                [[ -z "$_dp_line" ]] && continue
                local _dp_mt="${_dp_line%% *}"
                local _dp_fp="${_dp_line#* }"
                local _dp_rfp="${_dp_fp#$_dp_path/}"
                local _dp_age=""
                _epoch_to_reldate "${_dp_mt%%.*}" "$_dp_now"
                _dp_age="$_reldate"
                local _dp_max_rf=$(( _dp_inner_w - 18 ))
                (( ${#_dp_rfp} > _dp_max_rf )) && _dp_rfp="…${_dp_rfp: -$((_dp_max_rf-1))}"
                move_to $(( _dp_row + 5 + _dp_rfi )) 12
                tui '%s%s%s  %s%s%s' "${bwhite}" "$_dp_rfp" "${reset}" "${dim}" "$_dp_age" "${reset}"
                _dp_rfi=$(( _dp_rfi + 1 ))
                (( _dp_rfi >= 3 )) && break
            done <<< "$_dp_rf"
        fi
    fi

    # Status bar
    if [[ -n "$status_msg" ]]; then
        move_to "$term_lines" 1
        tui '%s  %s%s' "$status_color" "$status_msg" "${reset}"
        status_msg=""
    fi
}

# ── Input (reads from /dev/tty) ──────────────────────────────────
read_key() {
    local key c
    IFS= read -rsn1 key < /dev/tty || return 1
    if [[ "$key" == $'\e' ]]; then
        # Bracketed sequence — read intro byte
        IFS= read -rsn1 -t 0.1 c < /dev/tty || c=""
        key+="$c"
        if [[ "$c" == "[" ]]; then
            IFS= read -rsn1 -t 0.1 c < /dev/tty || c=""
            key+="$c"
            if [[ "$c" == "<" ]]; then
                # Mouse SGR — read until M or m
                while IFS= read -rsn1 -t 0.5 c < /dev/tty; do
                    key+="$c"
                    [[ "$c" == "M" || "$c" == "m" ]] && break
                done
            fi
        fi
    fi
    printf '%s' "$key"
}

# ── Prompts ───────────────────────────────────────────────────────
prompt_input() {
    local prompt_text="$1"
    local default_val="${2:-}"
    local term_lines
    term_lines=$(tput_lines)

    move_to "$term_lines" 1
    clear_line
    show_cursor
    tui '  %s%s%s' "${byellow}${bold}" "$prompt_text" "${reset}"
    local input
    if [[ -n "$default_val" ]]; then
        read -rei "$default_val" input < /dev/tty 2> /dev/tty
    else
        read -r input < /dev/tty 2> /dev/tty
    fi
    hide_cursor
    printf '%s' "$input"
}

confirm() {
    local prompt_text="$1"
    local term_lines
    term_lines=$(tput_lines)

    move_to "$term_lines" 1
    clear_line
    tui '  %s%s (y/N):%s ' "${bg_red}${bwhite}${bold}" "$prompt_text" "${reset}"
    local key
    IFS= read -rsn1 key < /dev/tty
    [[ "$key" == "y" || "$key" == "Y" ]]
}

# ── Search mode ──────────────────────────────────────────────────
do_search() {
    local term_lines
    term_lines=$(tput_lines)

    move_to "$term_lines" 1
    clear_line
    show_cursor
    tui '  %s/%s ' "${bblue}${bold}" "${reset}"
    local input
    read -rei "$search_query" input < /dev/tty 2> /dev/tty
    hide_cursor
    search_query="$input"
    apply_filter
    selected=0
    scroll_offset=0
}

do_clear_search() {
    search_query=""
    apply_filter
    selected=0
    scroll_offset=0
}

# ── Actions ───────────────────────────────────────────────────────
_get_real_idx() {
    # Get the real dirs[] index from the filtered selection
    (( ${#filtered[@]} == 0 )) && return 1
    printf '%s' "${filtered[$selected]}"
}

do_rename() {
    local idx
    idx=$(_get_real_idx) || return
    local dir="${dirs[$idx]}"
    local new_name
    new_name=$(prompt_input "Set title: " "${cache_title[$idx]}")
    if [[ -n "$new_name" ]]; then
        printf '%s' "$new_name" > "$dir/.name"
        refresh_cache "$idx"
        apply_filter
        status_msg="Title set: $new_name"
        status_color="${bgreen}${bold}"
    fi
}

do_move_dir() {
    local idx
    idx=$(_get_real_idx) || return
    local dir="${dirs[$idx]}"
    local base="${cache_base[$idx]}"
    local title="${cache_title[$idx]}"
    local source="${cache_source[$idx]}"

    local suggestion="$title"
    local parent
    parent=$(dirname "$dir")

    local new_name
    new_name=$(prompt_input "Rename directory '$base' to: " "$suggestion")
    if [[ -z "$new_name" ]]; then
        status_msg="Cancelled"
        status_color="$dim"
        return
    fi

    local new_path="$parent/$new_name"
    if [[ -e "$new_path" ]]; then
        status_msg="Directory '$new_name' already exists!"
        status_color="${bred}${bold}"
        return
    fi

    mv "$dir" "$new_path"
    if [[ -f "$new_path/.name" ]]; then
        local stored_name
        stored_name=$(<"$new_path/.name")
        if [[ "$stored_name" == "$new_name" ]]; then
            rm "$new_path/.name"
        fi
    fi

    dirs[$idx]="$new_path"
    cache_fullpath[$idx]="$new_path"
    refresh_cache "$idx"
    apply_filter
    status_msg="Moved: $base -> $new_name"
    status_color="${bgreen}${bold}"
}

_is_awkward_name() {
    local base="$1"
    # Timestamp patterns, all digits/underscores/dashes, or very long hex-like strings
    [[ "$base" =~ ^[0-9]{8}[_-][0-9]{4,6}$ ]] && return 0
    [[ "$base" =~ ^[0-9_-]+$ ]] && return 0
    [[ "$base" =~ ^[0-9a-f]{8,}$ ]] && return 0
    [[ "$base" =~ ^tmp[_-] ]] && return 0
    [[ "$base" =~ ^untitled ]] && return 0
    return 1
}

_sanitize_dirname() {
    local name="$1"
    # Replace characters that are problematic in directory names
    name="${name//\//-}"
    name="${name//:/-}"
    # Trim leading/trailing whitespace
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    printf '%s' "$name"
}

do_smart_rename() {
    local idx
    idx=$(_get_real_idx) || return
    local dir="${dirs[$idx]}"
    local base="${cache_base[$idx]}"
    local title="${cache_title[$idx]}"
    local source="${cache_source[$idx]}"

    if ! _is_awkward_name "$base"; then
        status_msg="Directory name '$base' doesn't look awkward — use 'm' to rename anyway"
        status_color="${byellow}${bold}"
        return
    fi

    if [[ "$title" == "$base" ]]; then
        status_msg="No app name detected to suggest — use 'm' to rename manually"
        status_color="${byellow}${bold}"
        return
    fi

    local suggestion
    suggestion=$(_sanitize_dirname "$title")
    local parent
    parent=$(dirname "$dir")

    local term_lines
    term_lines=$(tput_lines)
    move_to "$term_lines" 1
    clear_line
    tui '  %sSmart Rename:%s detected app → %s%s%s' \
        "${bcyan}${bold}" "${reset}" "${bwhite}${bold}" "$suggestion" "${reset}"

    local new_name
    new_name=$(prompt_input "Rename '$base' to: " "$suggestion")
    if [[ -z "$new_name" ]]; then
        status_msg="Cancelled"
        status_color="$dim"
        return
    fi

    new_name=$(_sanitize_dirname "$new_name")
    local new_path="$parent/$new_name"
    if [[ -e "$new_path" ]]; then
        status_msg="Directory '$new_name' already exists!"
        status_color="${bred}${bold}"
        return
    fi

    mv "$dir" "$new_path"
    # Clean up .name file if it matches the new dir name
    if [[ -f "$new_path/.name" ]]; then
        local stored_name
        stored_name=$(<"$new_path/.name")
        if [[ "$stored_name" == "$new_name" ]]; then
            rm "$new_path/.name"
        fi
    fi

    # Update extra dirs file if this is an external dir
    if [[ "$source" == "external" && -f "$EXTRA_DIRS_FILE" ]]; then
        sed -i '' "s|^${dir}$|${new_path}|" "$EXTRA_DIRS_FILE"
    fi

    dirs[$idx]="$new_path"
    cache_fullpath[$idx]="$new_path"
    refresh_cache "$idx"
    apply_filter
    status_msg="Smart renamed: $base → $new_name"
    status_color="${bgreen}${bold}"
}

do_edit_desc() {
    local idx
    idx=$(_get_real_idx) || return
    local dir="${dirs[$idx]}"
    local current_desc=""
    [[ -f "$dir/.description" ]] && current_desc=$(<"$dir/.description")
    local new_desc
    new_desc=$(prompt_input "Description: " "$current_desc")
    if [[ -n "$new_desc" ]]; then
        printf '%s' "$new_desc" > "$dir/.description"
        refresh_cache "$idx"
        apply_filter
        status_msg="Description updated"
        status_color="${bgreen}${bold}"
    fi
}

do_delete() {
    local idx
    idx=$(_get_real_idx) || return
    local title="${cache_title[$idx]}"
    local source="${cache_source[$idx]}"
    local dir="${dirs[$idx]}"

    # Two-tier safety: default = hide from claudemanager only; type "confirm" to wipe files from disk.
    local response
    response=$(prompt_input "Hide '$title' (enter), or type 'confirm' to DELETE files from disk: ")

    if [[ "$response" == "confirm" ]]; then
        if [[ "$source" == "external" ]]; then
            # External dirs aren't under our control — refuse to nuke them from this prompt
            status_msg="External dir; remove via 'a' management or rm by hand"
            status_color="${byellow}${bold}"
            return
        fi
        rm -rf "$dir"
        # Also drop from ignore file if present
        if [[ -f "$IGNORE_FILE" ]]; then
            local tmp
            tmp=$(grep -v "^${dir}$" "$IGNORE_FILE" 2>/dev/null || true)
            printf '%s\n' "$tmp" > "$IGNORE_FILE"
        fi
        status_msg="DELETED from disk: $title"
        status_color="${bred}${bold}"
    elif [[ -z "$response" || "$response" == "y" || "$response" == "Y" || "$response" == "yes" ]]; then
        # Hide from claudemanager view
        if [[ "$source" == "external" ]]; then
            # Same as before: remove from extra-dirs list
            if [[ -f "$EXTRA_DIRS_FILE" ]]; then
                local tmp
                tmp=$(grep -v "^${dir}$" "$EXTRA_DIRS_FILE" 2>/dev/null || true)
                printf '%s\n' "$tmp" > "$EXTRA_DIRS_FILE"
            fi
            status_msg="Removed from list: $title"
        else
            # Add to ignore file — load_dirs filters these out
            printf '%s\n' "$dir" >> "$IGNORE_FILE"
            status_msg="Hidden: $title  (files kept on disk)"
        fi
        status_color="${byellow}${bold}"
    else
        status_msg="Cancelled"
        status_color="$dim"
        return
    fi

    load_dirs
    _apply_groups_to_cache
    _apply_demo_mode
    if (( selected >= ${#filtered[@]} )); then
        selected=$(( ${#filtered[@]} - 1 ))
        (( selected < 0 )) && selected=0
    fi
}

do_refresh() {
    load_dirs "true"
    _apply_groups_to_cache
    _apply_demo_mode
    selected=0
    scroll_offset=0
    status_msg="Refreshed all projects"
    status_color="${bgreen}${bold}"
}

do_toggle_view() {
    if [[ "$view_mode" == "local" ]]; then
        view_mode="all"
        status_msg="Showing all Claude projects"
    else
        view_mode="local"
        status_msg="Showing local projects only"
    fi
    status_color="${bcyan}${bold}"
    selected=0
    scroll_offset=0
    load_dirs
    _apply_groups_to_cache
    _apply_demo_mode
    _save_prefs
}

do_toggle_sort() {
    case "$sort_mode" in
        date)     sort_mode="modified" ;;
        modified) sort_mode="recent" ;;
        recent)   sort_mode="name" ;;
        name)     sort_mode="language" ;;
        language) sort_mode="date" ;;
    esac
    sort_dirs
    apply_filter
    selected=0
    scroll_offset=0
    status_msg="Sort: $sort_mode"
    status_color="${byellow}${bold}"
    _save_prefs
}

do_add_dir() {
    local path
    path=$(prompt_input "Directory path to add: " "$HOME/")
    if [[ -z "$path" ]]; then
        status_msg="Cancelled"
        status_color="$dim"
        return
    fi

    # Expand ~ manually
    path="${path/#\~/$HOME}"

    if [[ ! -d "$path" ]]; then
        status_msg="Not a directory: $path"
        status_color="${bred}${bold}"
        return
    fi

    # Resolve to absolute path
    path=$(realpath "$path" 2>/dev/null) || path="$path"

    # Ask: single project, or scan children?
    local subdir_count
    subdir_count=$(find "$path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    local mode
    if (( subdir_count >= 2 )); then
        mode=$(prompt_input "Add as (s)ingle project, or (c)scan ${subdir_count} subdirs? [s/c]: " "c")
    else
        mode="s"
    fi
    local entry="$path"
    if [[ "$mode" == "c" || "$mode" == "C" ]]; then
        entry="$path/*"
    fi

    # Check if already tracked
    if [[ -f "$EXTRA_DIRS_FILE" ]] && grep -qxF "$entry" "$EXTRA_DIRS_FILE" 2>/dev/null; then
        status_msg="Already tracked: $entry"
        status_color="${byellow}${bold}"
        return
    fi

    # Append to extra dirs file
    printf '%s\n' "$entry" >> "$EXTRA_DIRS_FILE"
    load_dirs
    _apply_groups_to_cache
    _apply_demo_mode
    if [[ "$entry" == */\* ]]; then
        status_msg="Scanning: $entry (${subdir_count} subdirs)"
    else
        status_msg="Added: $entry"
    fi
    status_color="${bgreen}${bold}"
}

do_toggle_compact() {
    case "$display_mode" in
        compact) display_mode="full" ;;
        full)    display_mode="grid" ;;
        grid)    display_mode="compact" ;;
    esac
    scroll_offset=0
    status_msg="View: $display_mode"
    status_color="${byellow}${bold}"
    _save_prefs
}

_smart_title() {
    # Given a title and full path, return a disambiguated display name
    local t="$1" p="$2"
    local needs_context=false
    (( ${#t} <= 6 )) && needs_context=true
    [[ "${t,,}" =~ ^(pub|util|app|src|test|dev|build|tmp|empty[0-9]*|www|web|api|lib|main|home|docs)$ ]] && needs_context=true

    if $needs_context; then
        local parent
        parent=$(dirname "$p")
        local parent_name="${parent##*/}"
        if [[ "${parent_name,,}" =~ ^(users|home|util|code|src|projects|claude)$ ]]; then
            local gp
            gp=$(dirname "$parent")
            printf '%s/%s/%s' "${gp##*/}" "$parent_name" "$t"
        else
            printf '%s/%s' "$parent_name" "$t"
        fi
    else
        printf '%s' "$t"
    fi
}

_encode_proj_path() {
    # /Users/foo/bar -> -Users-foo-bar (Claude projects dir encoding)
    printf '%s' "$1" | sed 's|/|-|g'
}

_fmt_tokens() {
    local n="$1"
    if (( n >= 1000000000 )); then
        printf '%.1fB' "$(echo "$n / 1000000000" | bc -l)"
    elif (( n >= 1000000 )); then
        printf '%.1fM' "$(echo "$n / 1000000" | bc -l)"
    elif (( n >= 1000 )); then
        printf '%.1fK' "$(echo "$n / 1000" | bc -l)"
    else
        printf '%d' "$n"
    fi
}

_gather_token_stats() {
    # Gathers token usage from JSONL session files for all projects.
    # Sets parallel arrays: _tok_titles[], _tok_input[], _tok_output[], _tok_cache_read[], _tok_cache_write[], _tok_sessions[]
    # Also sets: _tok_total_in, _tok_total_out, _tok_total_cache_r, _tok_total_cache_w, _tok_total_sessions
    _tok_titles=()
    _tok_display=()    # smart display name with path context
    _tok_paths=()      # full path for context
    _tok_input=()
    _tok_output=()
    _tok_cache_read=()
    _tok_cache_write=()
    _tok_sessions=()
    _tok_total_in=0
    _tok_total_out=0
    _tok_total_cache_r=0
    _tok_total_cache_w=0
    _tok_total_sessions=0

    local total=${#dirs[@]}
    for (( i = 0; i < total; i++ )); do
        local d="${dirs[$i]}"
        local title="${cache_title[$i]}"
        local rp
        rp=$(realpath "$d" 2>/dev/null) || rp="$d"
        local encoded
        encoded=$(_encode_proj_path "$rp")
        local proj_dir="$CLAUDE_PROJECTS_DIR/$encoded"

        [[ -d "$proj_dir" ]] || continue

        # Count sessions and sum tokens with a single awk pass over all JSONL files
        local jsonl_files=()
        while IFS= read -r f; do
            jsonl_files+=("$f")
        done < <(find "$proj_dir" -name '*.jsonl' -type f 2>/dev/null)

        (( ${#jsonl_files[@]} == 0 )) && continue

        local result
        result=$(awk -F'"' '
            /"input_tokens"/ {
                for(i=1;i<=NF;i++) {
                    if($i=="input_tokens") { v=$(i+1); gsub(/[^0-9]/,"",v); inp += v }
                    if($i=="output_tokens") { v=$(i+1); gsub(/[^0-9]/,"",v); out += v }
                    if($i=="cache_read_input_tokens") { v=$(i+1); gsub(/[^0-9]/,"",v); cr += v }
                    if($i=="cache_creation_input_tokens") { v=$(i+1); gsub(/[^0-9]/,"",v); cw += v }
                }
            }
            END { printf "%d\t%d\t%d\t%d", inp, out, cr, cw }
        ' "${jsonl_files[@]}" 2>/dev/null)

        local p_in p_out p_cr p_cw
        IFS=$'\t' read -r p_in p_out p_cr p_cw <<< "$result"
        (( p_in == 0 && p_out == 0 )) && continue

        local sess_count=${#jsonl_files[@]}

        _tok_titles+=("$title")
        _tok_paths+=("$rp")
        _tok_input+=("$p_in")
        _tok_output+=("$p_out")
        _tok_cache_read+=("$p_cr")
        _tok_cache_write+=("$p_cw")
        _tok_sessions+=("$sess_count")

        (( _tok_total_in += p_in ))
        (( _tok_total_out += p_out ))
        (( _tok_total_cache_r += p_cr ))
        (( _tok_total_cache_w += p_cw ))
        (( _tok_total_sessions += sess_count ))
    done

    # Build smart display names: add path context for short/ambiguous/duplicate titles
    _tok_display=()
    local -A title_count=()
    for t in "${_tok_titles[@]}"; do
        title_count["${t,,}"]=$(( ${title_count["${t,,}"]:-0} + 1 ))
    done
    for (( i = 0; i < ${#_tok_titles[@]}; i++ )); do
        local t="${_tok_titles[$i]}"
        local p="${_tok_paths[$i]}"
        local needs_context=false

        # Short title, duplicate, or looks like a generic name
        (( ${#t} <= 6 )) && needs_context=true
        (( ${title_count["${t,,}"]:-0} > 1 )) && needs_context=true
        local dn
        dn=$(_smart_title "$t" "$p")
        # Also add context for duplicates even if _smart_title didn't
        if (( ${title_count["${t,,}"]:-0} > 1 )) && [[ "$dn" == "$t" ]]; then
            local parent
            parent=$(dirname "$p")
            dn="${parent##*/}/$t"
        fi
        _tok_display+=("$dn")
    done
}

do_assign_group() {
    # Quick-assign a group to the currently selected project
    (( ${#filtered[@]} == 0 )) && return
    local idx="${filtered[$selected]}"
    local title="${cache_title[$idx]}"
    local current_group="${cache_group[$idx]:-}"

    # Build choice list: suggestions first, then all groups, then "new" and "remove"
    local -a choices=()
    local -a choice_labels=()
    local -A seen_choice=()

    # Suggestions
    local -a suggestions=()
    while IFS= read -r sg; do
        [[ -n "$sg" ]] && suggestions+=("$sg")
    done < <(_suggest_groups_for "$idx")

    for sg in "${suggestions[@]}"; do
        choices+=("$sg")
        local lbl="$sg"
        [[ "$sg" == "$current_group" ]] && lbl="$sg  ✓ current"
        choice_labels+=("  ★ $lbl")
        seen_choice["$sg"]=1
    done

    # All existing groups
    while IFS= read -r g; do
        [[ -n "$g" && -z "${seen_choice[$g]:-}" ]] || continue
        choices+=("$g")
        local lbl="$g"
        [[ "$g" == "$current_group" ]] && lbl="$g  ✓ current"
        choice_labels+=("    $lbl")
    done < <(_get_all_group_names)

    # Special entries
    choices+=("__NEW__")
    choice_labels+=("  + Create new group")
    if [[ -n "$current_group" ]]; then
        choices+=("__REMOVE__")
        choice_labels+=("  - Remove from '$current_group'")
    fi

    # Draw picker
    local sel=0
    local count=${#choices[@]}
    while true; do
        clear_screen
        local term_lines term_cols
        term_lines=$(tput_lines)
        term_cols=$(tput_cols)
        local row=2
        move_to "$row" 1
        tui '  %sAssign group for:%s %s%s%s' "${bold}${bwhite}" "${reset}" "${bold}${bcyan}" "$title" "${reset}"
        if [[ -n "$current_group" ]]; then
            tui '  %s(current: %s)%s' "${dim}" "$current_group" "${reset}"
        fi
        (( row += 2 ))

        local max_vis=$(( term_lines - row - 2 ))
        local vis_start=0
        (( sel >= vis_start + max_vis )) && vis_start=$(( sel - max_vis + 1 ))
        (( sel < vis_start )) && vis_start=$sel

        for (( i = vis_start; i < count && i < vis_start + max_vis; i++ )); do
            move_to "$row" 1
            if (( i == sel )); then
                tui '  %s>%s %s%s%s' "${bgreen}${bold}" "${reset}" "${bg_sel}${bwhite}${bold}" "${choice_labels[$i]}" "${reset}"
            else
                tui '    %s' "${choice_labels[$i]}"
            fi
            (( row++ ))
        done

        move_to "$term_lines" 1
        tui '  %sj/k%s navigate  %senter%s select  %sq%s cancel' "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}"

        local key
        key=$(read_key)
        case "$key" in
            $'\e[A' | k) (( sel > 0 )) && (( sel-- )) ;;
            $'\e[B' | j) (( sel < count - 1 )) && (( sel++ )) ;;
            "")
                local pick="${choices[$sel]}"
                if [[ "$pick" == "__NEW__" ]]; then
                    local new_name
                    new_name=$(prompt_input "New group name: ")
                    [[ -z "$new_name" ]] && continue
                    _set_project_group "$idx" "$new_name"
                    status_msg="Added '$title' to group '$new_name'"
                    status_color="${bgreen}${bold}"
                elif [[ "$pick" == "__REMOVE__" ]]; then
                    _set_project_group "$idx" ""
                    status_msg="Removed '$title' from group '$current_group'"
                    status_color="${byellow}${bold}"
                else
                    _set_project_group "$idx" "$pick"
                    status_msg="Added '$title' to group '$pick'"
                    status_color="${bgreen}${bold}"
                fi
                return
                ;;
            q | $'\x1b') return ;;
        esac
    done
}

do_groups() {
    # Full group management screen
    while true; do
        local -a gnames=()
        while IFS= read -r g; do
            [[ -n "$g" ]] && gnames+=("$g")
        done < <(_get_all_group_names)

        if (( ${#gnames[@]} == 0 )); then
            clear_screen
            move_to 3 1
            tui '  %sNo groups yet.%s' "${dim}" "${reset}"
            move_to 4 1
            tui '  %sUse %sg%s on a project to assign it to a group.%s' "${dim}" "${bwhite}${bold}" "${reset}${dim}" "${reset}"
            move_to 6 1
            tui '  %sPress any key to return...%s' "${dim}" "${reset}"
            read_key > /dev/null
            return
        fi

        local sel=0
        local redraw=true
        while true; do
            if $redraw; then
                clear_screen
                local term_lines term_cols
                term_lines=$(tput_lines)
                term_cols=$(tput_cols)
                local row=2
                move_to "$row" 1
                tui '  %s  G R O U P S  %s  %s%d groups%s' "${bg_bblue}${bold}${white}" "${reset}" "${dim}" "${#gnames[@]}" "${reset}"
                (( row += 2 ))

                local total=${#dirs[@]}
                for (( gi = 0; gi < ${#gnames[@]}; gi++ )); do
                    local gn="${gnames[$gi]}"
                    # Count members and list their titles
                    local member_count=0
                    local member_titles=""
                    for (( pi = 0; pi < total; pi++ )); do
                        if [[ "${cache_group[$pi]:-}" == "$gn" ]]; then
                            (( member_count++ ))
                            [[ -n "$member_titles" ]] && member_titles+=", "
                            member_titles+="${cache_title[$pi]}"
                        fi
                    done

                    move_to "$row" 1
                    if (( gi == sel )); then
                        tui '  %s>%s %s%s%s  %s(%d projects)%s' "${bgreen}${bold}" "${reset}" "${bg_sel}${bold}${bwhite}" "$gn" "${reset}" "${dim}" "$member_count" "${reset}"
                    else
                        tui '    %s%s%s  %s(%d projects)%s' "${bold}${bwhite}" "$gn" "${reset}" "${dim}" "$member_count" "${reset}"
                    fi
                    (( row++ ))

                    # Show member names
                    local max_w=$(( term_cols - 8 ))
                    if (( ${#member_titles} > max_w )); then
                        member_titles="${member_titles:0:$(( max_w - 3 ))}..."
                    fi
                    move_to "$row" 1
                    tui '      %s%s%s' "${dim}" "$member_titles" "${reset}"
                    (( row++ ))
                done

                move_to "$term_lines" 1
                tui '  %sj/k%s nav  %senter%s details  %sr%s rename  %sd%s delete  %sq%s back' \
                    "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}${dim}" \
                    "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}${dim}" \
                    "${bwhite}${bold}" "${reset}"
                redraw=false
            fi

            local key
            key=$(read_key)
            case "$key" in
                $'\e[A' | k) (( sel > 0 )) && (( sel-- )); redraw=true ;;
                $'\e[B' | j) (( sel < ${#gnames[@]} - 1 )) && (( sel++ )); redraw=true ;;
                r)
                    local old_name="${gnames[$sel]}"
                    local new_name
                    new_name=$(prompt_input "Rename group: " "$old_name")
                    if [[ -n "$new_name" && "$new_name" != "$old_name" ]]; then
                        # Rename all assignments
                        for path in "${!group_map[@]}"; do
                            [[ "${group_map[$path]}" == "$old_name" ]] && group_map["$path"]="$new_name"
                        done
                        local total=${#dirs[@]}
                        for (( pi = 0; pi < total; pi++ )); do
                            [[ "${cache_group[$pi]}" == "$old_name" ]] && cache_group[$pi]="$new_name"
                        done
                        _save_groups
                        gnames[$sel]="$new_name"
                    fi
                    redraw=true
                    ;;
                d)
                    local del_name="${gnames[$sel]}"
                    if confirm "Delete group '$del_name'?"; then
                        # Remove all assignments for this group
                        for path in "${!group_map[@]}"; do
                            [[ "${group_map[$path]}" == "$del_name" ]] && unset 'group_map[$path]'
                        done
                        local total=${#dirs[@]}
                        for (( pi = 0; pi < total; pi++ )); do
                            [[ "${cache_group[$pi]}" == "$del_name" ]] && cache_group[$pi]=""
                        done
                        _save_groups
                        # Rebuild gnames
                        break  # re-enter outer loop to refresh
                    fi
                    redraw=true
                    ;;
                "")
                    # Group detail — show members, allow add/remove
                    _do_group_detail "${gnames[$sel]}"
                    redraw=true
                    ;;
                q | $'\x1b') return ;;
            esac
        done
    done
}

_do_group_detail() {
    local gname="$1"
    local total=${#dirs[@]}

    while true; do
        # Build members and non-members
        local -a members=() non_members=()
        for (( i = 0; i < total; i++ )); do
            if [[ "${cache_group[$i]:-}" == "$gname" ]]; then
                members+=("$i")
            else
                non_members+=("$i")
            fi
        done

        local all_count=$(( ${#members[@]} + ${#non_members[@]} ))
        local sel=0
        local section="members"  # members | available
        local redraw=true

        while true; do
            if $redraw; then
                clear_screen
                local term_lines term_cols
                term_lines=$(tput_lines)
                term_cols=$(tput_cols)
                local row=2
                move_to "$row" 1
                tui '  %sGroup:%s %s%s%s  %s(%d members)%s' "${bold}${bwhite}" "${reset}" "${bold}${bcyan}" "$gname" "${reset}" "${dim}" "${#members[@]}" "${reset}"
                (( row += 2 ))

                move_to "$row" 1
                tui '  %sMembers:%s' "${bold}${bgreen}" "${reset}"
                (( row++ ))
                if (( ${#members[@]} == 0 )); then
                    move_to "$row" 1
                    tui '    %s(none)%s' "${dim}" "${reset}"
                    (( row++ ))
                fi
                for (( mi = 0; mi < ${#members[@]}; mi++ )); do
                    local pi="${members[$mi]}"
                    move_to "$row" 1
                    if (( sel == mi )); then
                        tui '  %s>%s %s%s%s  %s%s%s' "${bgreen}${bold}" "${reset}" "${bg_sel}${bwhite}${bold}" "${cache_title[$pi]}" "${reset}" "${dim}" "${cache_lang[$pi]}" "${reset}"
                    else
                        tui '    %s%s%s  %s%s%s' "${bwhite}" "${cache_title[$pi]}" "${reset}" "${dim}" "${cache_lang[$pi]}" "${reset}"
                    fi
                    (( row++ ))
                done
                (( row++ ))

                local avail_start=${#members[@]}
                move_to "$row" 1
                tui '  %sAvailable to add:%s' "${bold}${byellow}" "${reset}"
                (( row++ ))
                local max_avail=$(( term_lines - row - 2 ))
                local avail_shown=0
                for (( ai = 0; ai < ${#non_members[@]} && avail_shown < max_avail; ai++ )); do
                    local pi="${non_members[$ai]}"
                    local list_idx=$(( avail_start + ai ))
                    move_to "$row" 1
                    if (( sel == list_idx )); then
                        tui '  %s>%s %s%s%s  %s%s%s' "${byellow}${bold}" "${reset}" "${bg_sel}${bwhite}${bold}" "${cache_title[$pi]}" "${reset}" "${dim}" "${cache_lang[$pi]}" "${reset}"
                    else
                        tui '    %s%s%s  %s%s%s' "${dim}${bwhite}" "${cache_title[$pi]}" "${reset}" "${dim}" "${cache_lang[$pi]}" "${reset}"
                    fi
                    (( row++ ))
                    (( avail_shown++ ))
                done

                local max_sel=$(( avail_start + avail_shown - 1 ))
                (( max_sel < 0 )) && max_sel=0

                move_to "$term_lines" 1
                tui '  %sj/k%s nav  %senter%s add/remove  %sq%s back' \
                    "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}${dim}" \
                    "${bwhite}${bold}" "${reset}"
                redraw=false
            fi

            local key
            key=$(read_key)
            case "$key" in
                $'\e[A' | k) (( sel > 0 )) && (( sel-- )); redraw=true ;;
                $'\e[B' | j) (( sel < max_sel )) && (( sel++ )); redraw=true ;;
                "")
                    if (( sel < ${#members[@]} )); then
                        # Remove from group
                        local pi="${members[$sel]}"
                        _set_project_group "$pi" ""
                    else
                        # Add to group
                        local ai=$(( sel - ${#members[@]} ))
                        local pi="${non_members[$ai]}"
                        _set_project_group "$pi" "$gname"
                    fi
                    break  # re-enter outer loop to refresh lists
                    ;;
                q | $'\x1b') return ;;
            esac
        done
    done
}

do_auto_group() {
    # Auto-detect groups by finding common title prefixes among projects
    local total=${#dirs[@]}
    (( total < 2 )) && { status_msg="Need at least 2 projects"; status_color="${byellow}${bold}"; return; }

    # Step 1: find all common prefixes of length >= 3 chars (case-insensitive)
    local -A prefix_members=()   # prefix -> space-separated indices
    local -A prefix_counts=()

    for (( i = 0; i < total; i++ )); do
        local ti="${cache_title[$i],,}"
        for (( j = i + 1; j < total; j++ )); do
            local tj="${cache_title[$j],,}"
            # Find common prefix
            local plen=0
            local ml=${#ti} tl=${#tj}
            local maxl=$(( ml < tl ? ml : tl ))
            for (( c = 0; c < maxl; c++ )); do
                [[ "${ti:$c:1}" == "${tj:$c:1}" ]] || break
                (( plen++ ))
            done
            (( plen < 3 )) && continue
            # Trim trailing separators (-, _, space)
            local prefix="${cache_title[$i]:0:$plen}"
            prefix="${prefix%[-_ ]}"
            prefix="${prefix%[-_ ]}"
            (( ${#prefix} < 3 )) && continue
            local pl="${prefix,,}"

            # Track members for this prefix
            if [[ -z "${prefix_counts[$pl]:-}" ]]; then
                prefix_counts["$pl"]=0
                prefix_members["$pl"]=""
            fi

            # Add both i and j if not already tracked
            local cur="${prefix_members[$pl]}"
            if [[ ! " $cur " == *" $i "* ]]; then
                prefix_members["$pl"]+=" $i"
                (( prefix_counts["$pl"]++ ))
            fi
            if [[ ! " $cur " == *" $j "* ]]; then
                prefix_members["$pl"]+=" $j"
                (( prefix_counts["$pl"]++ ))
            fi
        done
    done

    # Step 2: pick the best (longest) prefix for each cluster, dedup overlaps
    local -a sorted_prefixes=()
    for pl in "${!prefix_counts[@]}"; do
        sorted_prefixes+=("$(printf '%04d\t%s' "${#pl}" "$pl")")
    done
    (( ${#sorted_prefixes[@]} == 0 )) && { status_msg="No similar projects found to group"; status_color="${byellow}${bold}"; return; }

    IFS=$'\n' sorted_prefixes=($(sort -rn <<< "${sorted_prefixes[*]}")); unset IFS

    # Build proposed groups: longest prefix wins, each project in at most one group
    local -A proposed=()       # group_name -> space-separated indices
    local -A assigned=()       # index -> 1 (already assigned)

    for entry in "${sorted_prefixes[@]}"; do
        local pl="${entry#*	}"
        local members="${prefix_members[$pl]}"
        local -a unassigned=()
        for idx in $members; do
            [[ -z "${assigned[$idx]:-}" ]] && unassigned+=("$idx")
        done
        (( ${#unassigned[@]} < 2 )) && continue

        # Find the original-case version of this prefix from first member
        local first="${unassigned[0]}"
        local orig_title="${cache_title[$first]}"
        local gname="${orig_title:0:${#pl}}"
        # Trim trailing separators
        gname="${gname%[-_ ]}"
        gname="${gname%[-_ ]}"

        proposed["$gname"]=""
        for idx in "${unassigned[@]}"; do
            proposed["$gname"]+=" $idx"
            assigned["$idx"]=1
        done
    done

    (( ${#proposed[@]} == 0 )) && { status_msg="No groupings detected"; status_color="${byellow}${bold}"; return; }

    # Step 3: Interactive review — show proposals, let user accept/reject/edit
    local -a prop_names=()
    for g in "${!proposed[@]}"; do
        prop_names+=("$g")
    done

    local sel=0
    local count=${#prop_names[@]}
    local -A accepted=()  # gname -> "yes" if accepted
    for g in "${prop_names[@]}"; do accepted["$g"]="yes"; done

    while true; do
        clear_screen
        local term_lines term_cols
        term_lines=$(tput_lines)
        term_cols=$(tput_cols)
        local row=2
        move_to "$row" 1
        tui '  %s  A U T O   G R O U P  %s' "${bg_bblue}${bold}${white}" "${reset}"
        (( row += 1 ))
        move_to "$row" 1
        tui '  %sSuggested groups based on similar project names:%s' "${dim}" "${reset}"
        (( row += 2 ))

        for (( gi = 0; gi < count; gi++ )); do
            (( row >= term_lines - 3 )) && break
            local gn="${prop_names[$gi]}"
            local is_on="${accepted[$gn]}"
            local toggle_icon="✓"
            local toggle_color="${bgreen}"
            if [[ "$is_on" != "yes" ]]; then
                toggle_icon="✗"
                toggle_color="${bred}"
            fi

            move_to "$row" 1
            if (( gi == sel )); then
                tui '  %s>%s %s%s%s %s%s%s' "${bgreen}${bold}" "${reset}" "${bg_sel}${bold}${bwhite}" "$gn" "${reset}" "${toggle_color}${bold}" "$toggle_icon" "${reset}"
            else
                tui '    %s%s%s %s%s%s' "${bold}${bwhite}" "$gn" "${reset}" "${toggle_color}" "$toggle_icon" "${reset}"
            fi
            (( row++ ))

            # Show member project names
            local members="${proposed[$gn]}"
            local member_list=""
            for idx in $members; do
                [[ -n "$member_list" ]] && member_list+=", "
                member_list+="${cache_title[$idx]}"
            done
            local max_w=$(( term_cols - 8 ))
            if (( ${#member_list} > max_w )); then
                member_list="${member_list:0:$(( max_w - 3 ))}..."
            fi
            move_to "$row" 1
            tui '      %s%s%s' "${dim}" "$member_list" "${reset}"
            (( row++ ))
        done

        move_to "$term_lines" 1
        tui '  %sj/k%s nav  %sspace%s toggle  %senter%s apply  %sq%s cancel' \
            "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}${dim}" \
            "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}"

        local key
        key=$(read_key)
        case "$key" in
            $'\e[A' | k) (( sel > 0 )) && (( sel-- )) ;;
            $'\e[B' | j) (( sel < count - 1 )) && (( sel++ )) ;;
            " ")
                local gn="${prop_names[$sel]}"
                if [[ "${accepted[$gn]}" == "yes" ]]; then
                    accepted["$gn"]="no"
                else
                    accepted["$gn"]="yes"
                fi
                ;;
            "")
                # Apply accepted groups
                local applied=0
                for gn in "${prop_names[@]}"; do
                    [[ "${accepted[$gn]}" != "yes" ]] && continue
                    local members="${proposed[$gn]}"
                    for idx in $members; do
                        _set_project_group "$idx" "$gn"
                    done
                    (( applied++ ))
                done
                status_msg="Created $applied groups"
                status_color="${bgreen}${bold}"
                return
                ;;
            q | $'\x1b') return ;;
        esac
    done
}

do_stats() {
    clear_screen
    local term_lines term_cols
    term_lines=$(tput_lines)
    term_cols=$(tput_cols)

    # Show loading while gathering token data
    move_to 2 1
    tui '  %s  P R O J E C T   S T A T S  %s' "${bg_bblue}${bold}${white}" "${reset}"
    move_to 4 1
    tui '  %sScanning session data...%s' "${dim}" "${reset}"

    _gather_token_stats

    # Stats are ready — draw the full page
    # Use scrollable pages: [1] overview  [2] token usage  [3] projects by language
    local page=1 max_page=4
    while true; do
        clear_screen
        term_lines=$(tput_lines)
        term_cols=$(tput_cols)
        local row=2
        local total=${#dirs[@]}

        move_to "$row" 1
        tui '  %s  P R O J E C T   S T A T S  %s  %s[%d/%d]%s' "${bg_bblue}${bold}${white}" "${reset}" "${dim}" "$page" "$max_page" "${reset}"
        (( row += 2 ))

        case "$page" in
        1)  # ── Overview & Token Totals ──
            move_to "$row" 1
            tui '  %sTotal projects:%s  %s%d%s' "${bold}${bwhite}" "${reset}" "${bold}${bcyan}" "$total" "${reset}"
            (( row += 1 ))
            move_to "$row" 1
            tui '  %sTotal sessions:%s  %s%d%s' "${bold}${bwhite}" "${reset}" "${bold}${bcyan}" "$_tok_total_sessions" "${reset}"
            (( row += 2 ))

            # Projects by source
            local local_count=0 external_count=0 discovered_count=0
            for (( i = 0; i < total; i++ )); do
                case "${cache_source[$i]}" in
                    local)      (( local_count++ )) ;;
                    external)   (( external_count++ )) ;;
                    discovered) (( discovered_count++ )) ;;
                esac
            done
            move_to "$row" 1
            tui '  %sBy source:%s' "${bold}${bcyan}" "${reset}"
            (( row += 1 ))
            move_to "$row" 1; tui '    %sLocal:%s       %d' "${bwhite}" "${reset}" "$local_count"; (( row++ ))
            (( external_count > 0 ))   && { move_to "$row" 1; tui '    %sExternal:%s    %d' "${bwhite}" "${reset}" "$external_count"; (( row++ )); }
            (( discovered_count > 0 )) && { move_to "$row" 1; tui '    %sDiscovered:%s  %d' "${bwhite}" "${reset}" "$discovered_count"; (( row++ )); }
            (( row++ ))

            # Token usage totals
            move_to "$row" 1
            tui '  %sToken usage (all projects):%s' "${bold}${bcyan}" "${reset}"
            (( row += 1 ))
            move_to "$row" 1; tui '    %sInput tokens:%s          %s' "${bwhite}" "${reset}" "$(_fmt_tokens $_tok_total_in)"; (( row++ ))
            move_to "$row" 1; tui '    %sOutput tokens:%s         %s' "${bwhite}" "${reset}" "$(_fmt_tokens $_tok_total_out)"; (( row++ ))
            move_to "$row" 1; tui '    %sCache read tokens:%s     %s' "${bwhite}" "${reset}" "$(_fmt_tokens $_tok_total_cache_r)"; (( row++ ))
            move_to "$row" 1; tui '    %sCache write tokens:%s    %s' "${bwhite}" "${reset}" "$(_fmt_tokens $_tok_total_cache_w)"; (( row++ ))
            local grand_total=$(( _tok_total_in + _tok_total_out + _tok_total_cache_r + _tok_total_cache_w ))
            move_to "$row" 1; tui '    %sGrand total:%s           %s%s%s' "${bwhite}" "${reset}" "${bold}${byellow}" "$(_fmt_tokens $grand_total)" "${reset}"; (( row++ ))
            (( row++ ))

            # Activity
            local now_epoch
            now_epoch=$(date '+%s')
            local opened_7d=0 opened_30d=0 never_opened=0
            for (( i = 0; i < total; i++ )); do
                local d="${dirs[$i]}"
                local ts="${open_history[$d]:-0}"
                if (( ts == 0 )); then
                    (( never_opened++ ))
                else
                    local age=$(( now_epoch - ts ))
                    (( age < 604800 )) && (( opened_7d++ ))
                    (( age < 2592000 )) && (( opened_30d++ ))
                fi
            done
            move_to "$row" 1; tui '  %sActivity:%s' "${bold}${bcyan}" "${reset}"; (( row++ ))
            move_to "$row" 1; tui '    %sOpened last 7 days:%s   %d' "${bwhite}" "${reset}" "$opened_7d"; (( row++ ))
            move_to "$row" 1; tui '    %sOpened last 30 days:%s  %d' "${bwhite}" "${reset}" "$opened_30d"; (( row++ ))
            move_to "$row" 1; tui '    %sNever opened:%s         %d' "${bwhite}" "${reset}" "$never_opened"; (( row++ ))

            # Disk usage
            if (( row < term_lines - 2 )); then
                (( row++ ))
                local disk_usage
                disk_usage=$(du -sh "$CLAUDE_BASE" 2>/dev/null | cut -f1 | tr -d ' ')
                move_to "$row" 1
                tui '  %sDisk usage:%s  %s (%s)' "${bold}${bcyan}" "${reset}" "${disk_usage:-?}" "$CLAUDE_BASE"
            fi
            ;;

        2)  # ── Top projects by token usage ──
            move_to "$row" 1
            tui '  %sTop projects by token usage:%s' "${bold}${bcyan}" "${reset}"
            (( row += 1 ))

            # Sort by total tokens (input+output) descending
            local -a tok_sorted=()
            for (( i = 0; i < ${#_tok_titles[@]}; i++ )); do
                local t_total=$(( ${_tok_input[$i]} + ${_tok_output[$i]} ))
                tok_sorted+=("$(printf '%012d\t%d' "$t_total" "$i")")
            done
            IFS=$'\n' tok_sorted=($(sort -rn <<< "${tok_sorted[*]}")); unset IFS

            local max_rows=$(( term_lines - row - 2 ))
            local shown=0
            local max_name=20
            (( term_cols > 100 )) && max_name=30
            (( term_cols > 130 )) && max_name=40

            # Header
            move_to "$row" 1
            tui '    %s%-*s  %8s  %8s  %8s  %8s  %5s%s' "${dim}" "$max_name" "Project" "In" "Out" "CacheRd" "CacheWr" "Sess" "${reset}"
            (( row++ ))

            for entry in "${tok_sorted[@]}"; do
                (( shown >= max_rows )) && break
                local idx="${entry#*	}"
                local title="${_tok_display[$idx]}"
                # Truncate title
                if (( ${#title} > max_name )); then
                    title="${title:0:$(( max_name - 1 ))}…"
                fi
                move_to "$row" 1
                tui '    %-*s  %s%8s%s  %s%8s%s  %s%8s%s  %s%8s%s  %5d' \
                    "$max_name" "$title" \
                    "${bcyan}" "$(_fmt_tokens ${_tok_input[$idx]})" "${reset}" \
                    "${bgreen}" "$(_fmt_tokens ${_tok_output[$idx]})" "${reset}" \
                    "${byellow}" "$(_fmt_tokens ${_tok_cache_read[$idx]})" "${reset}" \
                    "${bmagenta}" "$(_fmt_tokens ${_tok_cache_write[$idx]})" "${reset}" \
                    "${_tok_sessions[$idx]}"
                (( row++ ))
                (( shown++ ))
            done

            if (( ${#_tok_titles[@]} == 0 )); then
                move_to "$row" 1
                tui '    %sNo session data found.%s' "${dim}" "${reset}"
            fi
            ;;

        3)  # ── Projects by language ──
            move_to "$row" 1
            tui '  %sProjects by language:%s' "${bold}${bcyan}" "${reset}"
            (( row += 1 ))

            # Group projects by language
            declare -A lang_projects=()
            for (( i = 0; i < total; i++ )); do
                local lang="${cache_lang[$i]}"
                [[ -z "$lang" || "$lang" == "—" ]] && lang="Unknown"
                local title
                title=$(_smart_title "${cache_title[$i]}" "${cache_fullpath[$i]}")
                if [[ -n "${lang_projects[$lang]:-}" ]]; then
                    lang_projects["$lang"]="${lang_projects[$lang]}, $title"
                else
                    lang_projects["$lang"]="$title"
                fi
            done

            # Sort by number of projects (count commas + 1)
            local -a lang_sorted=()
            for lang in "${!lang_projects[@]}"; do
                local names="${lang_projects[$lang]}"
                local cnt=$(( $(echo "$names" | tr -cd ',' | wc -c) + 1 ))
                lang_sorted+=("$(printf '%05d\t%s' "$cnt" "$lang")")
            done
            IFS=$'\n' lang_sorted=($(sort -rn <<< "${lang_sorted[*]}")); unset IFS

            local max_rows=$(( term_lines - row - 2 ))
            local shown=0
            for entry in "${lang_sorted[@]}"; do
                (( shown >= max_rows )) && break
                local cnt="${entry%%	*}"
                local lang="${entry#*	}"
                cnt=$(( 10#$cnt ))

                # Bar chart
                local bar_len=$(( cnt * 16 / (total > 0 ? total : 1) ))
                (( bar_len < 1 && cnt > 0 )) && bar_len=1
                local bar=""
                for (( b = 0; b < bar_len; b++ )); do bar+="█"; done

                move_to "$row" 1
                tui '    %s%-12s%s %s%s%s %d' "${bold}" "$lang" "${reset}" "${bblue}" "$bar" "${reset}" "$cnt"
                (( row++ ))

                # Show project names (truncated to fit)
                local names="${lang_projects[$lang]}"
                local max_w=$(( term_cols - 8 ))
                if (( ${#names} > max_w )); then
                    names="${names:0:$(( max_w - 3 ))}..."
                fi
                move_to "$row" 1
                tui '      %s%s%s' "${dim}" "$names" "${reset}"
                (( row++ ))
                (( shown += 2 ))
            done
            ;;

        4)  # ── Group / client billing stats ──
            local -a gnames_s=()
            while IFS= read -r g; do
                [[ -n "$g" ]] && gnames_s+=("$g")
            done < <(_get_all_group_names)

            if (( ${#gnames_s[@]} == 0 )); then
                move_to "$row" 1
                tui '  %sNo groups defined yet.%s' "${dim}" "${reset}"
                (( row += 1 ))
                move_to "$row" 1
                tui '  %sUse %sg%s on a project to assign it to a group,%s' "${dim}" "${bwhite}${bold}" "${reset}${dim}" "${reset}"
                (( row += 1 ))
                move_to "$row" 1
                tui '  %sor press %sG%s to open group management.%s' "${dim}" "${bwhite}${bold}" "${reset}${dim}" "${reset}"
            else
                move_to "$row" 1
                tui '  %sGroup / client billing:%s' "${bold}${bcyan}" "${reset}"
                (( row += 1 ))

                # Aggregate tokens per group from _tok data
                local -A grp_in=() grp_out=() grp_cr=() grp_cw=() grp_sess=() grp_projs=()
                for (( ti = 0; ti < ${#_tok_titles[@]}; ti++ )); do
                    # Find this project's group by matching title back to dirs
                    local tok_title="${_tok_titles[$ti]}"
                    local grp="(Unassigned)"
                    for (( pi = 0; pi < total; pi++ )); do
                        if [[ "${cache_title[$pi]}" == "$tok_title" && -n "${cache_group[$pi]:-}" ]]; then
                            grp="${cache_group[$pi]}"
                            break
                        fi
                    done
                    grp_in["$grp"]=$(( ${grp_in[$grp]:-0} + ${_tok_input[$ti]} ))
                    grp_out["$grp"]=$(( ${grp_out[$grp]:-0} + ${_tok_output[$ti]} ))
                    grp_cr["$grp"]=$(( ${grp_cr[$grp]:-0} + ${_tok_cache_read[$ti]} ))
                    grp_cw["$grp"]=$(( ${grp_cw[$grp]:-0} + ${_tok_cache_write[$ti]} ))
                    grp_sess["$grp"]=$(( ${grp_sess[$grp]:-0} + ${_tok_sessions[$ti]} ))
                    local cur_projs="${grp_projs[$grp]:-}"
                    [[ -n "$cur_projs" ]] && cur_projs+=", "
                    grp_projs["$grp"]="${cur_projs}${_tok_display[$ti]}"
                done

                # Sort groups by total tokens desc
                local -a grp_sorted=()
                for g in "${!grp_in[@]}"; do
                    local gt=$(( ${grp_in[$g]} + ${grp_out[$g]} ))
                    grp_sorted+=("$(printf '%012d\t%s' "$gt" "$g")")
                done
                IFS=$'\n' grp_sorted=($(sort -rn <<< "${grp_sorted[*]}")); unset IFS

                local max_name=18
                (( term_cols > 100 )) && max_name=25
                (( term_cols > 130 )) && max_name=35

                # Header
                move_to "$row" 1
                tui '    %s%-*s  %8s  %8s  %8s  %8s  %5s%s' "${dim}" "$max_name" "Group" "In" "Out" "CacheRd" "CacheWr" "Sess" "${reset}"
                (( row++ ))

                local max_rows=$(( term_lines - row - 2 ))
                local shown=0
                for entry in "${grp_sorted[@]}"; do
                    (( shown >= max_rows / 2 )) && break  # 2 rows per group (name + members)
                    local g="${entry#*	}"
                    local display_g="$g"
                    if (( ${#display_g} > max_name )); then
                        display_g="${display_g:0:$(( max_name - 1 ))}…"
                    fi

                    local g_color="${bcyan}"
                    [[ "$g" == "(Unassigned)" ]] && g_color="${dim}"

                    move_to "$row" 1
                    tui '    %s%-*s%s  %s%8s%s  %s%8s%s  %s%8s%s  %s%8s%s  %5d' \
                        "${bold}${g_color}" "$max_name" "$display_g" "${reset}" \
                        "${bcyan}" "$(_fmt_tokens ${grp_in[$g]})" "${reset}" \
                        "${bgreen}" "$(_fmt_tokens ${grp_out[$g]})" "${reset}" \
                        "${byellow}" "$(_fmt_tokens ${grp_cr[$g]})" "${reset}" \
                        "${bmagenta}" "$(_fmt_tokens ${grp_cw[$g]})" "${reset}" \
                        "${grp_sess[$g]}"
                    (( row++ ))

                    # Show member project names
                    local members="${grp_projs[$g]}"
                    local max_w=$(( term_cols - 8 ))
                    if (( ${#members} > max_w )); then
                        members="${members:0:$(( max_w - 3 ))}..."
                    fi
                    move_to "$row" 1
                    tui '      %s%s%s' "${dim}" "$members" "${reset}"
                    (( row++ ))
                    (( shown++ ))
                done
            fi
            ;;
        esac

        # Footer
        move_to "$term_lines" 1
        if (( page == 4 )); then
            tui '  %s← →%s page  %sG%s manage groups  %s#%s auto-group  %sq%s return' \
                "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}${dim}" \
                "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}"
        else
            tui '  %s← →%s page  %sq%s return' "${bwhite}${bold}" "${reset}${dim}" "${bwhite}${bold}" "${reset}"
        fi

        local key
        key=$(read_key)
        case "$key" in
            $'\e[C' | l | $'\e[6~') (( page < max_page )) && (( page++ )) ;;
            $'\e[D' | h | $'\e[5~') (( page > 1 )) && (( page-- )) ;;
            G)  do_groups ;;
            '#') do_auto_group ;;
            q | $'\x1b') break ;;
        esac
    done
}

do_about() {
    clear_screen
    local term_lines term_cols
    term_lines=$(tput_lines)
    term_cols=$(tput_cols)

    local row=3
    move_to "$row" 1
    tui '  %s  C L A U D E   M A N A G E R  %s' "${bg_bblue}${bold}${white}" "${reset}"
    (( row += 2 ))
    move_to "$row" 1
    tui '  %sVersion:%s  2.4.4' "${bold}${bwhite}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1
    # Show last modified date + relative time of the installed script
    local script_path="${BASH_SOURCE[0]}"
    local mod_epoch mod_date mod_rel=""
    mod_epoch=$(stat -f '%m' "$script_path" 2>/dev/null || echo "0")
    mod_date=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$script_path" 2>/dev/null || echo "unknown")
    if [[ "$mod_epoch" != "0" ]]; then
        local now_e diff_min diff_hr diff_d
        now_e=$(date '+%s')
        diff_min=$(( (now_e - mod_epoch) / 60 ))
        if (( diff_min < 1 )); then mod_rel="just now"
        elif (( diff_min == 1 )); then mod_rel="1 min ago"
        elif (( diff_min < 60 )); then mod_rel="${diff_min} mins ago"
        else
            diff_hr=$(( diff_min / 60 ))
            if (( diff_hr == 1 )); then mod_rel="1 hour ago"
            elif (( diff_hr < 24 )); then mod_rel="${diff_hr} hours ago"
            else
                diff_d=$(( diff_hr / 24 ))
                if (( diff_d == 1 )); then mod_rel="1 day ago"
                else mod_rel="${diff_d} days ago"
                fi
            fi
        fi
    fi
    tui '  %sBuild:%s     %s  %s(%s)%s' "${bold}${bwhite}" "${reset}" "$mod_date" "${dim}" "$mod_rel" "${reset}"
    (( row += 1 ))
    move_to "$row" 1
    tui '  %sCreated by:%s  Kinsman Software LLC' "${bold}${bwhite}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1
    tui '  %sWebsite:%s    https://kinsman.cc' "${bold}${bwhite}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1
    tui '  %sGitHub:%s     https://github.com/relipse/claudemanager' "${bold}${bwhite}" "${reset}"
    (( row += 2 ))
    move_to "$row" 1
    tui '  %sA colorful TUI for managing Claude Code project directories.%s' "${dim}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1
    tui '  %sNavigate, search, rename, and launch projects from one place.%s' "${dim}" "${reset}"
    (( row += 2 ))
    move_to "$row" 1
    tui '  %sKeybindings:%s' "${bold}${bcyan}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %senter%s  open project in claude    %ss%s  open shell in project dir' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %s/%s      search/filter              %sn%s  create new project' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %sr%s      set display title           %sm%s  rename directory' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %sR%s      smart rename directory      %se%s  edit description' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %sc%s      cycle view mode             %sp%s  toggle local/all view' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %st%s      cycle sort mode             %sa%s  add external directory' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %sf%s      force refresh cache         %sd%s  delete project' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %sg%s      assign group/client         %sG%s  group management' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %s#%s      auto-detect groups' "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %sS%s      project stats               %s,%s  settings' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %s?%s      this screen' "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %sj/k%s    navigate up/down            %sq%s  quit' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"

    move_to "$term_lines" 1
    tui '  %sPress q/esc to quit, any other key to return...%s' "${dim}" "${reset}"
    local dismiss_key
    dismiss_key=$(read_key)
    if [[ "$dismiss_key" == "q" || "$dismiss_key" == $'\x1b' ]]; then
        action="quit"
    fi
}

# ── Settings screen ───────────────────────────────────────────────
_cycle_value() {
    local current="$1" dir="$2"
    shift 2
    local -a values=("$@")
    local i
    for (( i = 0; i < ${#values[@]}; i++ )); do
        [[ "${values[$i]}" == "$current" ]] && break
    done
    (( i += dir ))
    (( i < 0 )) && i=$(( ${#values[@]} - 1 ))
    (( i >= ${#values[@]} )) && i=0
    printf '%s' "${values[$i]}"
}

_has_tmux() { command -v tmux &>/dev/null; }

_detect_pkg_manager() {
    if command -v brew &>/dev/null; then printf 'brew'; return; fi
    if command -v apt &>/dev/null; then printf 'apt'; return; fi
    if command -v dnf &>/dev/null; then printf 'dnf'; return; fi
    if command -v pacman &>/dev/null; then printf 'pacman'; return; fi
    if command -v apk &>/dev/null; then printf 'apk'; return; fi
    printf 'none'
}

_install_tmux() {
    local pkg_mgr
    pkg_mgr=$(_detect_pkg_manager)
    local install_cmd=""
    case "$pkg_mgr" in
        brew)   install_cmd="brew install tmux" ;;
        apt)    install_cmd="sudo apt install -y tmux" ;;
        dnf)    install_cmd="sudo dnf install -y tmux" ;;
        pacman) install_cmd="sudo pacman -S --noconfirm tmux" ;;
        apk)    install_cmd="sudo apk add tmux" ;;
        *)
            _settings_status="No package manager found. Install tmux manually."
            _settings_status_color="${bred}${bold}"
            return 1
            ;;
    esac

    # Confirm with user
    local term_lines
    term_lines=$(tput_lines)
    move_to "$term_lines" 1
    clear_line
    show_cursor
    tui '  %sInstall tmux via: %s%s%s  [y/N] ' "${byellow}${bold}" "${reset}${bwhite}${bold}" "$install_cmd" "${reset}"
    local answer
    IFS= read -rsn1 answer < /dev/tty
    hide_cursor
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        _settings_status="tmux installation skipped"
        _settings_status_color="${dim}"
        return 1
    fi

    # Run install
    clear_screen
    move_to 1 1
    show_cursor
    tui '%s  Installing tmux...%s\n\n' "${bwhite}${bold}" "${reset}"
    if eval "$install_cmd" > /dev/tty 2>&1; then
        _settings_status="tmux installed successfully!"
        _settings_status_color="${bgreen}${bold}"
        hide_cursor
        return 0
    else
        _settings_status="tmux installation failed. Try manually: $install_cmd"
        _settings_status_color="${bred}${bold}"
        hide_cursor
        return 1
    fi
}

_tmux_display_value() {
    local val="$1"
    case "$val" in
        tmux_split|tmux_status)
            if _has_tmux; then
                printf '%s' "$val"
            else
                printf '%s (no tmux)' "$val"
            fi
            ;;
        *) printf '%s' "$val" ;;
    esac
}

# ── Claude helpers install/uninstall ──────────────────────────────
_helpers_bin_dir() { printf '%s/bin' "$HOME"; }

_helpers_list() { printf 'claude-yolo claude-edits claude-pin claude-help'; }

_helpers_status() {
    local bin_dir
    bin_dir=$(_helpers_bin_dir)
    local found=0 total=4
    local h
    for h in $(_helpers_list); do
        [[ -x "$bin_dir/$h" ]] && (( found++ ))
    done
    if (( found == 0 )); then
        printf 'not installed'
    elif (( found == total )); then
        printf 'installed'
    else
        printf 'partial (%d/%d)' "$found" "$total"
    fi
}

_install_claude_helpers() {
    local bin_dir
    bin_dir=$(_helpers_bin_dir)
    mkdir -p "$bin_dir"

    cat > "$bin_dir/claude-yolo" <<'END_YOLO'
#!/usr/bin/env bash
# claude-yolo — launch Claude Code with bypassPermissions + safety denies
show_help() {
  cat <<'HELP'
claude-yolo — Launch Claude Code with all prompts disabled (with guardrails)

USAGE
  claude-yolo [claude-args...]

WHAT IT DOES
  Auto-approves every Bash command and file edit, except for a deny list
  that blocks obvious foot-guns (rm, sudo, git push, .env, .ssh, etc.).
  Nothing written to disk — session-only settings.

SEE ALSO
  claude-edits  safer: auto-accept edits only, Bash still prompts
  claude-pin    write yolo settings into ./.claude/ permanently
  claude-help   overview of all helpers
HELP
}
case "${1:-}" in -h|--help) show_help; exit 0 ;; esac
exec claude --settings '{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "deny": [
      "Bash(rm:*)", "Bash(sudo:*)", "Bash(git push:*)",
      "Read(**/.env)", "Read(**/.env.*)",
      "Read(**/.ssh/**)", "Read(**/.aws/**)",
      "Read(**/id_rsa*)", "Read(**/*.pem)"
    ]
  }
}' "$@"
END_YOLO

    cat > "$bin_dir/claude-edits" <<'END_EDITS'
#!/usr/bin/env bash
# claude-edits — Claude Code with acceptEdits (Bash still prompts)
show_help() {
  cat <<'HELP'
claude-edits — Launch Claude Code in acceptEdits mode

File edits auto-approve; Bash commands still prompt as usual.
The safer middle ground between default and claude-yolo.
HELP
}
case "${1:-}" in -h|--help) show_help; exit 0 ;; esac
exec claude --settings '{"permissions":{"defaultMode":"acceptEdits"}}' "$@"
END_EDITS

    cat > "$bin_dir/claude-pin" <<'END_PIN'
#!/usr/bin/env bash
# claude-pin — persist yolo settings into ./.claude/settings.local.json
set -euo pipefail
FORCE=0
case "${1:-}" in
  -h|--help)
    echo "claude-pin — Persist bypassPermissions to ./.claude/settings.local.json"
    echo "Usage: claude-pin [--force]"
    exit 0 ;;
  --force) FORCE=1 ;;
  "") ;;
  *) echo "Unknown arg: $1 (try --help)" >&2; exit 1 ;;
esac
TARGET=".claude/settings.local.json"
if [[ -f "$TARGET" && $FORCE -eq 0 ]]; then
  echo "Refusing to overwrite existing $TARGET (use --force)." >&2; exit 1
fi
mkdir -p .claude
cat > "$TARGET" <<'JSON'
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "deny": [
      "Bash(rm:*)", "Bash(sudo:*)", "Bash(git push:*)",
      "Read(**/.env)", "Read(**/.env.*)",
      "Read(**/.ssh/**)", "Read(**/.aws/**)",
      "Read(**/id_rsa*)", "Read(**/*.pem)"
    ]
  }
}
JSON
echo "Pinned yolo settings to $(pwd)/$TARGET"
END_PIN

    cat > "$bin_dir/claude-help" <<'END_HELP'
#!/usr/bin/env bash
# claude-help — overview of all installed Claude Code helpers
cat <<'HELP'
Claude Code helper commands
═══════════════════════════

  claude-yolo    Launch with all prompts disabled (with safety denies).
                 Session-only; nothing written to disk.

  claude-edits   Launch with file edits auto-approved, Bash still prompts.
                 The safer middle ground.

  claude-pin     Persist yolo-style settings into ./.claude/ for the
                 current project. After this, plain `claude` inherits it.

  claude-help    This screen.

Quick reference
───────────────
  Prompts for everything:  claude
  Prompts only for Bash:   claude-edits
  Prompts for nothing*:    claude-yolo            (* with deny list)
  Make it sticky:          claude-pin

Deny list (applied by claude-yolo / claude-pin)
────────────────────────────────────────────────
  Bash:  rm, sudo, git push
  Read:  .env, .env.*, .ssh/**, .aws/**, id_rsa*, *.pem

Edit scripts in ~/bin/ to adjust the deny list to your taste.
HELP
END_HELP

    chmod +x "$bin_dir"/claude-{yolo,edits,pin,help}

    # Ensure ~/bin is on PATH hint
    local path_ok=false
    [[ ":$PATH:" == *":$bin_dir:"* ]] && path_ok=true

    _settings_status="Claude helpers installed to $bin_dir"
    _settings_status_color="${bgreen}${bold}"
    if ! $path_ok; then
        _settings_status+="  (add $bin_dir to PATH)"
        _settings_status_color="${byellow}${bold}"
    fi
}

_uninstall_claude_helpers() {
    local bin_dir
    bin_dir=$(_helpers_bin_dir)
    local removed=0
    local h
    for h in $(_helpers_list); do
        if [[ -f "$bin_dir/$h" ]]; then
            rm -f "$bin_dir/$h"
            (( removed++ ))
        fi
    done
    if (( removed > 0 )); then
        _settings_status="Removed $removed helper(s) from $bin_dir"
        _settings_status_color="${bgreen}${bold}"
    else
        _settings_status="No helpers found to remove"
        _settings_status_color="${dim}"
    fi
}

_draw_setting_row() {
    # Draw a single setting row with label, value, description, and optional highlight
    local row="$1" is_selected="$2" label="$3" value="$4" desc="$5" val_color="${6:-}"

    move_to "$row" 1
    if (( is_selected )); then
        tui '  %s>%s ' "${bgreen}${bold}" "${reset}"
        tui '%s%s%s' "${bwhite}${bold}" "$label" "${reset}"
        [[ -z "$val_color" ]] && val_color="${bg_sel}${bwhite}${bold}"
        tui '   %s< %s%s%s >%s' "${dim}" "$val_color" "$value" "${reset}${dim}" "${reset}"
        (( row++ ))
        move_to "$row" 1
        tui '      %s%s%s' "${dim}" "$desc" "${reset}"
    else
        tui '    '
        tui '%s%s%s' "${white}" "$label" "${reset}"
        tui '   %s%s%s' "${dim}" "$value" "${reset}"
    fi
}

_draw_settings() {
    local sel="$1" page="${2:-1}"
    clear_screen
    local term_lines term_cols
    term_lines=$(tput_lines)
    term_cols=$(tput_cols)

    # Header
    move_to 1 1
    tui '%s' "${bg_bblue}${bold}${white}"
    tui '                              '
    move_to 1 1
    tui '%s  S E T T I N G S  %s' "${bg_bblue}${bold}${white}" "${reset}"
    if (( page == 1 )); then
        tui '  %s[1/2]  General%s' "${dim}" "${reset}"
    else
        tui '  %s[2/2]  Advanced%s' "${dim}" "${reset}"
    fi

    # Separator
    move_to 3 1
    local sep_len=$(( term_cols - 4 ))
    (( sep_len > 70 )) && sep_len=70
    tui '  %s%s%s' "${dim}${cyan}" "$(printf '%*s' "$sep_len" '' | tr ' ' '-')" "${reset}"

    local row=5

    if (( page == 1 )); then
        # ── Page 1: General ──
        # 0: View Mode
        _draw_setting_row "$row" "$(( sel == 0 ))" "View Mode" "$view_mode" \
            "local = your projects only  |  all = include Claude Code history"
        (( row += (sel == 0 ? 3 : 2) ))

        # 1: Display Mode
        _draw_setting_row "$row" "$(( sel == 1 ))" "Display Mode" "$display_mode" \
            "compact = single line  |  full = multi-line  |  grid = cells"
        (( row += (sel == 1 ? 3 : 2) ))

        # 2: Sort Mode
        _draw_setting_row "$row" "$(( sel == 2 ))" "Sort Mode" "$sort_mode" \
            "date = encoded  |  modified = most recent file  |  recent = last opened  |  name  |  language"
        (( row += (sel == 2 ? 3 : 2) ))

        # 3: Hide Empty
        _draw_setting_row "$row" "$(( sel == 3 ))" "Hide Empty" "$hide_empty" \
            "Hide folders with no files (e.g. blank timestamp sessions)"
        (( row += (sel == 3 ? 3 : 2) ))

        # 4: Demo Mode
        local demo_desc="Anonymize all project names, paths & groups for screenshots"
        local demo_val_color=""
        [[ "$demo_mode" == "on" ]] && demo_val_color="${bg_magenta}${bwhite}${bold}"
        _draw_setting_row "$row" "$(( sel == 4 ))" "Demo Mode" "$demo_mode" \
            "$demo_desc" "$demo_val_color"

    else
        # ── Page 2: Advanced ──
        # 0: Title Persistence
        local tp_display
        tp_display=$(_tmux_display_value "$title_mode")
        local tp_val_color=""
        if ! _has_tmux; then
            case "$title_mode" in
                tmux_split|tmux_status) tp_val_color="${bg_red}${bwhite}${bold}" ;;
            esac
        fi
        _draw_setting_row "$row" "$(( sel == 0 ))" "Title Persistence" "$tp_display" \
            "How to show the project name while Claude is running" "$tp_val_color"
        if (( sel == 0 )); then
            (( row += 3 ))
            # Extra detail for title mode
            local -a tp_opts=(
                "none:          Window/tab title only"
                "window_title:  Same as none"
                "tmux_split:    Launch in tmux with title pane"
                "tmux_status:   Use tmux status bar (in tmux)"
                "scroll_region: ANSI scroll region (experimental)"
                "prompt:        Show in shell prompt after exit"
            )
            for opt in "${tp_opts[@]}"; do
                move_to "$row" 1
                tui '      %s%s%s' "${dim}" "$opt" "${reset}"
                (( row++ ))
            done
            if ! _has_tmux; then
                move_to "$row" 1
                tui '      %stmux is NOT installed. Press i to install.%s' "${bred}${bold}" "${reset}"
                (( row++ ))
            fi
        else
            (( row += 2 ))
        fi

        # 1: AI Agent
        local _agent_display="$agent"
        command -v "$agent" &>/dev/null || _agent_display="${agent} ${bred}(not found)${reset}"
        _draw_setting_row "$row" "$(( sel == 1 ))" "AI Agent" "$_agent_display" \
            "claude  claude-yolo  claude-edits  opencode  copilot  amp  cursor-agent  aider  gemini  codex"
        (( row += (sel == 1 ? 3 : 2) ))

        # 2: Auto-launch Agent
        _draw_setting_row "$row" "$(( sel == 2 ))" "Auto-launch Agent" "$auto_claude" \
            "on = run agent on open  |  off = just cd into directory"
        (( row += (sel == 2 ? 3 : 2) ))

        # 3: Match Threshold
        _draw_setting_row "$row" "$(( sel == 3 ))" "Quick-open Threshold" "${match_threshold}%" \
            "Minimum similarity % for instant open (0-100, higher = stricter)"
        (( row += (sel == 3 ? 3 : 2) ))

        # 4: Claude Helpers
        local _helpers_val
        _helpers_val=$(_helpers_status)
        local _helpers_color=""
        case "$_helpers_val" in
            installed)   _helpers_color="${bgreen}${bold}" ;;
            "not installed") _helpers_color="${dim}" ;;
            partial*)    _helpers_color="${byellow}${bold}" ;;
        esac
        _draw_setting_row "$row" "$(( sel == 4 ))" "Claude Helpers" "$_helpers_val" \
            "claude-yolo  claude-edits  claude-pin  claude-help  (in ~/bin/)" "$_helpers_color"
    fi

    # Status message
    if [[ -n "${_settings_status:-}" ]]; then
        move_to $(( term_lines - 3 )) 1
        tui '    %s%s%s' "${_settings_status_color:-$bwhite}" "$_settings_status" "${reset}"
    fi

    # Footer
    move_to "$term_lines" 1
    tui '  '
    tui '%s <- / -> %s change  ' "${bg_gray}${bwhite}${bold}" "${reset}${dim}"
    tui '%s up / dn %s navigate  ' "${bg_gray}${bwhite}${bold}" "${reset}${dim}"
    tui '%s tab %s page %d/2  ' "${bg_cyan}${black}${bold}" "${reset}${dim}" "$page"
    if (( page == 2 && sel == 0 )) && ! _has_tmux; then
        tui '%s i %s install tmux  ' "${bg_green}${black}${bold}" "${reset}${dim}"
    fi
    if (( page == 2 && sel == 4 )); then
        local _hstat
        _hstat=$(_helpers_status)
        if [[ "$_hstat" == "installed" ]]; then
            tui '%s u %s uninstall helpers  ' "${bg_red}${white}${bold}" "${reset}${dim}"
        else
            tui '%s i %s install helpers  ' "${bg_green}${black}${bold}" "${reset}${dim}"
        fi
    fi
    if (( page == 2 )); then
        tui '%s x %s export  ' "${bg_cyan}${black}${bold}" "${reset}${dim}"
        tui '%s m %s import  ' "${bg_cyan}${black}${bold}" "${reset}${dim}"
    fi
    tui '%s enter %s save  ' "${bg_green}${black}${bold}" "${reset}${dim}"
    tui '%s q %s discard'  "${bg_red}${white}${bold}" "${reset}${dim}"
    tui '%s' "${reset}"
}

_export_prefs() {
    local default_path="$HOME/claudemanager_prefs.txt"
    local export_path
    export_path=$(prompt_input "Export to: " "$default_path")
    [[ -z "$export_path" ]] && return
    {
        printf '# claudemanager preferences export\n'
        printf '# exported: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'view_mode=%s\n' "$view_mode"
        printf 'display_mode=%s\n' "$display_mode"
        printf 'sort_mode=%s\n' "$sort_mode"
        printf 'title_mode=%s\n' "$title_mode"
        printf 'auto_claude=%s\n' "$auto_claude"
        printf 'agent=%s\n' "$agent"
    } > "$export_path"
    _settings_status="Exported to $export_path"
    _settings_status_color="${bgreen}${bold}"
}

_import_prefs() {
    local default_path="$HOME/claudemanager_prefs.txt"
    local import_path
    import_path=$(prompt_input "Import from: " "$default_path")
    [[ -z "$import_path" ]] && return
    if [[ ! -f "$import_path" ]]; then
        _settings_status="File not found: $import_path"
        _settings_status_color="${bred}${bold}"
        return
    fi
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            view_mode)    view_mode="$val" ;;
            display_mode) display_mode="$val" ;;
            sort_mode)    sort_mode="$val" ;;
            title_mode)   title_mode="$val" ;;
            auto_claude)  auto_claude="$val" ;;
            agent)        agent="$val" ;;
        esac
    done < "$import_path"
    _settings_status="Imported from $import_path"
    _settings_status_color="${bgreen}${bold}"
}

_settings_has_changes() {
    [[ "$view_mode" != "$_orig_view_mode" ]] || \
    [[ "$display_mode" != "$_orig_display_mode" ]] || \
    [[ "$sort_mode" != "$_orig_sort_mode" ]] || \
    [[ "$title_mode" != "$_orig_title_mode" ]] || \
    [[ "$auto_claude" != "$_orig_auto_claude" ]] || \
    [[ "$agent" != "$_orig_agent" ]] || \
    [[ "$demo_mode" != "$_orig_demo_mode" ]] || \
    [[ "$hide_empty" != "$_orig_hide_empty" ]] || \
    [[ "$match_threshold" != "$_orig_match_threshold" ]]
}

do_settings() {
    local settings_sel=0
    local settings_page=1
    local page1_count=5   # View Mode, Display Mode, Sort Mode, Hide Empty, Demo Mode
    local page2_count=5   # Title Persistence, AI Agent, Auto-launch Agent, Match Threshold, Claude Helpers
    _settings_status=""
    _settings_status_color=""

    # Save originals for discard
    local _orig_view_mode="$view_mode"
    local _orig_display_mode="$display_mode"
    local _orig_sort_mode="$sort_mode"
    local _orig_title_mode="$title_mode"
    local _orig_auto_claude="$auto_claude"
    local _orig_agent="$agent"
    local _orig_demo_mode="$demo_mode"
    local _orig_hide_empty="$hide_empty"
    local _orig_match_threshold="$match_threshold"

    while true; do
        local cur_count=$page1_count
        (( settings_page == 2 )) && cur_count=$page2_count

        _draw_settings "$settings_sel" "$settings_page"
        local key
        key=$(read_key) || break
        case "$key" in
            $'\e[A'|k) (( settings_sel > 0 )) && (( settings_sel-- )); _settings_status="" ;;
            $'\e[B'|j) (( settings_sel < cur_count - 1 )) && (( settings_sel++ )) || true; _settings_status="" ;;
            $'\t')
                # Tab switches page
                if (( settings_page == 1 )); then
                    settings_page=2
                else
                    settings_page=1
                fi
                settings_sel=0
                _settings_status=""
                ;;
            $'\e[C'|l)
                _settings_status=""
                if (( settings_page == 1 )); then
                    case "$settings_sel" in
                        0) view_mode=$(_cycle_value "$view_mode" 1 local all) ;;
                        1) display_mode=$(_cycle_value "$display_mode" 1 compact full grid) ;;
                        2) sort_mode=$(_cycle_value "$sort_mode" 1 date modified recent name language) ;;
                        3) hide_empty=$(_cycle_value "$hide_empty" 1 on off) ;;
                        4) demo_mode=$(_cycle_value "$demo_mode" 1 off on) ;;
                    esac
                else
                    case "$settings_sel" in
                        0)
                            title_mode=$(_cycle_value "$title_mode" 1 none window_title tmux_split tmux_status scroll_region prompt)
                            if ! _has_tmux; then
                                case "$title_mode" in tmux_split|tmux_status) _install_tmux ;; esac
                            fi
                            ;;
                        1) agent=$(_cycle_value "$agent" 1 claude claude-yolo claude-edits opencode copilot amp cursor-agent aider gemini codex) ;;
                        2) auto_claude=$(_cycle_value "$auto_claude" 1 on off) ;;
                        3) (( match_threshold < 100 )) && (( match_threshold += 5 )) ;;
                    esac
                fi
                ;;
            $'\e[D'|h)
                _settings_status=""
                if (( settings_page == 1 )); then
                    case "$settings_sel" in
                        0) view_mode=$(_cycle_value "$view_mode" -1 local all) ;;
                        1) display_mode=$(_cycle_value "$display_mode" -1 compact full grid) ;;
                        2) sort_mode=$(_cycle_value "$sort_mode" -1 date modified recent name language) ;;
                        3) hide_empty=$(_cycle_value "$hide_empty" -1 on off) ;;
                        4) demo_mode=$(_cycle_value "$demo_mode" -1 off on) ;;
                    esac
                else
                    case "$settings_sel" in
                        0)
                            title_mode=$(_cycle_value "$title_mode" -1 none window_title tmux_split tmux_status scroll_region prompt)
                            if ! _has_tmux; then
                                case "$title_mode" in tmux_split|tmux_status) _install_tmux ;; esac
                            fi
                            ;;
                        1) agent=$(_cycle_value "$agent" -1 claude claude-yolo claude-edits opencode copilot amp cursor-agent aider gemini codex) ;;
                        2) auto_claude=$(_cycle_value "$auto_claude" -1 on off) ;;
                        3) (( match_threshold > 0 )) && (( match_threshold -= 5 )) ;;
                    esac
                fi
                ;;
            "")
                # Enter = save and exit
                _save_prefs
                status_msg="Settings saved"
                status_color="${bgreen}${bold}"
                break
                ;;
            i|I)
                if (( settings_page == 2 && settings_sel == 0 )) && ! _has_tmux; then
                    _install_tmux
                elif (( settings_page == 2 && settings_sel == 4 )); then
                    _install_claude_helpers
                fi
                ;;
            u|U)
                if (( settings_page == 2 && settings_sel == 4 )); then
                    local _hstat
                    _hstat=$(_helpers_status)
                    if [[ "$_hstat" == "installed" || "$_hstat" == partial* ]]; then
                        _uninstall_claude_helpers
                    else
                        _settings_status="Helpers not installed — press i to install"
                        _settings_status_color="${dim}"
                    fi
                fi
                ;;
            x|X) (( settings_page == 2 )) && _export_prefs ;;
            m|M) (( settings_page == 2 )) && _import_prefs ;;
            q|$'\x1b')
                if _settings_has_changes; then
                    local term_lines
                    term_lines=$(tput_lines)
                    move_to "$term_lines" 1
                    clear_line
                    tui '  %sDiscard changes? [y/N]%s ' "${byellow}${bold}" "${reset}"
                    local answer
                    IFS= read -rsn1 answer < /dev/tty
                    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
                        view_mode="$_orig_view_mode"
                        display_mode="$_orig_display_mode"
                        sort_mode="$_orig_sort_mode"
                        title_mode="$_orig_title_mode"
                        auto_claude="$_orig_auto_claude"
                        agent="$_orig_agent"
                        demo_mode="$_orig_demo_mode"
                        hide_empty="$_orig_hide_empty"
                        match_threshold="$_orig_match_threshold"
                        status_msg="Settings discarded"
                        status_color="${byellow}${bold}"
                        break
                    fi
                else
                    break
                fi
                ;;
        esac
    done
    # Reload dirs if view mode may have changed
    load_dirs
    _apply_groups_to_cache
    _apply_demo_mode
}

do_new()   { action="new"; }

do_new_with() {
    local -a known_agents=(claude claude-yolo claude-edits opencode copilot amp cursor-agent aider gemini codex)
    local sel=0
    local count=${#known_agents[@]}
    for (( i=0; i<count; i++ )); do
        [[ "${known_agents[$i]}" == "$agent" ]] && sel=$i && break
    done

    while true; do
        clear_screen
        local term_lines term_cols
        term_lines=$(tput_lines)
        term_cols=$(tput_cols)
        local row=2
        move_to "$row" 1
        tui '  %sNew project — choose agent:%s' "${bold}${bwhite}" "${reset}"
        (( row += 2 ))

        for (( i=0; i<count; i++ )); do
            move_to "$row" 1
            local a="${known_agents[$i]}"
            local is_installed=false
            command -v "$a" &>/dev/null && is_installed=true
            local tag=""
            $is_installed || tag="${bred}  not installed${reset}"
            [[ "$a" == "$agent" ]] && tag+="${dim}  [default]${reset}"
            local desc
            desc=$(_agent_desc "$a")

            if (( i == sel )); then
                tui '  %s> %s%s%s%s' "${bgreen}${bold}" "${bg_sel}${bwhite}${bold}" "$a" "${reset}" "$tag"
                (( row++ ))
                move_to "$row" 1
                tui '      %s%s%s' "${dim}" "$desc" "${reset}"
                (( row++ ))
                if ! $is_installed; then
                    move_to "$row" 1
                    tui '      %s$ %s%s%s' "${byellow}" "${reset}${yellow}" "$(_agent_install_cmd "$a")" "${reset}"
                    (( row++ ))
                fi
            else
                if $is_installed; then
                    tui '    %s%s%s  %s%s%s' "${bwhite}" "$a" "${reset}" "${dim}" "$desc" "${reset}"
                else
                    tui '    %s%s%s  %s(not installed)%s' "${dim}" "$a" "${reset}${dim}" "" "${reset}"
                fi
                (( row++ ))
            fi
        done

        move_to "$term_lines" 1
        tui '  %sj/k%s navigate  %senter%s create  %sq%s cancel' \
            "${bwhite}${bold}" "${reset}${dim}" \
            "${bwhite}${bold}" "${reset}${dim}" \
            "${bwhite}${bold}" "${reset}"

        local key
        key=$(read_key)
        case "$key" in
            $'\e[A' | k) (( sel > 0 )) && (( sel-- )) ;;
            $'\e[B' | j) (( sel < count - 1 )) && (( sel++ )) ;;
            "")
                local _chosen="${known_agents[$sel]}"
                _ensure_agent_installed "$_chosen" || continue
                open_agent_override="$_chosen"
                action="new"
                return
                ;;
            q | $'\x1b') return ;;
        esac
    done
}
do_open()  {
    (( ${#filtered[@]} == 0 )) && return
    local idx="${filtered[$selected]}"
    open_dir="${dirs[$idx]}"
    _record_open "$open_dir"
    action="open"
}
do_shell() {
    (( ${#filtered[@]} == 0 )) && return
    local idx="${filtered[$selected]}"
    open_dir="${dirs[$idx]}"
    _record_open "$open_dir"
    action="shell"
}

# Ensure an agent is installed, offering to install it if not.
# Returns 0 if ready to use, 1 if not installed (user declined or install failed).
_ensure_agent_installed() {
    local a="$1"
    command -v "$a" &>/dev/null && return 0

    local install_cmd
    install_cmd=$(_agent_install_cmd "$a")

    local term_lines
    term_lines=$(tput_lines)
    move_to "$term_lines" 1
    clear_line
    show_cursor
    tui '  %s%s%s not installed. Install now? [y/N] ' "${byellow}${bold}" "$a" "${reset}"
    local answer
    IFS= read -rsn1 answer < /dev/tty
    hide_cursor

    [[ "$answer" != "y" && "$answer" != "Y" ]] && return 1

    clear_screen
    move_to 1 1
    show_cursor
    tui '%s  Installing %s...%s\n\n' "${bwhite}${bold}" "$a" "${reset}"

    local ok=false
    case "$a" in
        claude-yolo|claude-edits|claude-pin|claude-help)
            _install_claude_helpers
            command -v "$a" &>/dev/null && ok=true
            ;;
        *)
            if eval "$install_cmd" < /dev/tty; then
                # rehash so the shell finds the new binary
                hash -r 2>/dev/null || true
                command -v "$a" &>/dev/null && ok=true
            fi
            ;;
    esac

    hide_cursor
    if $ok; then
        tui '\n%s  %s installed successfully!%s\n' "${bgreen}${bold}" "$a" "${reset}"
        sleep 1
        return 0
    else
        tui '\n%s  Install may have failed. Try manually:%s\n  %s%s%s\n' \
            "${bred}${bold}" "${reset}" "${dim}" "$install_cmd" "${reset}"
        tui '%s  Press any key...%s' "${dim}" "${reset}"
        IFS= read -rsn1 < /dev/tty
        return 1
    fi
}

_agent_desc() {
    case "$1" in
        claude)       printf 'Anthropic Claude Code — official CLI' ;;
        claude-yolo)  printf 'Claude with all prompts bypassed (+ safety deny list)' ;;
        claude-edits) printf 'Claude with file edits auto-approved; Bash still prompts' ;;
        opencode)     printf 'OpenCode — open-source AI coding assistant' ;;
        copilot)      printf 'GitHub Copilot in the CLI (gh extension)' ;;
        amp)          printf 'Amp by Sourcegraph — AI pair programmer' ;;
        cursor-agent) printf 'Cursor IDE agent mode' ;;
        aider)        printf 'Aider — AI pair programmer in your terminal' ;;
        gemini)       printf 'Google Gemini CLI' ;;
        codex)        printf 'OpenAI Codex CLI' ;;
        *)            printf '' ;;
    esac
}

_agent_install_cmd() {
    case "$1" in
        claude)       printf 'npm install -g @anthropic-ai/claude-code' ;;
        claude-yolo)  printf 'claudemanager , → tab → Claude Helpers → i' ;;
        claude-edits) printf 'claudemanager , → tab → Claude Helpers → i' ;;
        opencode)     printf 'curl -fsSL https://opencode.ai/install | sh' ;;
        copilot)      printf 'gh extension install github/gh-copilot' ;;
        amp)          printf 'curl -fsSL https://ampcode.com/install | sh' ;;
        cursor-agent) printf 'Install Cursor IDE — cursor.com' ;;
        aider)        printf 'pipx install aider-chat' ;;
        gemini)       printf 'npm install -g @google/gemini-cli' ;;
        codex)        printf 'npm install -g @openai/codex' ;;
        *)            printf 'see project documentation' ;;
    esac
}

# Approximate token usage for a project directory from its JSONL conversation files
_project_usage_summary() {
    local proj_dir="$1"
    awk '
    /\"inputTokens"/ { match($0,/"inputTokens":([0-9]+)/,a); in_tok+=a[1] }
    /\"outputTokens"/ { match($0,/"outputTokens":([0-9]+)/,a); out_tok+=a[1] }
    END {
        total = in_tok + out_tok
        if (total == 0) { print "no usage data"; exit }
        if (total >= 1000000) printf "%.1fM tokens (%dk in · %dk out)", total/1000000, in_tok/1000, out_tok/1000
        else if (total >= 1000) printf "%dk tokens (%dk in · %dk out)", total/1000, in_tok/1000, out_tok/1000
        else printf "%d tokens", total
    }' <(find "$proj_dir" -name '*.jsonl' -type f 2>/dev/null | xargs cat 2>/dev/null)
}

do_open_with() {
    (( ${#filtered[@]} == 0 )) && return
    local idx="${filtered[$selected]}"
    local title="${cache_title[$idx]}"
    local fullpath="${cache_fullpath[$idx]}"
    local -a known_agents=(claude claude-yolo claude-edits opencode copilot amp cursor-agent aider gemini codex)

    local sel=0
    local count=${#known_agents[@]}
    # Pre-select current default agent
    for (( i=0; i<count; i++ )); do
        [[ "${known_agents[$i]}" == "$agent" ]] && sel=$i && break
    done

    # Compute project usage once (can be slow on large projects, so do it outside the loop)
    local proj_usage
    proj_usage=$(_project_usage_summary "$fullpath")

    while true; do
        clear_screen
        local term_lines term_cols
        term_lines=$(tput_lines)
        term_cols=$(tput_cols)
        local row=2
        move_to "$row" 1
        tui '  %sOpen in agent:%s  %s%s%s' "${bold}${bwhite}" "${reset}" "${bold}${bcyan}" "$title" "${reset}"
        if [[ -n "$proj_usage" ]]; then
            tui '   %s%s%s' "${dim}" "$proj_usage" "${reset}"
        fi
        (( row += 2 ))

        for (( i=0; i<count; i++ )); do
            move_to "$row" 1
            local a="${known_agents[$i]}"
            local is_installed=false
            command -v "$a" &>/dev/null && is_installed=true

            local tag=""
            $is_installed || tag="${bred}  not installed${reset}"
            [[ "$a" == "$agent" ]] && tag+="${dim}  [default]${reset}"

            local desc
            desc=$(_agent_desc "$a")

            if (( i == sel )); then
                tui '  %s> %s%s%s%s' "${bgreen}${bold}" "${bg_sel}${bwhite}${bold}" "$a" "${reset}" "$tag"
                (( row++ ))
                # Description line
                move_to "$row" 1
                tui '      %s%s%s' "${dim}" "$desc" "${reset}"
                (( row++ ))
                # Install hint if not installed
                if ! $is_installed; then
                    move_to "$row" 1
                    local install_cmd
                    install_cmd=$(_agent_install_cmd "$a")
                    tui '      %s$ %s%s%s' "${byellow}" "${reset}${yellow}" "$install_cmd" "${reset}"
                    (( row++ ))
                fi
            else
                if $is_installed; then
                    tui '    %s%s%s  %s%s%s' "${bwhite}" "$a" "${reset}" "${dim}" "$desc" "${reset}"
                else
                    tui '    %s%s%s  %s%s%s' "${dim}" "$a" "${reset}${dim}" "  (not installed)" "${reset}"
                fi
                (( row++ ))
            fi
        done

        move_to "$term_lines" 1
        tui '  %sj/k%s navigate  %senter%s open  %sq%s cancel' \
            "${bwhite}${bold}" "${reset}${dim}" \
            "${bwhite}${bold}" "${reset}${dim}" \
            "${bwhite}${bold}" "${reset}"

        local key
        key=$(read_key)
        case "$key" in
            $'\e[A' | k) (( sel > 0 )) && (( sel-- )) ;;
            $'\e[B' | j) (( sel < count - 1 )) && (( sel++ )) ;;
            "")
                local _chosen="${known_agents[$sel]}"
                _ensure_agent_installed "$_chosen" || continue
                open_agent_override="$_chosen"
                open_force_run=true
                do_open
                return
                ;;
            q | $'\x1b') return ;;
        esac
    done
}

# ── Fuzzy match (Levenshtein via awk) ─────────────────────────────
_levenshtein() {
    # Returns edit distance between two strings (case-insensitive)
    awk -v a="${1,,}" -v b="${2,,}" 'BEGIN {
        m = length(a); n = length(b)
        for (i = 0; i <= m; i++) d[i,0] = i
        for (j = 0; j <= n; j++) d[0,j] = j
        for (i = 1; i <= m; i++)
            for (j = 1; j <= n; j++) {
                cost = (substr(a,i,1) != substr(b,j,1)) ? 1 : 0
                ins = d[i,j-1] + 1
                del = d[i-1,j] + 1
                rep = d[i-1,j-1] + cost
                d[i,j] = ins < del ? ins : del
                if (rep < d[i,j]) d[i,j] = rep
            }
        print d[m,n]
    }'
}

_try_quick_open() {
    local query="${1,,}"
    local force="${2:-0}"
    [[ -z "$query" ]] && return 1

    local best_idx=-1 best_score=0
    local i
    for (( i = 0; i < ${#dirs[@]}; i++ )); do
        local title="${cache_title[$i],,}"
        [[ -z "$title" ]] && continue
        local maxlen=${#title}
        (( ${#query} > maxlen )) && maxlen=${#query}
        (( maxlen == 0 )) && continue
        local dist
        dist=$(_levenshtein "$query" "$title")
        local score=$(( (maxlen - dist) * 100 / maxlen ))
        if (( score > best_score )); then
            best_score=$score
            best_idx=$i
        fi
    done

    local gate=$match_threshold
    (( force )) && gate=0
    if (( best_idx >= 0 && best_score >= gate )); then
        open_dir="${dirs[$best_idx]}"
        _record_open "$open_dir"
        action="open"
        selected=0
        # Find filtered index for result file
        local fi
        for (( fi = 0; fi < ${#filtered[@]}; fi++ )); do
            if (( filtered[fi] == best_idx )); then
                selected=$fi
                break
            fi
        done
        return 0
    fi
    return 1
}

# ── Main ──────────────────────────────────────────────────────────
cleanup() {
    [[ -n "${_spinner_pid:-}" ]] && kill "$_spinner_pid" 2>/dev/null && wait "$_spinner_pid" 2>/dev/null || true
    disable_mouse 2>/dev/null || true
    show_cursor
    clear_screen
    stty sane 2>/dev/null || true
}
trap cleanup EXIT

_spinner_pid=""
_start_spinner() {
    (
        local frames=('|' '/' '-' '\')
        local i=0
        hide_cursor
        while true; do
            move_to 1 1
            tui '  %s%s Loading...%s' "${bold}${cyan}" "${frames[$i]}" "${reset}"
            i=$(( (i + 1) % 4 ))
            sleep 0.1
        done
    ) &
    _spinner_pid=$!
}
_stop_spinner() {
    if [[ -n "$_spinner_pid" ]]; then
        kill "$_spinner_pid" 2>/dev/null
        wait "$_spinner_pid" 2>/dev/null || true
        _spinner_pid=""
    fi
}

# ── Self-install / refresh ────────────────────────────────────────

_install_detect_profile() {
    local shell_name
    shell_name=$(basename "${SHELL:-bash}")
    case "$shell_name" in
        zsh)
            [[ -f "$HOME/.zshrc" ]] && echo "$HOME/.zshrc" || echo "$HOME/.zprofile" ;;
        bash)
            if [[ -f "$HOME/.bashrc" ]]; then echo "$HOME/.bashrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then echo "$HOME/.bash_profile"
            else echo "$HOME/.profile"; fi ;;
        *) echo "$HOME/.profile" ;;
    esac
}

_install_remove_old_wrapper() {
    local profile="$1"
    if grep -q 'claudemanager()' "$profile" 2>/dev/null || \
       grep -q '_cm_launch_claude()' "$profile" 2>/dev/null; then
        sed -i.bak '/# ── claudemanager ──/,/# ── \/claudemanager ──/d' "$profile"
        rm -f "${profile}.bak"
        local tmpprofile
        tmpprofile=$(mktemp "${profile}.XXXXXX")
        awk '
            /^_cm_launch_claude\(\)/ || /^claudemanager\(\)/ { skip=1; brace=0; next }
            skip && /\{/ { brace++ }
            skip && /^\}/ { brace--; if (brace <= 0) { skip=0 }; next }
            skip { next }
            !skip { print }
        ' "$profile" > "$tmpprofile" && mv "$tmpprofile" "$profile" || rm -f "$tmpprofile"
    fi
}

_install_write_wrapper() {
    local install_dir="$1" profile="$2"
    cat >> "$profile" << WRAPPER

# ── claudemanager ─────────────────────────────────────────────────
# TUI for managing Claude Code project directories.
# Opens a project picker; selecting a project cd's into it and optionally runs an AI agent.
_cm_launch_claude() {
    local title="\$1" mode="\$2" agent_cmd="\${3:-claude}"

    # Always set the terminal window/tab title (non-intrusive, works everywhere)
    if [[ -n "\$title" ]]; then
        printf '\\e]0;claudemanager: %s\\a' "\$title"
    fi

    case "\$mode" in
        tmux_split)
            if ! command -v tmux &>/dev/null; then
                printf '\\e[33mtmux is not installed. Falling back to window/tab title.\\e[0m\\n'
                printf '\\e[2mPress , in claudemanager to open settings and install tmux.\\e[0m\\n'
                sleep 2
                \$agent_cmd
            else
                local sess="cm_\$\$"
                local old_tmux="\${TMUX:-}"
                unset TMUX
                tmux new-session -d -s "\$sess" -x "\$(tput cols)" -y "\$(tput lines)"
                tmux split-window -v -b -l 2 -t "\$sess"
                tmux send-keys -t "\$sess:0.0" "printf '\\\\e[44;1;37m  %-*s\\\\e[0m' \$(tput cols) '  \$title'; exec cat" Enter
                tmux send-keys -t "\$sess:0.1" "\$agent_cmd; tmux kill-session -t \$sess 2>/dev/null" Enter
                tmux set -t "\$sess" status off
                tmux attach -t "\$sess"
                [[ -n "\$old_tmux" ]] && export TMUX="\$old_tmux"
            fi
            ;;
        tmux_status)
            if ! command -v tmux &>/dev/null; then
                printf '\\e[33mtmux is not installed. Falling back to window/tab title.\\e[0m\\n'
                printf '\\e[2mPress , in claudemanager to open settings and install tmux.\\e[0m\\n'
                sleep 2
                \$agent_cmd
            elif [[ -n "\${TMUX:-}" ]]; then
                local old_status
                old_status=\$(tmux show-option -gqv status-left)
                tmux set -g status-left "#[bg=blue,fg=white,bold]  \$title  #[default] "
                \$agent_cmd
                tmux set -g status-left "\$old_status"
            else
                \$agent_cmd
            fi
            ;;
        scroll_region)
            local lines=\$(tput lines)
            local cols=\$(tput cols)
            printf '\\e[1;1H\\e[44;1;37m  %-*s\\e[0m' "\$cols" "  \$title"
            printf '\\e[2;%dr' "\$lines"
            printf '\\e[2;1H'
            \$agent_cmd
            printf '\\e[r'
            ;;
        prompt)
            \$agent_cmd
            if [[ -n "\${BASH_VERSION:-}" ]]; then
                PROMPT_COMMAND="printf '\\e[44;1;37m  %-*s\\e[0m\\n' \$(tput cols) '  \$title'; \${PROMPT_COMMAND:-}"
            elif [[ -n "\${ZSH_VERSION:-}" ]]; then
                precmd() { printf '\\e[44;1;37m  %-*s\\e[0m\\n' "\$(tput cols)" "  \$title"; }
            fi
            ;;
        window_title|none|*)
            \$agent_cmd
            ;;
    esac

    if [[ -n "\$title" ]]; then
        printf '\\e]0;%s\\a' "\${TERM_PROGRAM:-Terminal}"
    fi
}
claudemanager() {
    # Pass subcommands (--install, --refresh, etc.) directly — no tmpfile needed
    case "\${1:-}" in
        --install|--refresh)
            "${install_dir}/claudemanager.sh" "\$@"
            return
            ;;
    esac
    local tmpfile
    tmpfile=\$(mktemp /tmp/claudemanager.XXXXXX)
    CLAUDEMANAGER_RESULT="\$tmpfile" "${install_dir}/claudemanager.sh" "\$@"
    local dir="" run_claude=false title="" title_mode="none" agent_cmd="claude"
    if [[ -f "\$tmpfile" ]]; then
        while IFS= read -r line; do
            case "\$line" in
                __CLAUDE_CD__:*)      dir="\${line#__CLAUDE_CD__:}" ;;
                __CLAUDE_RUN__)       run_claude=true ;;
                __CLAUDE_TITLE__:*)   title="\${line#__CLAUDE_TITLE__:}" ;;
                __AGENT_CMD__:*)      agent_cmd="\${line#__AGENT_CMD__:}" ;;
                __CLAUDE_TITLE_MODE__:*) title_mode="\${line#__CLAUDE_TITLE_MODE__:}" ;;
            esac
        done < "\$tmpfile"
        rm -f "\$tmpfile"
    fi
    if [[ -n "\$dir" ]]; then
        cd "\$dir" || return 1
        if \$run_claude; then
            _cm_launch_claude "\$title" "\$title_mode" "\$agent_cmd"
        fi
    fi
}
# ── /claudemanager ──
WRAPPER
}

cmd_install() {
    local install_dir="${CLAUDEMANAGER_HOME:-$HOME/.claudemanager}"
    local self
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    local _green=$'\e[32m' _cyan=$'\e[36m' _yellow=$'\e[33m' _bold=$'\e[1m' _dim=$'\e[2m' _rst=$'\e[0m'
    _ci_info()  { printf '%s[info]%s  %s\n' "${_cyan}${_bold}" "${_rst}" "$*"; }
    _ci_ok()    { printf '%s[ok]%s    %s\n' "${_green}${_bold}" "${_rst}" "$*"; }

    printf '\n%s  C L A U D E   M A N A G E R   I N S T A L L E R%s\n' "${_bold}${_cyan}" "${_rst}"
    printf '  %sKinsman Software LLC%s\n\n' "${_dim}" "${_rst}"

    # 1. Create install dir
    [[ -d "$install_dir" ]] || { _ci_info "Creating $install_dir"; mkdir -p "$install_dir"; }
    _ci_ok "Install directory: $install_dir"

    # 2. Copy self to install dir (unless already running from there)
    local target="$install_dir/claudemanager.sh"
    if [[ "$(realpath "$self" 2>/dev/null || echo "$self")" != \
          "$(realpath "$target" 2>/dev/null || echo "$target")" ]]; then
        _ci_info "Installing to $target"
        cp "$self" "$target"
        chmod +x "$target"
    fi
    _ci_ok "Installed claudemanager.sh → $target"

    # 3. Detect Claude projects
    local claude_projects_dir="$HOME/.claude/projects"
    if [[ -d "$claude_projects_dir" ]]; then
        local project_count
        project_count=$(find "$claude_projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        _ci_ok "Found $project_count projects in Claude history (~/.claude/projects)"
    fi

    # 4. Shell wrapper
    local profile
    profile=$(_install_detect_profile)
    if grep -q 'claudemanager()' "$profile" 2>/dev/null || \
       grep -q '_cm_launch_claude()' "$profile" 2>/dev/null; then
        _ci_info "Updating existing wrapper in $profile"
    else
        _ci_info "Adding shell function to $profile"
    fi
    _install_remove_old_wrapper "$profile"
    _install_write_wrapper "$install_dir" "$profile"
    _ci_ok "Shell wrapper written to $profile"

    # 5. CLAUDE_BASE if custom
    if [[ "${CLAUDE_BASE:-$install_dir}" != "$install_dir" ]]; then
        if ! grep -q 'export CLAUDE_BASE=' "$profile" 2>/dev/null; then
            printf '\nexport CLAUDE_BASE="%s"\n' "$CLAUDE_BASE" >> "$profile"
            _ci_ok "Set CLAUDE_BASE=$CLAUDE_BASE in $profile"
        fi
    fi

    printf '\n%s  Done!%s\n' "${_bold}${_green}" "${_rst}"
    printf '  Restart your shell or run: %ssource %s%s\n' "${_dim}" "$profile" "${_rst}"
    printf '  Then type: %sclaudemanager%s\n\n' "${_bold}" "${_rst}"
}

cmd_refresh() {
    local install_dir="${CLAUDEMANAGER_HOME:-$HOME/.claudemanager}"
    local _green=$'\e[32m' _cyan=$'\e[36m' _bold=$'\e[1m' _dim=$'\e[2m' _rst=$'\e[0m'

    local profile
    profile=$(_install_detect_profile)

    printf '\n%s  Refreshing shell wrapper...%s\n\n' "${_bold}${_cyan}" "${_rst}"
    _install_remove_old_wrapper "$profile"
    _install_write_wrapper "$install_dir" "$profile"
    printf '%s[ok]%s    Shell wrapper updated in %s\n' "${_green}${_bold}" "${_rst}" "$profile"
    printf '  Run: %ssource %s%s\n\n' "${_dim}" "$profile" "${_rst}"
}

main() {
    # Handle install/refresh subcommands before TUI init
    case "${1:-}" in
        --install) cmd_install; return ;;
        --refresh) cmd_refresh; return ;;
    esac

    # -o <query>: force-open best match (no threshold gate)
    local _force_open=0
    if [[ "${1:-}" == "-o" || "${1:-}" == "--open" ]]; then
        _force_open=1
        shift
    fi

    _start_spinner
    load_dirs
    _apply_groups_to_cache
    _apply_demo_mode
    _stop_spinner

    # Handle CLI argument: quick-open or pre-fill search
    if [[ -n "${1:-}" ]]; then
        if _try_quick_open "$1" "$_force_open"; then
            # Skip TUI — write result and exit
            show_cursor
            local result_file="${CLAUDEMANAGER_RESULT:-}"
            if [[ -n "$result_file" ]]; then
                local idx="${filtered[$selected]}"
                printf '__CLAUDE_CD__:%s\n' "$open_dir" > "$result_file"
                [[ "$auto_claude" == "on" ]] && printf '__CLAUDE_RUN__\n' >> "$result_file"
                printf '__AGENT_CMD__:%s\n' "${open_agent_override:-$agent}" >> "$result_file"
                printf '__CLAUDE_TITLE__:%s\n' "${cache_title[$idx]}" >> "$result_file"
                printf '__CLAUDE_TITLE_MODE__:%s\n' "$title_mode" >> "$result_file"
            fi
            return
        else
            # No close match — pre-fill search query
            search_query="$1"
            apply_filter
        fi
    fi

    hide_cursor
    enable_mouse

    while true; do
        draw
        local key
        key=$(read_key) || { action="quit"; break; }

        # Mouse SGR event: \e[<btn;col;rowM (press) or m (release)
        if [[ "$key" == $'\e'\[\<* ]]; then
            local _body="${key#$'\e'\[\<}"
            local _act="${_body: -1}"   # M or m
            local _coords="${_body%[Mm]}"
            local _btn _col _row
            IFS=";" read -r _btn _col _row <<< "$_coords"
            case "$_btn" in
                64) # wheel up
                    if [[ "$_mouse_display_mode" == "grid" ]]; then
                        (( selected >= _mouse_grid_cols )) && (( selected -= _mouse_grid_cols ))
                    else
                        (( selected > 0 )) && (( selected-- )) || true
                    fi
                    continue
                    ;;
                65) # wheel down
                    if [[ "$_mouse_display_mode" == "grid" ]]; then
                        (( selected + _mouse_grid_cols < ${#filtered[@]} )) && (( selected += _mouse_grid_cols )) || true
                    else
                        (( selected < ${#filtered[@]} - 1 )) && (( selected++ )) || true
                    fi
                    continue
                    ;;
                0) # left button
                    if [[ "$_act" == "M" ]]; then
                        # Check keybinding-bar buttons first
                        local _bi _btn_match=0 _btn_hit_key=""
                        for (( _bi = 0; _bi < ${#_mouse_btn_rows[@]}; _bi++ )); do
                            if (( _row == _mouse_btn_rows[_bi] && _col >= _mouse_btn_starts[_bi] && _col <= _mouse_btn_ends[_bi] )); then
                                _btn_match=1
                                _btn_hit_key="${_mouse_btn_keys[$_bi]}"
                                break
                            fi
                        done
                        if (( _btn_match == 1 )); then
                            key="$_btn_hit_key"
                        else
                            # Map click to item index
                            local _cidx=-1
                            if [[ "$_mouse_display_mode" == "grid" ]]; then
                                local _gr=$(( (_row - _mouse_list_start) / _mouse_cell_height ))
                                local _gc=$(( (_col - 2) / _mouse_cell_width ))
                                (( _gr >= 0 && _gc >= 0 && _gc < _mouse_grid_cols )) && _cidx=$(( scroll_offset + _gr * _mouse_grid_cols + _gc ))
                            else
                                local _lr=$(( (_row - _mouse_list_start) / _mouse_row_height ))
                                local _lc=0
                                (( _mouse_list_cols == 2 && _col >= _mouse_right_col_start )) && _lc=1
                                if (( _lr >= 0 && _lr < _mouse_list_max_rows )); then
                                    _cidx=$(( scroll_offset + _lr + _lc * _mouse_list_max_rows ))
                                fi
                            fi
                            if (( _cidx >= 0 && _cidx < ${#filtered[@]} )); then
                                if (( _cidx == selected )); then
                                    # Click on already-selected item → treat as Enter
                                    key=""
                                else
                                    selected="$_cidx"
                                    continue
                                fi
                            else
                                continue
                            fi
                        fi
                    else
                        continue
                    fi
                    ;;
                *) continue ;;
            esac
        fi

        # Compute grid_cols for navigation (must match draw)
        local nav_grid_cols=1
        if [[ "$display_mode" == "grid" ]]; then
            local _tc
            _tc=$(tput_cols)
            nav_grid_cols=$(( (_tc - 2) / 24 ))
            (( nav_grid_cols < 1 )) && nav_grid_cols=1
        fi

        case "$key" in
            $'\e[A' | k)
                if [[ "$display_mode" == "grid" ]]; then
                    (( selected >= nav_grid_cols )) && (( selected -= nav_grid_cols ))
                else
                    (( selected > 0 )) && (( selected-- ))
                fi
                ;;
            $'\e[B' | j)
                if [[ "$display_mode" == "grid" ]]; then
                    (( selected + nav_grid_cols < ${#filtered[@]} )) && (( selected += nav_grid_cols )) || true
                else
                    (( selected < ${#filtered[@]} - 1 )) && (( selected++ )) || true
                fi
                ;;
            $'\e[D' | h)
                if [[ "$display_mode" == "grid" ]]; then
                    (( selected > 0 )) && (( selected-- ))
                elif [[ "$display_mode" == "compact" && _mouse_list_cols == 2 ]]; then
                    local _pos=$(( selected - scroll_offset ))
                    local _lc=$(( _pos / _mouse_list_max_rows ))
                    (( _lc > 0 )) && (( selected -= _mouse_list_max_rows ))
                fi
                ;;
            $'\e[C' | l)
                if [[ "$display_mode" == "grid" ]]; then
                    (( selected < ${#filtered[@]} - 1 )) && (( selected++ )) || true
                elif [[ "$display_mode" == "compact" && _mouse_list_cols == 2 ]]; then
                    local _pos=$(( selected - scroll_offset ))
                    local _lc=$(( _pos / _mouse_list_max_rows ))
                    (( _lc == 0 && selected + _mouse_list_max_rows < ${#filtered[@]} )) && (( selected += _mouse_list_max_rows ))
                fi
                ;;
            $'\e[5~')     (( selected -= 5 )); (( selected < 0 )) && selected=0 ;;
            $'\e[6~')     (( selected += 5 )); (( selected >= ${#filtered[@]} )) && selected=$(( ${#filtered[@]} - 1 )); (( selected < 0 )) && selected=0 ;;
            "")           do_open ;;
            /)            do_search ;;
            $'\x1b')      if [[ -n "$search_query" ]]; then do_clear_search; else do_about; fi ;;
            n)            do_new ;;
            N)            do_new_with ;;
            r)            do_rename ;;
            R)            do_smart_rename ;;
            m)            do_move_dir ;;
            e)            do_edit_desc ;;
            d)            do_delete ;;
            s)            do_shell ;;
            A)            do_open_with ;;
            c)            do_toggle_compact ;;
            p)            do_toggle_view ;;
            t)            do_toggle_sort ;;
            a)            do_add_dir ;;
            f)            do_refresh ;;
            g)            do_assign_group ;;
            G)            do_groups ;;
            '#')          do_auto_group ;;
            S)            do_stats ;;
            ,)            do_settings ;;
            ?)            do_about ;;
        esac

        [[ -n "$action" ]] && break
    done

    show_cursor
    clear_screen

    # Write signals to result file (read by wrapper function)
    local result_file="${CLAUDEMANAGER_RESULT:-}"
    if [[ -n "$result_file" ]]; then
        case "$action" in
            open)
                local idx="${filtered[$selected]}"
                local _effective_agent="${open_agent_override:-$agent}"
                printf '__CLAUDE_CD__:%s\n' "$open_dir" > "$result_file"
                { [[ "$auto_claude" == "on" ]] || $open_force_run; } && printf '__CLAUDE_RUN__\n' >> "$result_file"
                printf '__AGENT_CMD__:%s\n' "$_effective_agent" >> "$result_file"
                printf '__CLAUDE_TITLE__:%s\n' "${cache_title[$idx]}" >> "$result_file"
                printf '__CLAUDE_TITLE_MODE__:%s\n' "$title_mode" >> "$result_file"
                ;;
            shell)
                printf '__CLAUDE_CD__:%s\n' "$open_dir" > "$result_file"
                ;;
            new)
                local new_dir="$CLAUDE_BASE/$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$new_dir"
                local _new_agent="${open_agent_override:-$agent}"
                printf '__CLAUDE_CD__:%s\n' "$new_dir" > "$result_file"
                { [[ "$auto_claude" == "on" ]] || [[ -n "$open_agent_override" ]]; } && printf '__CLAUDE_RUN__\n' >> "$result_file"
                printf '__AGENT_CMD__:%s\n' "$_new_agent" >> "$result_file"
                printf '__CLAUDE_TITLE__:%s\n' "$(basename "$new_dir")" >> "$result_file"
                printf '__CLAUDE_TITLE_MODE__:%s\n' "$title_mode" >> "$result_file"
                ;;
            quit) ;;
        esac
    fi
}

main "$@"
