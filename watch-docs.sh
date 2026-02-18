#!/bin/bash
# watch-docs.sh - Watch for markdown changes and rebuild HTML
#
# Runs an initial full build, then watches for .md file changes.
# Also detects structural changes (directory renames/moves/deletes)
# and triggers full rebuilds with orphan cleanup.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# Load configuration
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
else
    echo "Error: $SCRIPT_DIR/.env not found. Copy .env.example to .env and configure." >&2
    exit 1
fi

export PATH="${EXTRA_PATH:+$EXTRA_PATH:}$PATH"
HEARTBEAT_FILE="$OUTPUT_DIR/_heartbeat.js"
FULL_REBUILD_TS_FILE=$(mktemp "${TMPDIR:-/tmp}/code-docs-rebuild.XXXXXX")

write_heartbeat() {
    mkdir -p "$OUTPUT_DIR"
    echo "window.__watcherHeartbeat = $(date +%s);" > "$HEARTBEAT_FILE"
}

cleanup() {
    # Kill the heartbeat background loop if running
    if [[ -n "${HEARTBEAT_PID:-}" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
    fi
    rm -f "$HEARTBEAT_FILE"
    rm -f "$OUTPUT_DIR/_lastbuild.js"
    rm -f "$FULL_REBUILD_TS_FILE"
    exit 0
}

trap cleanup EXIT INT TERM

echo "Running initial build..."
"$SCRIPT_DIR/build-docs.sh"

# Start heartbeat background loop (write every 30s)
(
    while true; do
        write_heartbeat
        sleep 30
    done
) &
HEARTBEAT_PID=$!

echo ""
echo "Watching for changes in $CODE_DIR ..."

# Build fswatch exclude args for excluded projects
exclude_args=()
if [[ -n "${EXCLUDE_PROJECTS:-}" ]]; then
    for project in $EXCLUDE_PROJECTS; do
        exclude_args+=(--exclude "$CODE_DIR/$project")
    done
fi

fswatch \
    --event Created --event Updated --event Renamed --event Removed \
    --latency 2 \
    --exclude="node_modules" --exclude="\\.git" --exclude="vendor" \
    --exclude="__pycache__" --exclude="\\.venv" --exclude="\\.next" \
    --exclude="dist" --exclude="\\.cache" --exclude="\\.terraform" \
    "${exclude_args[@]}" \
    "$CODE_DIR" | while IFS= read -r changed_file; do

    # Three-way classification
    if [[ "$changed_file" == *.md ]]; then
        # Markdown file changed — incremental build
        echo ""
        echo "Changed: $changed_file"
        "$SCRIPT_DIR/build-docs.sh" --file "$changed_file"
        write_heartbeat

    elif [[ -d "$changed_file" ]] || { [[ ! -e "$changed_file" ]] && [[ "$changed_file" != *.* ]]; }; then
        # Directory event or deleted path with no extension — structural change
        # Debounce: only run full rebuild if >10s since last one
        local_now=$(date +%s)
        last_rebuild=$(cat "$FULL_REBUILD_TS_FILE" 2>/dev/null || echo 0)
        if (( local_now - last_rebuild >= 10 )); then
            echo ""
            echo "Structural change detected: $changed_file"
            echo "Running full rebuild..."
            echo "$local_now" > "$FULL_REBUILD_TS_FILE"
            "$SCRIPT_DIR/build-docs.sh"
            write_heartbeat
        fi
    fi
    # Otherwise (non-.md files like .js, .py, etc.) — ignore silently
done
