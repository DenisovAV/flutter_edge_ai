#!/usr/bin/env python3
"""Reject Web release artifacts missing or corrupting pinned runtime assets."""

import argparse
import hashlib
import json
import re
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
    validate_headers((directory / "_headers").read_text())
    # Consumer additions are allowed. This checks the storage helper's static
    # interface only; app/browser tests must still verify its behavior.
    helper = (directory / "cache_api.js").read_text()
    for name in ("cacheHas", "cacheGetBlobUrl", "cachePut", "cacheDelete",
                 "cacheDeleteCache", "cacheGetAllKeys", "storageRequestPersistent",
                 "storageGetQuota", "blobUrlRevoke", "createBlob"):
        if not re.search(rf"(?:window|globalThis)\.{name}\s*=", helper):
            raise RuntimeError(f"Storage helper is missing {name}")
    if (directory / "cache_api.LICENSE").read_bytes() != (PACKAGE / "example/web/cache_api.LICENSE").read_bytes():
        raise RuntimeError("Release artifact changed cache_api.LICENSE")


def validate_headers(source):
    required = {"cross-origin-opener-policy": "same-origin",
                "cross-origin-embedder-policy": "require-corp"}
    wildcard = {}
    scope = None
    for line in source.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            scope = line.strip()
            continue
        name, separator, value = line.strip().partition(":")
        name, value = name.lower(), value.strip().lower()
        if separator and name in required:
            if value != required[name]:
                raise RuntimeError(f"Conflicting isolation header: {name}")
            if scope == "/*": wildcard[name] = value
    if wildcard != required:
        raise RuntimeError("_headers must apply COOP same-origin and COEP require-corp to /*")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=PACKAGE / "example/build/web")
    args = parser.parse_args()
    validate(args.directory)
    print("Web release artifact integrity: PASS")


if __name__ == "__main__":
    main()
