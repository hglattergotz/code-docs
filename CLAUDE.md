# Code Docs

Shell-based build system that converts Markdown files from source code projects into browsable HTML documentation. Paths are configured in `.env` (see `.env.example`).

## File Layout

| File | Purpose |
|------|---------|
| `code-docs.sh` | Entry-point script — setup wizard, watcher lifecycle (up/down/status) |
| `.env.example` | Configuration template — copy to `.env` and adjust for your system |
| `.env` | Local configuration (gitignored) — sets `CODE_DIR`, `OUTPUT_DIR`, `EXTRA_PATH` |
| `build-docs.sh` | Main build script — scans for `.md` files, converts to HTML via pandoc, generates index and dashboard |
| `watch-docs.sh` | File watcher — runs initial build, then uses fswatch to rebuild on `.md` changes; manages heartbeat |
| `style.html` | Pandoc HTML template included in every generated page for consistent styling |
| `build-system.md` | Project documentation (this file becomes part of the generated docs) |

## Commands

```bash
# First-time setup (interactive)
./code-docs.sh setup

# Start the file watcher
./code-docs.sh up

# Stop the file watcher
./code-docs.sh down

# Check watcher status
./code-docs.sh status

# Manual builds (also available directly)
./build-docs.sh
./build-docs.sh --file $CODE_DIR/project/README.md
./build-docs.sh --clean
```

## Architecture

- **Scanning**: Finds `.md` files at project root level (depth 2) and inside `docs/`, `docks/`, `doc/` directories. Excludes `node_modules`, `.git`, `vendor`, `__pycache__`, `.venv`, `.next`, `dist`, `.cache`, `.terraform`.
- **Incremental builds**: Only rebuilds when HTML output is missing or older than the source `.md` or `style.html`.
- **Conversion**: Uses pandoc with `style.html` template. Extracts first `# heading` as page title.
- **Index generation**: Creates `index.html` with sidebar navigation, project search, and iframe-based document viewer.
- **Dashboard**: Generates `dashboard.html` with stats (project count, doc count, word count), recently modified docs, project activity, and freshness distribution.
- **Heartbeat**: `watch-docs.sh` writes `_heartbeat.js` every 30 seconds. The index page polls it to show a green/red watcher status dot.
- **Watcher**: Uses fswatch to monitor `$CODE_DIR` for `.md` changes, rebuilding individual files incrementally.

## Dependencies

- **pandoc** — Markdown to HTML conversion
- **fswatch** — File system monitoring
- Both installed via Homebrew (path configured via `EXTRA_PATH` in `.env`)

## Theme System

Dark/light mode toggle in the sidebar header. Uses CSS custom properties on `:root` with `[data-theme="dark"]` overrides.

- **Parent frame** (index.html): owns the toggle, persists choice in `localStorage` key `code-docs-theme`, auto-detects `prefers-color-scheme` on first visit
- **Iframes** (doc pages, dashboard): read parent's `data-theme` attribute on init (same-origin), listen for `postMessage` `{ type: 'theme-change', theme }` as backup
- **Helper functions** in `build-docs.sh`: `emit_theme_css_vars` (shared CSS variables) and `emit_theme_listener_script` (iframe theme listener JS) reduce duplication between dashboard and index
- **style.html**: contains its own copy of CSS variables plus the iframe listener script (included by pandoc in every doc page)

## Key Conventions

- Scripts use `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"` for all relative paths (resolves symlinks)
- A symlink to this repo (e.g. `~/bin/code-docs`) can be created for convenience
- HTML output goes to `$OUTPUT_DIR` (configured in `.env`)
- The watcher runs in a **tmux session** (LaunchAgent was abandoned — macOS Full Disk Access restrictions prevent launchd processes from accessing `~/Documents/`)
- This project lives inside the directory it scans (`$CODE_DIR`), so its own `.md` files intentionally appear in the generated docs
