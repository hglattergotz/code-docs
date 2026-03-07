#!/bin/bash
set -e

mkdir -p /output

echo "Starting HTTP server on :8000..."
python3 /app/serve.py &

echo "Starting watcher..."
exec /app/watch-docs.sh
