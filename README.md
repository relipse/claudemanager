# Claude Manager

A colorful terminal UI (TUI) for managing Claude Code project directories. Navigate, search, group, and launch projects from one place — with built-in token usage analytics.

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
- **Project grouping / client billing** — organize projects into groups for tracking
- **Auto-group detection** — automatically suggests groups based on similar project names
- **Token usage stats** — view input, output, and cache token usage per project and per group
- **Smart project names** — ambiguous names like `pub` or `util` show parent directory context
- Configurable title bar modes (window title, tmux split, tmux status, scroll region)

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

You can also pass a search query to quickly open a matching project:

```bash
claudemanager myproject
```

## Keybindings

### Navigation

| Key | Action |
|-----|--------|
| `j` / `k` / arrows | Navigate up/down |
| `h` / `l` / arrows | Navigate left/right (grid mode) |
| `enter` | Open project in Claude Code |
| `s` | Open shell in project directory |
| `/` | Search / filter projects |
| `q` | Quit |

### Project Management

| Key | Action |
|-----|--------|
| `n` | Create new project |
| `r` | Set display title |
| `R` | Smart rename directory |
| `m` | Rename directory |
| `e` | Edit description |
| `d` | Delete project |
| `a` | Add external directory |

### Views & Sorting

| Key | Action |
|-----|--------|
| `p` | Toggle local / all projects view |
| `t` | Cycle sort mode (date, name, language) |
| `c` | Cycle view mode (compact, full, grid) |
| `f` | Force refresh cache |

### Groups & Stats

| Key | Action |
|-----|--------|
| `g` | Assign project to a group/client |
| `G` | Group management screen |
| `#` | Auto-detect groups from similar project names |
| `S` | Project stats (4 pages: overview, tokens, languages, group billing) |

### Other

| Key | Action |
|-----|--------|
| `,` | Settings |
| `?` | About / help |

## Stats Pages

Press `S` to open the stats dashboard with 4 pages (navigate with arrow keys):

1. **Overview** — total projects, sessions, source breakdown, aggregate token usage, activity, disk usage
2. **Top Projects by Tokens** — ranked table of all projects by input/output/cache token usage
3. **Projects by Language** — bar chart with project names listed under each language
4. **Group Billing** — token usage aggregated per group/client, with member project names

## Project Grouping

Organize projects into named groups for client billing or categorization:

- Press `g` on any project to assign it to a group
- Press `#` to auto-detect groups based on similar project names (review & confirm)
- Press `G` to manage groups (rename, delete, add/remove members)
- View per-group token usage on stats page 4

Groups are persisted in `~/.claudemanager/.claudemanager_groups`.

## Requirements

- Bash 4+ or Zsh
- A terminal with ANSI color support (256-color recommended)
- macOS or Linux
- Claude Code CLI (optional, for launching projects)

## License

MIT
