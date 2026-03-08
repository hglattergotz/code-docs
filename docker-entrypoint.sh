#!/bin/bash
set -e

mkdir -p /output

# Write a placeholder so the browser shows a progress page instead of 404
# while the initial build runs. The real index.html overwrites it when done.
cat > /output/index.html << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>code-docs — Building…</title>
  <meta http-equiv="refresh" content="4">
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      background: #0d1117;
      color: #c9d1d9;
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100vh;
    }
    .card {
      text-align: center;
      padding: 2.5rem 3rem;
      border: 1px solid #30363d;
      border-radius: 8px;
      background: #161b22;
    }
    .spinner {
      width: 40px;
      height: 40px;
      border: 3px solid #30363d;
      border-top-color: #58a6ff;
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
      margin: 0 auto 1.5rem;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    h1 { font-size: 1.1rem; color: #e6edf3; margin-bottom: 0.5rem; }
    p  { font-size: 0.85rem; color: #8b949e; }
  </style>
</head>
<body>
  <div class="card">
    <div class="spinner"></div>
    <h1>Building docs&hellip;</h1>
    <p>Initial build in progress. Page refreshes automatically.</p>
  </div>
</body>
</html>
HTML

echo "Starting HTTP server on :8000..."
python3 /app/serve.py &

echo "Running initial build..."
/app/build-docs.sh

echo "Starting watcher..."
SKIP_INITIAL_BUILD=1 exec /app/watch-docs.sh
