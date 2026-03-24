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

    # Remove old wrapper if present (to update with new paths)
    if grep -q 'claudemanager()' "$profile" 2>/dev/null; then
        ok "Shell function already in $profile (updating)"
        # Remove the old block
        sed -i.bak '/# ── claudemanager ──/,/^}/d' "$profile"
        rm -f "${profile}.bak"
    fi

    info "Adding shell function to $profile"
    cat >> "$profile" << WRAPPER

# ── claudemanager ─────────────────────────────────────────────────
# TUI for managing Claude Code project directories.
# Opens a project picker; selecting a project cd's into it and optionally runs claude.
claudemanager() {
    local tmpfile
    tmpfile=\$(mktemp /tmp/claudemanager.XXXXXX)
    CLAUDEMANAGER_RESULT="\$tmpfile" "${INSTALL_DIR}/claudemanager.sh"
    local dir="" run_claude=false
    if [[ -f "\$tmpfile" ]]; then
        while IFS= read -r line; do
            case "\$line" in
                __CLAUDE_CD__:*)
                    dir="\${line#__CLAUDE_CD__:}"
                    ;;
                __CLAUDE_RUN__)
                    run_claude=true
                    ;;
            esac
        done < "\$tmpfile"
        rm -f "\$tmpfile"
    fi
    if [[ -n "\$dir" ]]; then
        cd "\$dir" || return 1
        if \$run_claude; then
            claude
        fi
    fi
}
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
