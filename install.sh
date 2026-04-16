#!/usr/bin/env bash
# claudemanager installer — Kinsman Software LLC
#
# Remote install (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/relipse/claudemanager/main/install.sh | bash
#
# Local install (after cloning):
#   git clone https://github.com/relipse/claudemanager.git
#   cd claudemanager && ./install.sh
#
# Custom project directory:
#   CLAUDE_BASE=~/my-claude-projects ./install.sh
#
# Installs claudemanager.sh and adds a shell wrapper function to your shell profile.

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/relipse/claudemanager/main"

# Where to install the script itself
INSTALL_DIR="${CLAUDEMANAGER_HOME:-$HOME/.claudemanager}"

# Where Claude projects live (user-configurable, defaults to install dir)
CLAUDE_BASE="${CLAUDE_BASE:-$INSTALL_DIR}"

# Detect if running locally (install.sh is next to claudemanager.sh)
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" != "bash" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
LOCAL_MODE=false
if [[ -n "$SCRIPT_DIR" ]] && [[ -f "$SCRIPT_DIR/claudemanager.sh" ]]; then
    LOCAL_MODE=true
fi

# ── Colors ────────────────────────────────────────────────────────
green=$'\e[32m'
yellow=$'\e[33m'
cyan=$'\e[36m'
bold=$'\e[1m'
dim=$'\e[2m'
reset=$'\e[0m'

info()  { printf '%s[info]%s  %s\n' "${cyan}${bold}" "${reset}" "$*"; }
ok()    { printf '%s[ok]%s    %s\n' "${green}${bold}" "${reset}" "$*"; }
warn()  { printf '%s[warn]%s  %s\n' "${yellow}${bold}" "${reset}" "$*"; }

