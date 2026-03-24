#!/usr/bin/env bash
# claudemanager installer
# Installs claudemanager.sh and adds a shell wrapper function to your shell profile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${CLAUDE_BASE:-$HOME/util/claude}"

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

    # 2. Copy script
    local target="$INSTALL_DIR/claudemanager.sh"
    cp "$SCRIPT_DIR/claudemanager.sh" "$target"
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
