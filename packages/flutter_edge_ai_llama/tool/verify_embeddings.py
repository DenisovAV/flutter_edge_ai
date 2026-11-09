#!/usr/bin/env python3
"""Qualify the pinned EmbeddingGemma 2 text profile in a packaged app.

Desktop by default. `--device <id>` with an Android device id runs it on that
device or emulator: the fixture is served from this machine through
`adb reverse`, and on Android, where llamadart has no GPU embedding path,
`--backend gpu` must be refused and `--backend auto` must load on the CPU
without the "selected CPU" warning.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import sys
from threading import Thread

from fetch_test_model import verify
from verify import PACKAGE, run_smoke

DESKTOP = ('macos', 'linux', 'windows')
# Printed when automatic placement asked for GPU layers and got the CPU on a
# target that should have had the GPU. Android resolves auto to the CPU by
# design, so the warning there would be noise.
AUTO_CPU_WARNING = 'load requested GPU layers but selected CPU'
ANDROID_GPU_REFUSAL = 'unavailable on Android'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-path', type=Path, required=True)
    parser.add_argument('--backend', choices=['cpu', 'gpu', 'auto'], default='cpu')
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--device',
                        default={'darwin': 'macos', 'win32': 'windows'}.get(sys.platform, 'linux'),
                        help='macos, linux, windows, or an Android device id from `adb devices`')
    args = parser.parse_args()
    model = args.model_path.resolve()
    spec = json.loads((PACKAGE / 'tool/embedding_model.json').read_text())
    if not verify(model, spec):
        parser.error('The embedding fixture must match the pinned size and SHA-256.')
    android = args.device not in DESKTOP
    command = [args.flutter, 'test', 'integration_test/embedding_smoke_test.dart',
               '-d', args.device, '--no-pub', '--reporter', 'json',
               f'--dart-define=GGUF_EMBEDDING_BACKEND={args.backend}']
    if android:
        command.append(f'--dart-define=GGUF_EMBEDDING_EXPECT_GPU_REFUSAL={ANDROID_GPU_REFUSAL}')
    server = None
    thread = None
    if args.device == 'macos' or android:
        # A CLI path has no picker grant on macOS, and an Android app cannot
        # read this machine's files. Let core download the verified fixture
        # into app-owned storage instead.
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
        port = server.server_address[1]
        if android:
            # The device's 127.0.0.1:<port> reaches this machine's server.
            subprocess.run(['adb', '-s', args.device, 'reverse', f'tcp:{port}', f'tcp:{port}'],
                           check=True)
            # The load runs on core's embedding worker isolate, whose prints
            # reach logcat but not the test report; read the warning there.
            subprocess.run(['adb', '-s', args.device, 'logcat', '-c'], check=True)
        command.append(f'--dart-define=GGUF_EMBEDDING_MODEL_URL=http://127.0.0.1:{port}/embedding.gguf')
    else:
        command.append(f'--dart-define=GGUF_EMBEDDING_MODEL_PATH={model}')
    try:
        report = run_smoke(command, PACKAGE / 'example', 'packaged GGUF text embeddings',
                           timeout=1200 if android else 600)
        if android:
            logcat = subprocess.run(['adb', '-s', args.device, 'logcat', '-d', '-s', 'flutter'],
                                    check=True, capture_output=True, text=True).stdout
            if AUTO_CPU_WARNING in report or AUTO_CPU_WARNING in logcat:
                sys.exit(f'The automatic load on {args.device} printed "{AUTO_CPU_WARNING}".')
            marker = ('GGUF embedding GPU refused' if args.backend == 'gpu'
                      else 'GGUF embedding cycle=0 backend=PreferredBackend.cpu')
            if marker not in report:
                sys.exit(f'The run on {args.device} never printed "{marker}".')
    finally:
        if android:
            subprocess.run(['adb', '-s', args.device, 'reverse', '--remove-all'], check=False)
        if server is not None:
            server.shutdown()
            thread.join()
            server.server_close()


if __name__ == '__main__':
    main()
