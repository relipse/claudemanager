#!/usr/bin/env bash
# claudemanager - Colorful TUI for managing Claude project directories
# Copyright (C) 2026 Kinsman Software LLC. All rights reserved.
# All TUI I/O goes through /dev/tty so the wrapper function can capture stdout signals.

set -uo pipefail

CLAUDE_BASE="${CLAUDE_BASE:-$HOME/.claudemanager}"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
EXTRA_DIRS_FILE="$CLAUDE_BASE/.claudemanager_dirs"

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
    if [[ "$sort_mode" == "date" ]]; then
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
    local -a new_source=() new_fullpath=()
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
}

# ── Load & cache a single directory ──────────────────────────────
_cache_one_dir() {
    local d="$1" source="$2"
    dirs+=("$d")
    cache_base+=("$(basename "$d")")
    cache_title+=("$(_compute_title "$d")")
    cache_date+=("$(_compute_date "$d")")
    cache_reldate+=("$(_compute_reldate "$d")")
    cache_desc+=("$(_compute_desc "$d")")
    cache_files+=("$(_compute_filecount "$d")")
    cache_source+=("$source")
    cache_fullpath+=("$d")

    _lang_name="" _lang_color="" _framework=""
    _compute_language "$d"
    cache_lang+=("$_lang_name")
    cache_langcolor+=("$_lang_color")
    cache_framework+=("$_framework")
}

# ── Load & cache everything ───────────────────────────────────────
load_dirs() {
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

    # Collect all directories to scan
    local tmp_dirs=()
    local tmp_sources=()

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

    # 2. If "all" view, discover from ~/.claude/projects
    if [[ "$view_mode" == "all" ]] && [[ -d "$CLAUDE_PROJECTS_DIR" ]]; then
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

    clear_screen
    move_to 1 1
    tui '%s  Loading %d projects...%s' "${bold}${cyan}" "${#tmp_dirs[@]}" "${reset}"

    local idx=0
    for (( idx = 0; idx < ${#tmp_dirs[@]}; idx++ )); do
        local d="${tmp_dirs[$idx]}"
        local src="${tmp_sources[$idx]}"

        _cache_one_dir "$d" "$src"

        move_to 2 1
        clear_line
        tui '  %s[%d/%d]%s %s' "${dim}" "$(( idx + 1 ))" "${#tmp_dirs[@]}" "${reset}" "${cache_title[-1]}"
    done

    sort_dirs
    apply_filter
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
    tui '%s d %s del  '         "${bg_red}${white}${bold}"      "${reset}${dim}"
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
}

do_toggle_sort() {
    case "$sort_mode" in
        date)     sort_mode="name" ;;
        name)     sort_mode="language" ;;
        language) sort_mode="date" ;;
    esac
    sort_dirs
    apply_filter
    selected=0
    scroll_offset=0
    status_msg="Sort: $sort_mode"
    status_color="${byellow}${bold}"
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
    tui '  %sVersion:%s  1.2.0' "${bold}${bwhite}" "${reset}"
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
    move_to "$row" 1; tui '    %sd%s      delete project              %s?%s  this screen' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"
    (( row += 1 ))
    move_to "$row" 1; tui '    %sj/k%s    navigate up/down            %sq%s  quit' "${bwhite}${bold}" "${reset}" "${bwhite}${bold}" "${reset}"

    move_to "$term_lines" 1
    tui '  %sPress any key to return...%s' "${dim}" "${reset}"
    read_key > /dev/null
}

do_new()   { action="new"; }
do_open()  {
    (( ${#filtered[@]} == 0 )) && return
    local idx="${filtered[$selected]}"
    open_dir="${dirs[$idx]}"
    action="open"
}
do_shell() {
    (( ${#filtered[@]} == 0 )) && return
    local idx="${filtered[$selected]}"
    open_dir="${dirs[$idx]}"
    action="shell"
}

# ── Main ──────────────────────────────────────────────────────────
cleanup() {
    show_cursor
    clear_screen
    stty sane 2>/dev/null || true
}
trap cleanup EXIT

main() {
    load_dirs
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
            $'\x1b')      if [[ -n "$search_query" ]]; then do_clear_search; else action="quit"; fi ;;
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
            ?)            do_about ;;
            q)            action="quit" ;;
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
                printf '__CLAUDE_CD__:%s\n' "$open_dir" > "$result_file"
                printf '__CLAUDE_RUN__\n' >> "$result_file"
                ;;
            shell)
                printf '__CLAUDE_CD__:%s\n' "$open_dir" > "$result_file"
                ;;
            new)
                local new_dir="$CLAUDE_BASE/$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$new_dir"
                printf '__CLAUDE_CD__:%s\n' "$new_dir" > "$result_file"
                printf '__CLAUDE_RUN__\n' >> "$result_file"
                ;;
            quit) ;;
        esac
    fi
}

main
