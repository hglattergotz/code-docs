# Code Docs

Think GitHub Pages, but local and for all your projects at once. Point it at a folder of repositories and it turns every Markdown file it finds into a browsable HTML documentation site with sidebar navigation, search, and a project dashboard.

It recursively scans the directory for `.md` files, converts them to styled HTML via pandoc, and generates an index page that ties everything together. A file watcher rebuilds incrementally as you edit — no pushing to a remote, no deploy step.

## Quick Start

```bash
# Install dependencies
brew install pandoc fswatch tmux

# Run the interactive setup wizard (creates .env)
./code-docs.sh setup

# Start the file watcher + local web server
./code-docs.sh up --serve
```

Open [http://localhost:8000](http://localhost:8000) to browse your docs.

## Key Commands

```bash
./code-docs.sh up --serve    # Start watcher + web server
./code-docs.sh down          # Stop everything
./code-docs.sh status        # Check watcher state
./build-docs.sh --clean      # Full rebuild from scratch
./build-docs.sh --help       # Show build options
```

## Configuration

Copy `.env.example` to `.env` (or run `./code-docs.sh setup`). Key settings:

| Variable | Purpose |
|----------|---------|
| `CODE_DIR` | Directory containing your source code projects |
| `OUTPUT_DIR` | Where generated HTML is written |
| `EXCLUDE_PROJECTS` | Space-separated project names to skip |
| `SIDEBAR_STYLE` | `"tree"` (default, nested folders) or `"flat"` (file paths) |

## More Information

See [build-system.md](build-system.md) for full architecture details, file watcher behavior, theme system, and configuration reference.
