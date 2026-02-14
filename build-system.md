# Code Docs Build System

A shell-based build system that converts Markdown files from `~/Documents/code/` projects into a browsable HTML documentation site at `~/Documents/code-html/`.

## File Locations

| What | Path |
|------|------|
| Project repo | `~/Documents/code/code-docs/` |
| Symlink | `~/bin/code-docs` → `~/Documents/code/code-docs/` |
| Build script | `~/Documents/code/code-docs/build-docs.sh` |
| File watcher | `~/Documents/code/code-docs/watch-docs.sh` |
| Pandoc style | `~/Documents/code/code-docs/style.html` |
| This file | `~/Documents/code/code-docs/build-system.md` |
| LaunchAgent | `~/Library/LaunchAgents/com.user.code-docs-watcher.plist` |
| Source docs | `~/Documents/code/` |
| HTML output | `~/Documents/code-html/` |
| Dashboard | `~/Documents/code-html/dashboard.html` |
| Index | `~/Documents/code-html/index.html` |

## Usage

```bash
# Full rebuild of all docs + index
~/Documents/code/code-docs/build-docs.sh

# Rebuild a single file + index (used by the watcher)
~/Documents/code/code-docs/build-docs.sh --file ~/Documents/code/project/README.md

# Clean everything and do a full rebuild
~/Documents/code/code-docs/build-docs.sh --clean

# Start the file watcher (runs initial build, then watches for changes)
~/Documents/code/code-docs/watch-docs.sh
```

> **Note:** `~/bin/code-docs` is a symlink to `~/Documents/code/code-docs/`, so both paths work.

## How It Works

### Scanning

The build system scans `~/Documents/code/` for `.md` files in two ways:

1. **Root-level**: `.md` files at the top of each project directory (depth 2, e.g., `code/project/README.md`)
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
- Output placed in `~/Documents/code-html/` mirroring the source directory structure

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

`watch-docs.sh` uses `fswatch` to monitor `~/Documents/code/` for `.md` file changes. When a file changes, it rebuilds just that file and regenerates the index.

## Dependencies

- **pandoc** — Markdown to HTML conversion
- **fswatch** — File system change monitoring (for `watch-docs.sh`)
- Both expected at `/opt/homebrew/bin` (Homebrew on Apple Silicon)
