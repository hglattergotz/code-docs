#!/bin/bash
set -e

mkdir -p /output

echo "Starting HTTP server on :8000..."
cd /output && python3 -m http.server 8000 &

echo "Starting watcher..."
exec /app/watch-docs.sh
