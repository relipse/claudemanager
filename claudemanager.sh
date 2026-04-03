#!/usr/bin/env bash
# claudemanager - Colorful TUI for managing Claude project directories
# Copyright (C) 2026 Kinsman Software LLC. All rights reserved.
# All TUI I/O goes through /dev/tty so the wrapper function can capture stdout signals.

set -uo pipefail

CLAUDE_BASE="${CLAUDE_BASE:-$HOME/.claudemanager}"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
EXTRA_DIRS_FILE="$CLAUDE_BASE/.claudemanager_dirs"
CACHE_FILE="$CLAUDE_BASE/.claudemanager_cache"
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
show_cursor()  { tui '\e[?25h'; }
move_to()      { tui '\e[%d;%dH' "$1" "$2"; }
clear_screen() { tui '\e[2J\e[H'; }
clear_line()   { tui '\e[2K'; }

# ── State ─────────────────────────────────────────────────────────
selected=0
scroll_offset=0
action=""
open_dir=""
status_msg=""
status_color="$green"
search_query=""
sort_mode="date"       # date | name | language
view_mode="local"      # local | all
display_mode="compact"  # compact | full | grid
title_mode="scroll_region" # none | window_title | tmux_split | tmux_status | scroll_region | prompt
auto_claude="on"       # on | off
match_threshold=95     # 0-100, minimum similarity % for quick-open
demo_mode="off"        # off | on — anonymize project names/paths for screenshots

# ── Preferences persistence ──────────────────────────────────────
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
            match_threshold)  match_threshold="$val" ;;
            demo_mode)        demo_mode="$val" ;;
        esac
    done < "$PREFS_FILE"
}

