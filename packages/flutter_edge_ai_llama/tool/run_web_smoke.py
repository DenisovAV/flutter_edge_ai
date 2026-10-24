#!/usr/bin/env python3
"""Run real Web inference with worker isolation headers missing in Flutter tests.

The proxy changes HTTP headers only, for this test browser's local runtime asset
requests. It does not modify Flutter, browser settings, or upstream assets.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shlex
import select
import socket
import shutil
import subprocess
import tempfile
from threading import Thread
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import urlopen

from smoke_result import require_smoke_success

PACKAGE = Path(__file__).resolve().parents[1]


class HeadersProxy(BaseHTTPRequestHandler):
    def do_GET(self):
        target = urlparse(self.path)
        if (target.scheme not in {"http", "ws"} or target.hostname not in {"localhost", "127.0.0.1"}):
            self.send_error(403)
            return
        if self.headers.get("Upgrade", "").lower() == "websocket":
            with socket.create_connection((target.hostname, target.port)) as upstream:
                path = target.path + ("?" + target.query if target.query else "")
                request = f"GET {path} HTTP/1.1\r\n" + "".join(
                    f"{name}: {value}\r\n" for name, value in self.headers.items()
                    if not name.lower().startswith("proxy-")) + "\r\n"
                upstream.sendall(request.encode())
                self._relay(upstream)
            return
        try:
            try:
                response = urlopen(self.path, timeout=30)
            except HTTPError as error:
                response = error
            with response:
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/octet-stream"))
                if response.headers.get("Content-Length"):
                    self.send_header("Content-Length", response.headers["Content-Length"])
                if target.path.startswith("/webgpu_bridge/"):
                    print(f"WEB_SMOKE_PROXY: isolation headers for {target.path}", flush=True)
                    self.send_header("Cross-Origin-Opener-Policy", "same-origin")
                    self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
                else:
                    for header in ("Cross-Origin-Opener-Policy", "Cross-Origin-Embedder-Policy",
                                   "Cross-Origin-Resource-Policy", "Access-Control-Allow-Origin"):
                        if response.headers.get(header):
                            self.send_header(header, response.headers[header])
                self.end_headers()
                shutil.copyfileobj(response, self.wfile)
        except Exception:
            self.send_error(502)

    def _relay(self, upstream):
        # Browser-manager WebSockets must remain unchanged through the proxy.
        sockets = [self.connection, upstream]
        while True:
            ready, _, _ = select.select(sockets, [], [], 1)
            for source in ready:
                data = source.recv(65536)
                if not data:
                    return
                (upstream if source is self.connection else self.connection).sendall(data)

    def do_CONNECT(self):
        host, _, port = self.path.rpartition(":")
        if host not in {"localhost", "127.0.0.1"}:
            self.send_error(403)
            return
        with socket.create_connection((host, int(port))) as upstream:
            self.send_response(200, "Connection Established")
            self.end_headers()
            self._relay(upstream)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default=shutil.which("flutter"))
    parser.add_argument("--chrome", default=os.environ.get("CHROME_EXECUTABLE") or shutil.which("google-chrome") or shutil.which("chromium") or shutil.which("chromium-browser") or "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    parser.add_argument("--model-url", required=True)
    parser.add_argument("--storage-helper-url")
    args = parser.parse_args()
    if os.name == "nt":
        parser.error("The isolation-header proxy runner requires a POSIX host; run this lane on Linux or macOS.")
    if not args.flutter or not Path(args.chrome).is_file():
        parser.error("Supply existing --flutter and --chrome executables.")
    proxy = ThreadingHTTPServer(("127.0.0.1", 0), HeadersProxy)
    thread = Thread(target=proxy.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="edge-llama-browser-") as temporary:
            wrapper = Path(temporary) / "chrome"
            setting = f"http=127.0.0.1:{proxy.server_port};https=direct://"
            wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(args.chrome)} --proxy-server={shlex.quote(setting)} --proxy-bypass-list='<-loopback>' \"$@\"\n")
            wrapper.chmod(0o700)
            command = [args.flutter, "test", "test/web_smoke_test.dart", "--platform", "chrome",
                       "--wasm", "--cross-origin-isolation", "--reporter", "json",
                       f"--dart-define=GGUF_WEB_MODEL_URL={args.model_url}"]
            if args.storage_helper_url:
                command.append(f"--dart-define=GGUF_WEB_STORAGE_HELPER_URL={args.storage_helper_url}")
            result = subprocess.run(command, cwd=PACKAGE,
                                    env={**os.environ, "CHROME_EXECUTABLE": str(wrapper)}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(result.stdout, flush=True)
            if result.returncode == 0:
                require_smoke_success(result.stdout, "real browser facade installs a URL")
            return result.returncode
    finally:
        proxy.shutdown()
        proxy.server_close()
        thread.join()


if __name__ == "__main__":
    raise SystemExit(main())
