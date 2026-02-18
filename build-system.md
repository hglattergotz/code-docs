# Code Docs Build System

A shell-based build system that converts Markdown files from source code projects into a browsable HTML documentation site. Paths are configured in `.env` (see `.env.example`).

## File Locations

| What | Path |
|------|------|
| Project repo | `code-docs/` (wherever cloned) |
| Entry-point | `code-docs/code-docs.sh` |
| Build script | `code-docs/build-docs.sh` |
| File watcher | `code-docs/watch-docs.sh` |
| Pandoc style | `code-docs/style.html` |
| Config template | `code-docs/.env.example` |
| Local config | `code-docs/.env` (gitignored) |
| This file | `code-docs/build-system.md` |
| Source docs | `$CODE_DIR` (configured in `.env`) |
| HTML output | `$OUTPUT_DIR` (configured in `.env`) |
| Dashboard | `$OUTPUT_DIR/dashboard.html` |
| Index | `$OUTPUT_DIR/index.html` |

## Setup

1. Clone the repo
2. Run `./code-docs.sh setup` (interactive wizard that creates `.env`)
3. Install dependencies: `brew install pandoc fswatch tmux` (or equivalent)
4. Optionally create a symlink for convenience: `ln -s /path/to/code-docs ~/bin/code-docs`

## Usage

### Entry-Point Script

`code-docs.sh` is the main entry-point for setup and watcher management:

```bash
./code-docs.sh setup              # Interactive .env configuration wizard
./code-docs.sh up                 # Start the file watcher (auto-runs setup if no .env)
./code-docs.sh up --build         # Full build, then start watcher
./code-docs.sh up --clean         # Clean build, then start watcher
./code-docs.sh up --serve         # Start watcher + HTTP server on localhost:8000
./code-docs.sh up --serve --build # Build then serve over HTTP
./code-docs.sh down               # Stop the file watcher (and server if running)
./code-docs.sh status             # Show watcher state and configuration
./code-docs.sh help               # Show usage info
```

### Manual Builds

The build script can also be invoked directly:

```bash
./build-docs.sh                              # Full rebuild of all docs + index
./build-docs.sh --file $CODE_DIR/project/README.md  # Rebuild a single file + index
./build-docs.sh --clean                      # Clean everything and do a full rebuild
```

### Running the File Watcher

The watcher runs in a **tmux session** so it persists across terminal sessions. Use `code-docs.sh` to manage it:

```bash
./code-docs.sh up       # Start the watcher
./code-docs.sh down     # Stop the watcher
./code-docs.sh status   # Check if it's running

# Attach to the tmux session to see live output (detach with Ctrl-b d)
tmux attach -t code-docs
```

> **Note:** A LaunchAgent (`com.user.code-docs-watcher.plist`) was previously used but abandoned because macOS Full Disk Access restrictions prevent launchd-spawned processes from accessing `~/Documents/`. Running the watcher from a terminal (via tmux) inherits the terminal's FDA permissions and works reliably.

### Local Web Server

For a better browsing experience with direct URLs and browser refresh support:

```bash
./code-docs.sh up --serve         # Start watcher + server
```

This starts a Python HTTP server at `http://localhost:8000` alongside the file watcher. You get:
- Direct doc URLs like `http://localhost:8000/project/README.html`
- Browser refresh works (no iframe context loss)
- Bookmarkable and shareable links
- Standard browser navigation (back/forward buttons)

The watcher and server both run in the same tmux session. Use `./code-docs.sh down` to stop both.

> **Note:** Without `--serve`, docs open as `file:///` URLs with iframe-based navigation in index.html. With `--serve`, each doc is accessible at its own HTTP URL.

## How It Works

### Scanning

The build system scans `$CODE_DIR` for `.md` files in two ways:

1. **Root-level**: `.md` files at the top of each project directory (depth 2, e.g., `$CODE_DIR/project/README.md`)
2. **Doc directories**: `.md` files at any depth inside directories named `docs`, `docks`, or `doc`

### Excluded Directories

The following directories are always skipped:

- `node_modules`
- `.git`
- `vendor`
- `__pycache__`
- `.venv`
- `.next`
- `dist`
- `.cache`
- `.terraform`

### Incremental Builds

Each `.md` file is only rebuilt if the HTML output is missing or older than the source file or the style template. This makes repeated builds fast.

### Conversion

Each Markdown file is converted to a standalone HTML page using **pandoc** with:

- The shared `style.html` template for consistent styling
- The first `# heading` as the page title (falls back to filename)
- Output placed in `$OUTPUT_DIR` mirroring the source directory structure

### Index Generation

After building individual pages, an `index.html` is generated with:

- A sidebar listing all projects and their documents
- A search box to filter projects
- An iframe that loads documents when clicked
- A dashboard as the default view

### Dashboard

A `dashboard.html` is generated with metadata about all documented projects:

- Summary statistics (projects, documents, total words)
- Recently modified documents
- Projects sorted by activity with staleness indicators
- Document freshness distribution

### File Watcher

`watch-docs.sh` uses `fswatch` to monitor `$CODE_DIR` for changes. It classifies events into three categories:

- **Markdown files** (`.md`) — incremental rebuild of the changed file
- **Directories or deleted paths** — full rebuild with orphan cleanup (debounced to max once per 10 seconds)
- **Other files** — ignored silently

## Dependencies

- **pandoc** — Markdown to HTML conversion
- **fswatch** — File system change monitoring (for `watch-docs.sh`)
- Both available via Homebrew (`brew install pandoc fswatch`); path configured via `EXTRA_PATH` in `.env`
