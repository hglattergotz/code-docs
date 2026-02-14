# Code Docs

Shell-based build system that converts Markdown files from `~/Documents/code/` projects into browsable HTML documentation at `~/Documents/code-html/`.

## File Layout

| File | Purpose |
|------|---------|
| `build-docs.sh` | Main build script — scans for `.md` files, converts to HTML via pandoc, generates index and dashboard |
| `watch-docs.sh` | File watcher — runs initial build, then uses fswatch to rebuild on `.md` changes; manages heartbeat |
| `style.html` | Pandoc HTML template included in every generated page for consistent styling |
| `build-system.md` | Project documentation (this file becomes part of the generated docs) |

## Commands

```bash
# Full rebuild of all docs + index
./build-docs.sh

# Rebuild a single file + index (used by the watcher)
./build-docs.sh --file ~/Documents/code/project/README.md

# Clean everything and do a full rebuild
./build-docs.sh --clean

# Start the file watcher manually
./watch-docs.sh

# Load/unload the LaunchAgent (auto-starts watcher at login)
launchctl load ~/Library/LaunchAgents/com.user.code-docs-watcher.plist
launchctl unload ~/Library/LaunchAgents/com.user.code-docs-watcher.plist
```

## Architecture

- **Scanning**: Finds `.md` files at project root level (depth 2) and inside `docs/`, `docks/`, `doc/` directories. Excludes `node_modules`, `.git`, `vendor`, `__pycache__`, `.venv`, `.next`, `dist`, `.cache`, `.terraform`.
- **Incremental builds**: Only rebuilds when HTML output is missing or older than the source `.md` or `style.html`.
- **Conversion**: Uses pandoc with `style.html` template. Extracts first `# heading` as page title.
- **Index generation**: Creates `index.html` with sidebar navigation, project search, and iframe-based document viewer.
- **Dashboard**: Generates `dashboard.html` with stats (project count, doc count, word count), recently modified docs, project activity, and freshness distribution.
- **Heartbeat**: `watch-docs.sh` writes `_heartbeat.js` every 30 seconds. The index page polls it to show a green/red watcher status dot.
- **Watcher**: Uses fswatch to monitor `~/Documents/code/` for `.md` changes, rebuilding individual files incrementally.

## Dependencies

- **pandoc** — Markdown to HTML conversion (`/opt/homebrew/bin/pandoc`)
- **fswatch** — File system monitoring (`/opt/homebrew/bin/fswatch`)
- Both installed via Homebrew

## Key Conventions

- Scripts use `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` for all relative paths
- `~/bin/code-docs` is a **symlink** pointing to this repo at `~/Documents/code/code-docs/`
- HTML output goes to `~/Documents/code-html/`
- The LaunchAgent plist lives at `~/Library/LaunchAgents/com.user.code-docs-watcher.plist` and references the symlink path
- This project lives inside the directory it scans (`~/Documents/code/`), so its own `.md` files intentionally appear in the generated docs