# ── Detect shell profile ─────────────────────────────────────────
detect_profile() {
    local shell_name
    shell_name=$(basename "${SHELL:-bash}")
    case "$shell_name" in
        zsh)
            if [[ -f "$HOME/.zshrc" ]]; then
                echo "$HOME/.zshrc"
            else
                echo "$HOME/.zprofile"
            fi
            ;;
        bash)
            if [[ -f "$HOME/.bashrc" ]]; then
                echo "$HOME/.bashrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.profile"
            fi
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# ── Main ──────────────────────────────────────────────────────────
main() {
    printf '\n%s  C L A U D E   M A N A G E R   I N S T A L L E R%s\n' "${bold}${cyan}" "${reset}"
    printf '  %sKinsman Software LLC%s\n\n' "${dim}" "${reset}"

    # 1. Create install directory
    if [[ ! -d "$INSTALL_DIR" ]]; then
        info "Creating directory: $INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
    fi
    ok "Install directory: $INSTALL_DIR"

    # 2. Get claudemanager.sh (local copy or remote download)
    local target="$INSTALL_DIR/claudemanager.sh"
    if $LOCAL_MODE; then
        info "Installing from local copy ..."
        cp "$SCRIPT_DIR/claudemanager.sh" "$target"
    else
        info "Downloading claudemanager.sh ..."
        if command -v curl &>/dev/null; then
            curl -fsSL "$REPO_URL/claudemanager.sh" -o "$target"
        elif command -v wget &>/dev/null; then
            wget -qO "$target" "$REPO_URL/claudemanager.sh"
        else
            printf '%s[error]%s  curl or wget is required\n' "${yellow}${bold}" "${reset}"
            exit 1
        fi
    fi
    chmod +x "$target"
    ok "Installed claudemanager.sh"

    # 3. Detect Claude projects from ~/.claude/projects history
    local claude_projects_dir="$HOME/.claude/projects"
    if [[ -d "$claude_projects_dir" ]]; then
        local project_count
        project_count=$(find "$claude_projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        ok "Found $project_count projects in Claude history (~/.claude/projects)"
        info "Use 'p' key in claudemanager to browse all discovered projects"
    else
        warn "No Claude project history found yet (~/.claude/projects)"
        info "Projects will appear after you use Claude Code in a directory"
    fi

    # 4. Add shell wrapper function
    local profile
    profile=$(detect_profile)

    # Remove old wrapper(s) if present (handles both marked and unmarked installs)
    if grep -q 'claudemanager()' "$profile" 2>/dev/null || \
       grep -q '_cm_launch_claude()' "$profile" 2>/dev/null; then
        ok "Shell function already in $profile (updating)"
        # Remove marked blocks (new-style: start marker to end marker)
        sed -i.bak '/# ── claudemanager ──/,/# ── \/claudemanager ──/d' "$profile"
        rm -f "${profile}.bak"
        # Remove any remaining unmarked _cm_launch_claude() or claudemanager() functions
        # (from manual installs or older versions)
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

    info "Adding shell function to $profile"
    cat >> "$profile" << WRAPPER

# ── claudemanager ─────────────────────────────────────────────────
# TUI for managing Claude Code project directories.
# Opens a project picker; selecting a project cd's into it and optionally runs claude.
_cm_launch_claude() {
    local title="\$1" mode="\$2" agent_cmd="\${3:-claude}"

    # Guard: verify agent is installed before any terminal manipulation
    if ! command -v "\$agent_cmd" &>/dev/null; then
        printf '\\n\\e[31m[error]\\e[0m  Agent not found: %s\\n' "\$agent_cmd"
        local _hint
        case "\$agent_cmd" in
            claude)       _hint="npm install -g @anthropic-ai/claude-code" ;;
            opencode)     _hint="curl -fsSL https://opencode.ai/install | sh" ;;
            copilot)      _hint="gh extension install github/gh-copilot" ;;
            amp)          _hint="curl -fsSL https://ampcode.com/install | sh" ;;
            cursor-agent) _hint="Install Cursor IDE from cursor.com" ;;
            aider)        _hint="pipx install aider-chat" ;;
            gemini)       _hint="npm install -g @google/gemini-cli" ;;
            codex)        _hint="npm install -g @openai/codex" ;;
            *)            _hint="see the project documentation" ;;
        esac
        printf '       Install:  %s\\n\\n' "\$_hint"
        printf 'Press any key to continue... '
        IFS= read -rsn1
        printf '\\n'
        return 1
    fi

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
                # If already in tmux, allow nesting
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
                # Not in tmux, window/tab title already set above
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
            # window/tab title already set above, just run claude
            \$agent_cmd
            ;;
    esac

    # Restore original terminal title on exit
    if [[ -n "\$title" ]]; then
        printf '\\e]0;%s\\a' "\${TERM_PROGRAM:-Terminal}"
    fi
}
claudemanager() {
    # Pass subcommands (--install, --refresh, etc.) directly — no tmpfile needed
    case "\${1:-}" in
        --install|--refresh)
            "${INSTALL_DIR}/claudemanager.sh" "\$@"
            return
            ;;
    esac
    local tmpfile
    tmpfile=\$(mktemp /tmp/claudemanager.XXXXXX)
    CLAUDEMANAGER_RESULT="\$tmpfile" "${INSTALL_DIR}/claudemanager.sh" "\$@"
    local dir="" run_claude=false title="" title_mode="none" agent_cmd="claude"
    if [[ -f "\$tmpfile" ]]; then
        while IFS= read -r line; do
            case "\$line" in
                __CLAUDE_CD__:*)
                    dir="\${line#__CLAUDE_CD__:}"
                    ;;
                __CLAUDE_RUN__)
                    run_claude=true
                    ;;
                __CLAUDE_TITLE__:*)
                    title="\${line#__CLAUDE_TITLE__:}"
                    ;;
                __AGENT_CMD__:*)
                    agent_cmd="\${line#__AGENT_CMD__:}"
                    ;;
                __CLAUDE_TITLE_MODE__:*)
                    title_mode="\${line#__CLAUDE_TITLE_MODE__:}"
                    ;;
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
    ok "Added claudemanager() to $profile"

    # 5. Set CLAUDE_BASE in profile if it differs from install dir
    if [[ "$CLAUDE_BASE" != "$INSTALL_DIR" ]]; then
        if ! grep -q 'export CLAUDE_BASE=' "$profile" 2>/dev/null; then
            printf '\nexport CLAUDE_BASE="%s"\n' "$CLAUDE_BASE" >> "$profile"
            ok "Set CLAUDE_BASE=$CLAUDE_BASE in $profile"
        fi
    fi

    printf '\n%s  Done!%s\n' "${bold}${green}" "${reset}"
    printf '  Restart your shell or run: %ssource %s%s\n' "${dim}" "$profile" "${reset}"
    printf '  Then type: %sclaudemanager%s\n\n' "${bold}" "${reset}"
}

main "$@"
