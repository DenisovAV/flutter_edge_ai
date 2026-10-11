#!/usr/bin/env python3
"""Reject Web release artifacts missing or corrupting pinned runtime assets."""

import argparse
import hashlib
import json
from pathlib import Path

from fetch_web_assets import FILES, MANIFEST_SHA256, PACKAGE


def validate(directory):
    runtime = directory / "webgpu_bridge"
    data = (runtime / "manifest.json").read_bytes()
    if hashlib.sha256(data).hexdigest() != MANIFEST_SHA256:
        raise RuntimeError("Release artifact has the wrong Web runtime manifest")
    manifest = json.loads(data)
    for filename in FILES:
        path = runtime / filename
        expected = manifest["artifacts"][filename]
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        if path.stat().st_size != expected["size_bytes"] or digest.hexdigest() != expected["sha256"]:
            raise RuntimeError(f"Release artifact has a corrupt runtime asset: {filename}")
    for filename in ("index.html", "flutter_bootstrap.js", "main.dart.wasm", "cache_api.js", "cache_api.LICENSE", "_headers"):
        if not (directory / filename).is_file():
            raise RuntimeError(f"Release artifact is missing {filename}")
    for filename in ("cache_api.js", "cache_api.LICENSE", "_headers"):
        if (directory / filename).read_bytes() != (PACKAGE / "example/web" / filename).read_bytes():
            raise RuntimeError(f"Release artifact changed {filename}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=PACKAGE / "example/build/web")
    args = parser.parse_args()
    validate(args.directory)
    print("Web release artifact integrity: PASS")


if __name__ == "__main__":
    main()
