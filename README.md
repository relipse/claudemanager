# Claude Manager

A terminal UI (TUI) for managing Claude Code project directories. Navigate, search, rename, and launch projects from one place.

Built with pure Bash — no dependencies beyond a standard Unix terminal.

**Kinsman Software LLC** | [kinsman.cc](https://kinsman.cc)

## Features

- Browse local project directories and all Claude Code project history
- Three view modes: compact, full, and grid
- Fuzzy search/filter across projects
- Sort by date, name, or language
- Create new projects, rename, add descriptions
- Launch Claude Code or a shell directly from the picker
- Add external directories from anywhere on your system
- Auto-detects project language (Swift, Python, JS, Go, Rust, PHP, etc.)

## Install

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/relipse/claudemanager/main/install.sh | bash
```

### Clone and install locally

```bash
git clone https://github.com/relipse/claudemanager.git
cd claudemanager
./install.sh
```

### Custom project directory

By default, claudemanager discovers projects from your Claude Code history (`~/.claude/projects`). To also set a base directory for local projects:

```bash
CLAUDE_BASE=~/my-projects ./install.sh
```

## Usage

After installing, restart your shell (or `source ~/.bashrc` / `source ~/.zshrc`), then:

```bash
claudemanager
```

## Keybindings

| Key | Action |
|-----|--------|
| `enter` | Open project in Claude Code |
| `s` | Open shell in project directory |
| `/` | Search / filter projects |
| `n` | Create new project |
| `p` | Toggle local / all projects view |
| `t` | Cycle sort mode (date, name, language) |
| `c` | Cycle view mode (compact, full, grid) |
| `a` | Add external directory |
| `r` | Set display title |
| `R` | Smart rename directory |
| `m` | Rename directory |
| `e` | Edit description |
| `d` | Delete project |
| `?` | About |
| `q` | Quit |

## Requirements

- Bash 4+ or Zsh
- A terminal with ANSI color support
- Claude Code CLI (for launching projects)

## License

MIT