_save_prefs() {
    printf 'view_mode=%s\ndisplay_mode=%s\nsort_mode=%s\ntitle_mode=%s\nauto_claude=%s\nmatch_threshold=%s\ndemo_mode=%s\n' \
        "$view_mode" "$display_mode" "$sort_mode" "$title_mode" "$auto_claude" "$match_threshold" "$demo_mode" > "$PREFS_FILE"
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
declare -a cache_group=()      # group/client name per project
declare -A group_map=()        # group_map["path"] = "group_name"

_load_groups

# ── Filtered view (indices into dirs[]) ──────────────────────────
declare -a filtered=()

apply_filter() {
    filtered=()
    local i
    for (( i = 0; i < ${#dirs[@]}; i++ )); do
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
        printf '%s' "${app_dirs[0]}"
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
            printf '%s' "$prefix"
            return
        fi
    fi
    # 3. Fall back to directory basename
    basename "$dir"
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
        esac
    done

    # Sort and rebuild arrays
    local -a sorted_indices=()
    if [[ "$sort_mode" == "date" || "$sort_mode" == "recent" ]]; then
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
    local -a new_source=() new_fullpath=() new_epoch=() new_mtime=()
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
}

# ── Disk cache for fast startup ──────────────────────────────────
declare -A disk_cache=()
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
    local diff_days=$(( (now_epoch - then_epoch) / 86400 ))
    if (( diff_days < 0 )); then _reldate=""
    elif (( diff_days == 0 )); then _reldate="today"
    elif (( diff_days == 1 )); then _reldate="yesterday"
    elif (( diff_days < 7 )); then _reldate="${diff_days}d ago"
    elif (( diff_days < 30 )); then _reldate="$(( diff_days / 7 ))w ago"
    elif (( diff_days < 365 )); then _reldate="$(( diff_days / 30 ))mo ago"
    else _reldate="$(( diff_days / 365 ))y ago"
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
    while IFS=$'\t' read -r c_path c_mtime c_title c_date c_desc c_files c_lang c_framework c_epoch; do
        [[ -z "$c_path" || "$c_path" == \#* ]] && continue
        disk_cache["$c_path"]="${c_mtime}	${c_title}	${c_date}	${c_desc}	${c_files}	${c_lang}	${c_framework}	${c_epoch}"
    done < "$CACHE_FILE"
}

_save_disk_cache() {
    local i
    {
        printf '# claudemanager cache - auto-generated\n'
        for (( i = 0; i < ${#dirs[@]}; i++ )); do
            local d="${dirs[$i]}"
            local mtime="${cache_mtime[$i]:-}"
            [[ -z "$mtime" ]] && mtime=$(stat -f '%m' "$d" 2>/dev/null || echo "0")
            local t="${cache_title[$i]//$'\t'/ }"
            local dt="${cache_date[$i]//$'\t'/ }"
            local ds="${cache_desc[$i]//$'\t'/ }"
            local f="${cache_files[$i]}"
            local l="${cache_lang[$i]}"
            local fw="${cache_framework[$i]//$'\t'/ }"
            local ep="${cache_epoch[$i]}"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$mtime" "$t" "$dt" "$ds" "$f" "$l" "$fw" "$ep"
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

    # Try disk cache (mtime-based invalidation)
    if [[ "$use_cache" == "true" && -n "$dir_mtime" ]]; then
        local cached="${disk_cache[$d]:-}"
        if [[ -n "$cached" ]]; then
            local c_mtime c_title c_date c_desc c_files c_lang c_framework c_epoch
            IFS=$'\t' read -r c_mtime c_title c_date c_desc c_files c_lang c_framework c_epoch <<< "$cached"
            if [[ "$c_mtime" == "$dir_mtime" ]]; then
                cache_title+=("$c_title")
                cache_date+=("$c_date")
                _epoch_to_reldate "$c_epoch" "$now_epoch"
                cache_reldate+=("$_reldate")
                cache_desc+=("$c_desc")
                cache_files+=("$c_files")
                cache_lang+=("$c_lang")
                _set_lang_color "$c_lang"
                cache_langcolor+=("$_lcolor")
                cache_framework+=("$c_framework")
                cache_epoch+=("$c_epoch")
                return
            fi
        fi
    fi

    # Cache miss - compute everything
    cache_title+=("$(_compute_title "$d")")
    cache_date+=("$(_compute_date "$d")")
    local ep
    ep=$(_compute_epoch "$d")
    cache_epoch+=("$ep")
    _epoch_to_reldate "$ep" "$now_epoch"
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
                local decoded_path
                decoded_path=$(basename "$proj_dir" | sed 's/^-/\//; s/-/\//g')
                # Verify directory exists and isn't inside CLAUDE_BASE
                if [[ -d "$decoded_path" ]]; then
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
            if [[ -z "$cached" || -z "$mt" ]]; then
                (( miss_count++ ))
            else
                local c_mtime
                IFS=$'\t' read -r c_mtime _ <<< "$cached"
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
}

# ── Drawing ───────────────────────────────────────────────────────
draw() {
    local term_lines term_cols
    term_lines=$(tput_lines)
    term_cols=$(tput_cols)

    clear_screen

    # ── Header ──
    move_to 1 1
    tui '%s' "${bg_bblue}${bold}${white}"
    tui '                              '
    move_to 1 1
    tui '%s  C L A U D E   M A N A G E R  %s' "${bg_bblue}${bold}${white}" "${reset}"
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

    # Keybindings bar
    move_to 2 1
    tui '  '
    tui '%s enter %s open  '    "${bg_gray}${bwhite}${bold}"   "${reset}${dim}"
    tui '%s / %s search  '      "${bg_bblue}${white}${bold}"   "${reset}${dim}"
    tui '%s n %s new  '         "${bg_green}${black}${bold}"    "${reset}${dim}"
    tui '%s p %s all  '         "${bg_cyan}${black}${bold}"     "${reset}${dim}"
    tui '%s t %s sort  '        "${bg_yellow}${black}${bold}"   "${reset}${dim}"
    tui '%s c %s view  '          "${bg_yellow}${black}${bold}"   "${reset}${dim}"
    tui '%s a %s add  '         "${bg_green}${black}${bold}"  "${reset}${dim}"
    tui '%s R %s rename  '       "${bg_cyan}${black}${bold}"     "${reset}${dim}"
    tui '%s f %s refresh  '     "${bg_magenta}${white}${bold}" "${reset}${dim}"
    tui '%s g %s group  '       "${bg_green}${black}${bold}"     "${reset}${dim}"
    tui '%s # %s auto-grp  '    "${bg_magenta}${white}${bold}"  "${reset}${dim}"
    tui '%s S %s stats  '       "${bg_cyan}${black}${bold}"     "${reset}${dim}"
    tui '%s d %s del  '         "${bg_red}${white}${bold}"      "${reset}${dim}"
    tui '%s , %s settings  '    "${bg_gray}${bwhite}${bold}"    "${reset}${dim}"
    tui '%s ? %s about  '       "${bg_gray}${bwhite}${bold}"    "${reset}${dim}"
    tui '%s q %s quit'          "${bg_gray}${bwhite}${bold}"    "${reset}${dim}"
    tui '%s' "${reset}"

    # Search bar (if active)
    local header_end=3
    if [[ -n "$search_query" ]]; then
        move_to 3 1
        tui '  %s/%s %s%s%s' "${bblue}${bold}" "${reset}" "${bwhite}${bold}" "$search_query" "${reset}"
        header_end=4
        move_to 4 1
    else
        move_to 3 1
    fi

    # Separator
    local sep_len=$(( term_cols - 4 ))
    (( sep_len > 90 )) && sep_len=90
    tui '  %s%s%s' "${dim}${cyan}" "$(printf '%*s' "$sep_len" '' | tr ' ' '-')" "${reset}"

    # ── List area ──
    local list_start=$(( header_end + 1 ))

    if [[ "$display_mode" == "grid" ]]; then
        # ── GRID MODE ──
        local cell_width=24
        local cell_height=2
        local grid_cols=$(( (term_cols - 2) / cell_width ))
        (( grid_cols < 1 )) && grid_cols=1
        local grid_rows=$(( (term_lines - list_start - 2) / cell_height ))
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
                disp_title="${disp_title:0:$((max_title - 1))}\u2026"
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
                    disp_lang="${disp_lang:0:$((max_title - 1))}\u2026"
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
            (( bottom_row > term_lines - 1 )) && bottom_row=$(( term_lines - 1 ))
            move_to "$bottom_row" 3
            tui '%sv more below%s' "${byellow}${bold}" "${reset}"
        fi
    else
        # ── LIST MODES (compact / full) ──
        local row_height=3
        [[ "$display_mode" == "compact" ]] && row_height=1
        local max_items=$(( (term_lines - list_start - 2) / row_height ))
        (( max_items < 1 )) && max_items=1

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

            local row=$(( list_start + i * row_height ))

            # Source badge for non-local dirs
            local source_badge=""
            if [[ "$source" == "discovered" ]]; then
                source_badge="${dim}${bcyan} [claude]${reset}"
            elif [[ "$source" == "external" ]]; then
                source_badge="${dim}${bcyan} [added]${reset}"
            fi

            if [[ "$display_mode" == "compact" ]]; then
                # ── COMPACT MODE: single row per project ──
                move_to "$row" 1
                if (( fidx == selected )); then
                    tui '  %s>%s ' "${bgreen}${bold}" "${reset}"
                    tui '%s %s %s' "${bg_sel}${bwhite}${bold}" "$title" "${reset}"
                else
                    tui '  %s>%s ' "${dim}" "${reset}"
                    tui '%s%s%s' "${bold}${bwhite}" "$title" "${reset}"
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

        # Scroll indicators
        if (( scroll_offset > 0 )); then
            move_to $(( list_start - 1 )) 3
            tui '%s^ more above%s' "${byellow}${bold}" "${reset}"
        fi
        if (( scroll_offset + max_items < ${#filtered[@]} )); then
            local bottom_row=$(( list_start + max_items * row_height ))
            (( bottom_row > term_lines - 1 )) && bottom_row=$(( term_lines - 1 ))
            move_to "$bottom_row" 3
            tui '%sv more below%s' "${byellow}${bold}" "${reset}"
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
    local key
    IFS= read -rsn1 key < /dev/tty || return 1
    if [[ "$key" == $'\e' ]]; then
        local seq
        IFS= read -rsn2 -t 0.1 seq < /dev/tty || true
        key="${key}${seq}"
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

    local prompt_msg="Delete '$title' and all contents?"
    if [[ "$source" == "external" ]]; then
        prompt_msg="Remove '$title' from list? (files kept)"
    fi

    if confirm "$prompt_msg"; then
        if [[ "$source" == "external" ]]; then
            # Just remove from extra dirs file
            local dir="${dirs[$idx]}"
            if [[ -f "$EXTRA_DIRS_FILE" ]]; then
                local tmp
                tmp=$(grep -v "^${dir}$" "$EXTRA_DIRS_FILE" 2>/dev/null || true)
                printf '%s\n' "$tmp" > "$EXTRA_DIRS_FILE"
            fi
        else
            rm -rf "${dirs[$idx]}"
        fi
        load_dirs
        _apply_groups_to_cache
    _apply_demo_mode
        if (( selected >= ${#filtered[@]} )); then
            selected=$(( ${#filtered[@]} - 1 ))
            (( selected < 0 )) && selected=0
        fi
        if [[ "$source" == "external" ]]; then
            status_msg="Removed from list: $title"
        else
            status_msg="Deleted: $title"
        fi
        status_color="${bred}${bold}"
    else
        status_msg="Cancelled"
        status_color="$dim"
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
        date)     sort_mode="recent" ;;
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

    # Check if already tracked
    if [[ -f "$EXTRA_DIRS_FILE" ]] && grep -qx "$path" "$EXTRA_DIRS_FILE" 2>/dev/null; then
        status_msg="Already tracked: $path"
        status_color="${byellow}${bold}"
        return
    fi

    # Append to extra dirs file
    printf '%s\n' "$path" >> "$EXTRA_DIRS_FILE"
    load_dirs
    _apply_groups_to_cache
    _apply_demo_mode
    status_msg="Added: $path"
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
    tui '  %sVersion:%s  2.0.0' "${bold}${bwhite}" "${reset}"
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
            "date = modified  |  recent = last opened  |  name  |  language"
        (( row += (sel == 2 ? 3 : 2) ))

        # 3: Demo Mode
        local demo_desc="Anonymize all project names, paths & groups for screenshots"
        local demo_val_color=""
        [[ "$demo_mode" == "on" ]] && demo_val_color="${bg_magenta}${bwhite}${bold}"
        _draw_setting_row "$row" "$(( sel == 3 ))" "Demo Mode" "$demo_mode" \
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

        # 1: Auto-launch Claude
        _draw_setting_row "$row" "$(( sel == 1 ))" "Auto-launch Claude" "$auto_claude" \
            "on = run claude on open  |  off = just cd into directory"
        (( row += (sel == 1 ? 3 : 2) ))

        # 2: Match Threshold
        _draw_setting_row "$row" "$(( sel == 2 ))" "Quick-open Threshold" "${match_threshold}%" \
            "Minimum similarity % for instant open (0-100, higher = stricter)"
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
    [[ "$demo_mode" != "$_orig_demo_mode" ]] || \
    [[ "$match_threshold" != "$_orig_match_threshold" ]]
}

do_settings() {
    local settings_sel=0
    local settings_page=1
    local page1_count=4   # View Mode, Display Mode, Sort Mode, Demo Mode
    local page2_count=3   # Title Persistence, Auto-launch Claude, Match Threshold
    _settings_status=""
    _settings_status_color=""

    # Save originals for discard
    local _orig_view_mode="$view_mode"
    local _orig_display_mode="$display_mode"
    local _orig_sort_mode="$sort_mode"
    local _orig_title_mode="$title_mode"
    local _orig_auto_claude="$auto_claude"
    local _orig_demo_mode="$demo_mode"
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
                        2) sort_mode=$(_cycle_value "$sort_mode" 1 date recent name language) ;;
                        3) demo_mode=$(_cycle_value "$demo_mode" 1 off on) ;;
                    esac
                else
                    case "$settings_sel" in
                        0)
                            title_mode=$(_cycle_value "$title_mode" 1 none window_title tmux_split tmux_status scroll_region prompt)
                            if ! _has_tmux; then
                                case "$title_mode" in tmux_split|tmux_status) _install_tmux ;; esac
                            fi
                            ;;
                        1) auto_claude=$(_cycle_value "$auto_claude" 1 on off) ;;
                        2) (( match_threshold < 100 )) && (( match_threshold += 5 )) ;;
                    esac
                fi
                ;;
            $'\e[D'|h)
                _settings_status=""
                if (( settings_page == 1 )); then
                    case "$settings_sel" in
                        0) view_mode=$(_cycle_value "$view_mode" -1 local all) ;;
                        1) display_mode=$(_cycle_value "$display_mode" -1 compact full grid) ;;
                        2) sort_mode=$(_cycle_value "$sort_mode" -1 date recent name language) ;;
                        3) demo_mode=$(_cycle_value "$demo_mode" -1 off on) ;;
                    esac
                else
                    case "$settings_sel" in
                        0)
                            title_mode=$(_cycle_value "$title_mode" -1 none window_title tmux_split tmux_status scroll_region prompt)
                            if ! _has_tmux; then
                                case "$title_mode" in tmux_split|tmux_status) _install_tmux ;; esac
                            fi
                            ;;
                        1) auto_claude=$(_cycle_value "$auto_claude" -1 on off) ;;
                        2) (( match_threshold > 0 )) && (( match_threshold -= 5 )) ;;
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
                        demo_mode="$_orig_demo_mode"
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

    if (( best_score >= 95 && best_idx >= 0 )); then
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

main() {
    _start_spinner
    load_dirs
    _apply_groups_to_cache
    _apply_demo_mode
    _stop_spinner

    # Handle CLI argument: quick-open or pre-fill search
    if [[ -n "${1:-}" ]]; then
        if _try_quick_open "$1"; then
            # Skip TUI — write result and exit
            show_cursor
            local result_file="${CLAUDEMANAGER_RESULT:-}"
            if [[ -n "$result_file" ]]; then
                local idx="${filtered[$selected]}"
                printf '__CLAUDE_CD__:%s\n' "$open_dir" > "$result_file"
                [[ "$auto_claude" == "on" ]] && printf '__CLAUDE_RUN__\n' >> "$result_file"
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

    while true; do
        draw
        local key
        key=$(read_key) || { action="quit"; break; }

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
                fi
                ;;
            $'\e[C' | l)
                if [[ "$display_mode" == "grid" ]]; then
                    (( selected < ${#filtered[@]} - 1 )) && (( selected++ )) || true
                fi
                ;;
            $'\e[5~')     (( selected -= 5 )); (( selected < 0 )) && selected=0 ;;
            $'\e[6~')     (( selected += 5 )); (( selected >= ${#filtered[@]} )) && selected=$(( ${#filtered[@]} - 1 )); (( selected < 0 )) && selected=0 ;;
            "")           do_open ;;
            /)            do_search ;;
            $'\x1b')      if [[ -n "$search_query" ]]; then do_clear_search; else do_about; fi ;;
            n)            do_new ;;
            r)            do_rename ;;
            R)            do_smart_rename ;;
            m)            do_move_dir ;;
            e)            do_edit_desc ;;
            d)            do_delete ;;
            s)            do_shell ;;
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
                printf '__CLAUDE_CD__:%s\n' "$open_dir" > "$result_file"
                [[ "$auto_claude" == "on" ]] && printf '__CLAUDE_RUN__\n' >> "$result_file"
                printf '__CLAUDE_TITLE__:%s\n' "${cache_title[$idx]}" >> "$result_file"
                printf '__CLAUDE_TITLE_MODE__:%s\n' "$title_mode" >> "$result_file"
                ;;
            shell)
                printf '__CLAUDE_CD__:%s\n' "$open_dir" > "$result_file"
                ;;
            new)
                local new_dir="$CLAUDE_BASE/$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$new_dir"
                printf '__CLAUDE_CD__:%s\n' "$new_dir" > "$result_file"
                [[ "$auto_claude" == "on" ]] && printf '__CLAUDE_RUN__\n' >> "$result_file"
                printf '__CLAUDE_TITLE__:%s\n' "$(basename "$new_dir")" >> "$result_file"
                printf '__CLAUDE_TITLE_MODE__:%s\n' "$title_mode" >> "$result_file"
                ;;
            quit) ;;
        esac
    fi
}

main "$@"
