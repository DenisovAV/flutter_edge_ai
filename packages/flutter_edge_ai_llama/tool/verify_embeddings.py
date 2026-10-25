#!/usr/bin/env python3
"""Qualify the pinned EmbeddingGemma 2 text profile in a packaged desktop app."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import sys
from threading import Thread

from fetch_test_model import verify
from verify import PACKAGE, run_smoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-path', type=Path, required=True)
    parser.add_argument('--backend', choices=['cpu', 'gpu', 'auto'], default='cpu')
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--device', choices=['macos', 'linux', 'windows'],
                        default={'darwin': 'macos', 'win32': 'windows'}.get(sys.platform, 'linux'))
    args = parser.parse_args()
    model = args.model_path.resolve()
    spec = json.loads((PACKAGE / 'tool/embedding_model.json').read_text())
    if not verify(model, spec):
        parser.error('The embedding fixture must match the pinned size and SHA-256.')
    command = [args.flutter, 'test', 'integration_test/embedding_smoke_test.dart',
               '-d', args.device, '--no-pub', '--reporter', 'json',
               f'--dart-define=GGUF_EMBEDDING_BACKEND={args.backend}']
    server = None
    thread = None
    if args.device == 'macos':
        # A CLI path has no picker grant. Keep the sandbox enabled and let core
        # download this verified fixture into app-owned storage instead.
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != '/embedding.gguf':
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(model.stat().st_size))
                self.end_headers()
                with model.open('rb') as source:
                    shutil.copyfileobj(source, self.wfile)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        command.append(f'--dart-define=GGUF_EMBEDDING_MODEL_URL=http://127.0.0.1:{server.server_address[1]}/embedding.gguf')
    else:
        command.append(f'--dart-define=GGUF_EMBEDDING_MODEL_PATH={model}')
    try:
        run_smoke(command, PACKAGE / 'example', 'packaged GGUF text embeddings', timeout=600)
    finally:
        if server is not None:
            server.shutdown()
            thread.join()
            server.server_close()


if __name__ == '__main__':
    main()
