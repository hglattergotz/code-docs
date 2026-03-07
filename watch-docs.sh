#!/bin/bash
# watch-docs.sh — Polling-based doc rebuild loop
#
# Replaces the previous inotifywait/fswatch approach, which was unreliable
# when watching macOS host volumes from inside a Docker Linux container.
# inotify events don't propagate reliably through Docker Desktop's VirtioFS
# layer, so events were silently dropped.
#
# This version polls every POLL_INTERVAL seconds (default: 15) and calls
# build-docs.sh --update, which diffs the current .md file states against
# a saved state file and rebuilds only what changed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# Load configuration
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
fi
if [[ -z "${CODE_DIR:-}" || -z "${OUTPUT_DIR:-}" ]]; then
    echo "Error: CODE_DIR and OUTPUT_DIR must be set (via .env or environment variables)" >&2
    exit 1
fi

export PATH="${EXTRA_PATH:+$EXTRA_PATH:}$PATH"

POLL_INTERVAL="${POLL_INTERVAL:-15}"

cleanup() {
    rm -f "$OUTPUT_DIR/_heartbeat.js"
    rm -f "$OUTPUT_DIR/_lastbuild.js"
    exit 0
}
trap cleanup EXIT INT TERM

echo "Running initial full build..."
"$SCRIPT_DIR/build-docs.sh"

echo ""
echo "Polling for changes every ${POLL_INTERVAL}s in $CODE_DIR ..."
echo ""

while true; do
    sleep "$POLL_INTERVAL"
    "$SCRIPT_DIR/build-docs.sh" --update
done
