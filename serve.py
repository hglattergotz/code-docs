#!/usr/bin/env python3
"""HTTP server for code-docs: serves static files and handles build triggers.

POST /update   — incremental build (build-docs.sh --update): only rebuilds changed files
POST /rebuild  — full rebuild (build-docs.sh): rebuilds everything
"""
import http.server
import subprocess
import threading
import os

BUILD_SCRIPT = '/app/build-docs.sh'
OUTPUT_DIR = os.environ.get('OUTPUT_DIR', '/output')

_rebuild_lock = threading.Lock()
_rebuild_running = False


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        global _rebuild_running
        if self.path in ('/rebuild', '/update'):
            with _rebuild_lock:
                if _rebuild_running:
                    self._json(409, b'{"status":"already_running"}')
                    return
                _rebuild_running = True

            args = [BUILD_SCRIPT] if self.path == '/rebuild' else [BUILD_SCRIPT, '--update']

            def run_build():
                global _rebuild_running
                try:
                    subprocess.run(args)
                finally:
                    with _rebuild_lock:
                        _rebuild_running = False

            threading.Thread(target=run_build, daemon=True).start()
            self._json(202, b'{"status":"started"}')
        else:
            self.send_response(404)
            self.end_headers()

    def _json(self, code, body):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


os.chdir(OUTPUT_DIR)
print(f'Starting HTTP server on :8000 (serving {OUTPUT_DIR})', flush=True)
http.server.HTTPServer(('', 8000), Handler).serve_forever()
