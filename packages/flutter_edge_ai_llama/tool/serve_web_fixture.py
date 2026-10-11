#!/usr/bin/env python3
"""Serve only the verified Web smoke model and pinned storage helper locally."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil

from fetch_test_model import PACKAGE, verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8098)
    args = parser.parse_args()
    spec = json.loads((PACKAGE / "tool/test_model.json").read_text())
    if not verify(args.model_path, spec):
        parser.error("Web smoke fixture must match the pinned size and checksum")
    files = {
        "/chat.gguf": (args.model_path, "application/octet-stream"),
        "/cache_api.js": (PACKAGE / "example/web/cache_api.js", "text/javascript"),
    }

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            entry = files.get(self.path)
            if entry is None:
                self.send_error(404)
                return
            path, content_type = entry
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(path.stat().st_size))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
            self.end_headers()
            with path.open("rb") as source:
                shutil.copyfileobj(source, self.wfile)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
