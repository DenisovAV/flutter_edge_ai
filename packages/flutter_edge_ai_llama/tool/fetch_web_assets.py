#!/usr/bin/env python3
"""Stage checksum-verified, unmodified runtime assets for the Web demo/tests."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

PACKAGE = Path(__file__).resolve().parents[1]
TAG = "v0.1.65"
MANIFEST_SHA256 = "185cfc060fb90b7c8d240b23e7eeb85ef402eb3ef52e8acb1a5590cd5da56328"
BASE = f"https://cdn.jsdelivr.net/gh/leehack/llama-web-bridge-assets@{TAG}"
OUT = PACKAGE / "example/web/webgpu_bridge"
FILES = (
    "llama_webgpu_bridge.js",
    "llama_webgpu_bridge_worker.js",
    "llama_webgpu_core.js",
    "llama_webgpu_core.wasm",
    "llama_webgpu_core_mem64.js",
    "llama_webgpu_core_mem64.wasm",
)


def download(name, destination):
    subprocess.run(
        ["curl", "--fail", "--location", "--silent", "--show-error",
         "--retry", "3", f"{BASE}/{name}", "--output", str(destination)],
        check=True,
    )


def main(argv=None):
    global OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUT, help="Application web/webgpu_bridge directory")
    args = parser.parse_args(argv)
    OUT = args.output
    with tempfile.TemporaryDirectory(prefix="edge-llama-web-") as temporary:
        staging = Path(temporary)
        download("manifest.json", staging / "manifest.json")
        manifest_data = (staging / "manifest.json").read_bytes()
        if hashlib.sha256(manifest_data).hexdigest() != MANIFEST_SHA256:
            raise RuntimeError("Pinned Web runtime manifest checksum mismatch")
        manifest = json.loads(manifest_data)
        if (manifest.get("bridge_assets_tag") != TAG or
                manifest.get("assets_repository") != "leehack/llama-web-bridge-assets"):
            raise RuntimeError("Unexpected Web runtime provenance")
        for name in FILES:
            download(name, staging / name)
            digest = hashlib.sha256()
            with (staging / name).open("rb") as asset:
                for block in iter(lambda: asset.read(1024 * 1024), b""):
                    digest.update(block)
            expected = manifest["artifacts"][name]
            if ((staging / name).stat().st_size != expected["size_bytes"] or
                    digest.hexdigest() != expected["sha256"]):
                raise RuntimeError(f"Web runtime checksum mismatch: {name}")
        OUT.mkdir(parents=True, exist_ok=True)
        for name in (*FILES, "manifest.json"):
            shutil.copyfile(staging / name, OUT / name)
    test_link = PACKAGE / "test/webgpu_bridge"
    if OUT == PACKAGE / "example/web/webgpu_bridge" and not test_link.exists():
        test_link.symlink_to("../example/web/webgpu_bridge", target_is_directory=True)
    print(f"Staged unmodified {TAG} assets in {OUT}")


if __name__ == "__main__":
    main()
