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
- **Group mode** — browse your groups as folders (press `b`); open a folder to see just that group's projects
- **Auto-group detection** — automatically suggests groups based on similar project names
- **Token usage stats** — view input, output, and cache token usage per project and per group
- **GitHub integration** — connect your GitHub account (via the `gh` CLI), browse your repos, and open / clone / assign a local directory for each. Press `o` to switch to any organization you belong to.
- **Multiple clones per repo** — press `C` in the GitHub view to spin up extra numbered clones (`repo-2`, `repo-3`, …) so you can run several AI agents on the same project in parallel. Repos with more than one clone show a clone count, and `enter` lets you pick which clone to open. When a local copy already exists, the extra clone is made **from that local copy** (`git clone` of the on-disk repo — fast and offline) instead of re-downloading from GitHub.
- **Local project clone** — press `C` on any local git project to clone it into a numbered sibling, copying only git-tracked content (like `cp -r` but skipping `node_modules`, build output, and other untracked files). Same parallel-agent workflow, no GitHub required.
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
| `C` | Clone project (git-tracked files only) into a numbered sibling |
| `m` | Rename directory |
| `e` | Edit description |
| `d` | Delete project |
| `a` | Add external directory |

### Views & Sorting

| Key | Action |
|-----|--------|
| `p` | Toggle local / all projects view |
| `t` | Cycle sort mode (date, name, language) |
| `c` | Cycle view mode (compact, full, grid, groups) |
| `f` | Force refresh cache |

### Groups & Stats

| Key | Action |
|-----|--------|
| `g` | Assign project to a group/client |
| `G` | Group management screen |
| `b` | Group mode — show groups as folders, open one to see its projects |
| `#` | Auto-detect groups from similar project names |
| `H` | GitHub repos — browse / clone / assign / open repos (press `o` to pick another org) |
| `S` | Project stats (4 pages: overview, tokens, languages, group billing) |

### Other

| Key | Action |
|-----|--------|
| `,` | Settings |
| `u` | Check for updates / view what's new / install |
| `?` | About / help |

## Updates

claudemanager can keep itself current from the public GitHub repo:

- Press `u` anytime to check GitHub, see a **What's new** list of changes since your installed version, and install with one confirmation.
- **Settings → page 2**:
  - **Auto-update Check** — how often to check GitHub in the background (off / daily / every 3, 7, 14, 30 days).
  - **Auto-install Updates** — when `on`, a found update is shown (with its changelog) and installed automatically at startup; when `off`, you're just notified and can press `u`.

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

## GitHub Integration

Press `H` to open the GitHub repos screen. It connects to your GitHub account through the [`gh` CLI](https://cli.github.com) — auth is handled by `gh` (keyring/token), so claudemanager never stores credentials. If you aren't logged in, it offers to run `gh auth login` for you.

The screen lists your repositories (private/public badge, language, last-updated date, description) and shows which are already cloned locally — detected from the git remotes of your tracked projects, plus any manual assignments.

| Key | Action |
|-----|--------|
| `enter` | Open the repo in Claude Code (clones first if needed) |
| `s` | Open a shell in the repo directory (clones first if needed) |
| `c` | Clone the repo (prompts for destination; remembers your last clone dir) |
| `a` | Assign an existing local directory to this repo |
| `w` | Open the repo's GitHub page in your browser |
| `/` | Filter repos by name/description/language |
| `r` | Refresh the repo list |
| `o` | List a different owner's / org's repos |
| `q` / `esc` | Back |

Clones default to `~/github/<repo>` (configurable per-clone; the last destination becomes the new default). Manual directory assignments are persisted in `~/.claudemanager/.claudemanager_gh`. Cloned and assigned repos are automatically added to claudemanager's project list.

Requires the `gh` CLI (`brew install gh` on macOS).

## Requirements

- Bash 4+ or Zsh
- A terminal with ANSI color support (256-color recommended)
- macOS or Linux
- Claude Code CLI (optional, for launching projects)
- GitHub CLI `gh` (optional, for the GitHub integration screen)

## License

MIT
