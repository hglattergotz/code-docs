#!/bin/bash
# watch-docs.sh - Watch for markdown changes and rebuild HTML
#
# Runs an initial full build, then watches for .md file changes.

set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODE_DIR="$HOME/Documents/code"
OUTPUT_DIR="$HOME/Documents/code-html"
HEARTBEAT_FILE="$OUTPUT_DIR/_heartbeat.js"

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
echo "Watching for .md changes in $CODE_DIR ..."

fswatch \
    --event Created --event Updated --event Renamed --event Removed \
    -e ".*" -i "\\.md$" \
    --exclude="node_modules" --exclude="\\.git" --exclude="vendor" \
    "$CODE_DIR" | while IFS= read -r changed_file; do
    echo ""
    echo "Changed: $changed_file"
    "$SCRIPT_DIR/build-docs.sh" --file "$changed_file"
    write_heartbeat
done
