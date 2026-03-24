#!/usr/bin/env bash
# claudemanager installer
#
# Remote install (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/relipse/claudemanager/main/install.sh | bash
#
# Local install (after cloning):
#   git clone https://github.com/relipse/claudemanager.git
#   cd claudemanager && ./install.sh
#
# Installs claudemanager.sh and adds a shell wrapper function to your shell profile.

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/relipse/claudemanager/main"
INSTALL_DIR="${CLAUDE_BASE:-$HOME/util/claude}"

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
    printf '\n%s  C L A U D E   M A N A G E R   I N S T A L L E R%s\n\n' "${bold}${cyan}" "${reset}"

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

    # 3. Add shell wrapper function
    local profile
    profile=$(detect_profile)

    if grep -q 'claudemanager()' "$profile" 2>/dev/null; then
        ok "Shell function already in $profile"
    else
        info "Adding shell function to $profile"
        cat >> "$profile" << 'WRAPPER'

# ── claudemanager ─────────────────────────────────────────────────
# TUI for managing Claude Code project directories.
# Opens a project picker; selecting a project cd's into it and optionally runs claude.
claudemanager() {
    local tmpfile
    tmpfile=$(mktemp /tmp/claudemanager.XXXXXX)
    CLAUDEMANAGER_RESULT="$tmpfile" "${CLAUDE_BASE:-$HOME/util/claude}/claudemanager.sh"
    local dir="" run_claude=false
    if [[ -f "$tmpfile" ]]; then
        while IFS= read -r line; do
            case "$line" in
                __CLAUDE_CD__:*)
                    dir="${line#__CLAUDE_CD__:}"
                    ;;
                __CLAUDE_RUN__)
                    run_claude=true
                    ;;
            esac
        done < "$tmpfile"
        rm -f "$tmpfile"
    fi
    if [[ -n "$dir" ]]; then
        cd "$dir" || return 1
        if $run_claude; then
            claude
        fi
    fi
}
WRAPPER
        ok "Added claudemanager() to $profile"
    fi

    # 4. Set CLAUDE_BASE if non-default
    if [[ "$INSTALL_DIR" != "$HOME/util/claude" ]]; then
        if ! grep -q 'export CLAUDE_BASE=' "$profile" 2>/dev/null; then
            printf '\nexport CLAUDE_BASE="%s"\n' "$INSTALL_DIR" >> "$profile"
            ok "Set CLAUDE_BASE=$INSTALL_DIR in $profile"
        fi
    fi

    printf '\n%s  Done!%s\n' "${bold}${green}" "${reset}"
    printf '  Restart your shell or run: %ssource %s%s\n' "${dim}" "$profile" "${reset}"
    printf '  Then type: %sclaudemanager%s\n\n' "${bold}" "${reset}"
}

main "$@"
