#!/usr/bin/env python3
"""Fetch the immutable small CPU smoke fixture; reuse only verified bytes."""

import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

PACKAGE = Path(__file__).resolve().parents[1]


def verify(path, spec):
    if not path.is_file() or path.stat().st_size != spec["size_bytes"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest() == spec["sha256"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=PACKAGE / "tool/fixtures/chat.gguf")
    args = parser.parse_args()
    spec = json.loads((PACKAGE / "tool/test_model.json").read_text())
    target = args.output.resolve()
    if not verify(target, spec):
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_suffix(".partial")
        url = (f'https://huggingface.co/{spec["repository"]}/resolve/'
               f'{spec["revision"]}/{spec["filename"]}')
        try:
            with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as output:
                while block := response.read(1024 * 1024):
                    output.write(block)
            if not verify(partial, spec):
                raise RuntimeError("Smoke fixture size or SHA-256 mismatch")
            partial.replace(target)
        finally:
            partial.unlink(missing_ok=True)
    print(target)


if __name__ == "__main__":
    main()
