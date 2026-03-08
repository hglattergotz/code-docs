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
3. Install Docker Desktop (pandoc and other dependencies are bundled in the container)
4. Optionally create a symlink for convenience: `ln -s /path/to/code-docs ~/bin/code-docs`

## Usage

### Entry-Point Script

`code-docs.sh` is the main entry-point for setup and watcher management:

```bash
./code-docs.sh setup              # Interactive .env configuration wizard
./code-docs.sh up                 # Start the Docker container (auto-runs setup if no .env)
./code-docs.sh up --clean         # Clean output files, then start the Docker container
./code-docs.sh down               # Stop the Docker container
./code-docs.sh status             # Show container state and configuration
./code-docs.sh logs               # Follow container logs (Ctrl+C to stop)
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

The watcher runs in a **Docker container** alongside a built-in HTTP server. Use `code-docs.sh` to manage it:

```bash
./code-docs.sh up       # Start the container (builds docs + starts watcher + HTTP server)
./code-docs.sh down     # Stop the container
./code-docs.sh status   # Check if it's running
./code-docs.sh logs     # Follow live log output (Ctrl+C to detach)
```

The container includes everything needed (pandoc, Python HTTP server, file watcher). Source files are bind-mounted read-only; HTML output is written to a separate bind-mounted volume.

Open `http://localhost:8000` (or the port configured via `HTTP_PORT` in `.env`) to browse your docs. You get:
- Direct doc URLs like `http://localhost:8000/project/README.html`
- Browser refresh works (no iframe context loss)
- Bookmarkable and shareable links

> **Note:** The watcher uses polling (every 15s by default, configurable via `POLL_INTERVAL`) instead of inotify because Docker Desktop for macOS does not reliably propagate inotify events through bind-mounted volumes.

## How It Works

### Scanning

The build system recursively scans `$CODE_DIR` for all `.md` files at any depth under each project directory (e.g., `$CODE_DIR/project/README.md`, `$CODE_DIR/project/docs/api/reference.md`). There is no depth limit — every `.md` file is discovered automatically.

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

### Excluding Projects

To exclude entire projects from the generated docs, set `EXCLUDE_PROJECTS` in `.env` to a space-separated list of directory names:

```bash
EXCLUDE_PROJECTS="archived-project fork-of-something"
```

Excluded projects are filtered out of `find_md_files`, skipped in `--file` single-file builds, and ignored by the fswatch watcher. This is useful for forks, archived repos, or projects with sensitive content.

### Sidebar Display Style

The sidebar can render project documents in two modes, controlled by `SIDEBAR_STYLE` in `.env`:

- **`tree`** (default): Nested expandable folders that mirror the directory structure. Each folder shows a file count and can be toggled open/closed. Clicking a hash link auto-expands parent folders.
- **`flat`**: File paths shown as flat links under each project (e.g., `docs/api/reference.html`). This was the original behavior before recursive scanning was added.

```bash
# In .env
SIDEBAR_STYLE="tree"   # nested folders (default)
SIDEBAR_STYLE="flat"   # flat file paths
```

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

`watch-docs.sh` polls `$CODE_DIR` every `POLL_INTERVAL` seconds (default: 15) and calls `build-docs.sh --update`. The `--update` mode diffs the current set of `.md` files and their mtimes against a saved state file (`_state.tsv`) and rebuilds only what changed:

- **New files** — built and added to the index
- **Modified files** — rebuilt (mtime changed since last poll)
- **Deleted files** — corresponding HTML removed

Polling was chosen over event-based watchers (inotifywait, fswatch) because Docker Desktop for macOS does not reliably deliver inotify events through bind-mounted host volumes.

## Dependencies

All dependencies are bundled in the Docker image. For native/manual use:

- **pandoc** — Markdown to HTML conversion
- **fswatch** — File system change monitoring (macOS; `brew install pandoc fswatch`)
