#!/usr/bin/env python3
"""Mutation tests for check_codelab_web_storage.py — run before the real check.

A guard is only worth its false sense of security if something proves it still
fires. Each case below builds a minimal codelab tree, breaks exactly one thing
a browser needs, and asserts the guard reports it. Every MISS in this file was
a real escape at some point: the first version was a `grep`, and a review broke
it four ways in an afternoon; the second version was a regex, and a review broke
it fifteen.

No network, no flutter, no pub: the fixtures point package_config.json at the
real pub cache only to have some bytes to compare against.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote, urlparse
from urllib.request import url2pathname

HERE = Path(__file__).resolve().parent
CHECKER = HERE / "check_codelab_web_storage.py"

INDEX = """<html><head>
<script type="module">
window.litertLmReady = (async () => 1)();
</script>
<script src="cache_api.js"></script>
<script src="opfs_helper.js"></script>
</head><body><script src="flutter_bootstrap.js" async></script></body></html>
"""

PUBSPEC = """name: demo
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  flutter_edge_ai: ^2.0.0
  flutter_edge_ai_litertlm: ^1.8.7
"""

MAIN = """import 'package:flutter_edge_ai/flutter_edge_ai.dart';

void main() async {
  await FlutterEdgeAi.initialize(
    webStorageMode: WebStorageMode.streaming,
    inferenceEngines: [LiteRtLmEngine()],
  );
}
"""


def package_dir(name: str) -> Path | None:
    """A resolved package from THIS repo's own codelab apps, for real bytes."""
    for config in sorted((HERE.parent / "codelabs").glob("*/*/.dart_tool/package_config.json")):
        try:
            entries = json.loads(config.read_text())["packages"]
        except (OSError, ValueError, KeyError):
            continue
        for entry in entries:
            if entry["name"] != name:
                continue
            uri = entry["rootUri"]
            if uri.startswith("file://"):
                return Path(url2pathname(urlparse(uri).path))
            relative_path = url2pathname(urlparse(uri).path)
            return (config.parent / relative_path).resolve()
    return None


def build(root: Path, core: Path, litertlm: Path) -> Path:
    app = root / "codelabs" / "demo" / "app"
    (app / "lib").mkdir(parents=True)
    (app / "web").mkdir()
    (app / ".dart_tool").mkdir()
    for js in ("cache_api.js", "opfs_helper.js"):
        shutil.copy(core / "web" / js, app / "web" / js)
    (app / "web" / "index.html").write_text(INDEX)
    (app / "pubspec.yaml").write_text(PUBSPEC)
    (app / "lib" / "main.dart").write_text(MAIN)
    (app / ".dart_tool" / "package_config.json").write_text(
        json.dumps(
            {
                "configVersion": 2,
                "packages": [
                    {"name": "flutter_edge_ai", "rootUri": core.as_uri(), "packageUri": "lib/"},
                    {"name": "flutter_edge_ai_litertlm", "rootUri": litertlm.as_uri(), "packageUri": "lib/"},
                ],
            }
        )
    )
    return app


def run(root: Path) -> int:
    return subprocess.run(
        [sys.executable, str(CHECKER), str(root)], capture_output=True, text=True
    ).returncode


def use_relative_encoded_root_uris(app: Path) -> None:
    """Mirror pub's relative rootUri form, including URI-escaped path bytes."""
    config = app / ".dart_tool" / "package_config.json"
    data = json.loads(config.read_text())
    package_roots = app.parents[2] / "package roots"
    for entry in data["packages"]:
        source = Path(url2pathname(urlparse(entry["rootUri"]).path))
        target = package_roots / entry["name"]
        target.mkdir(parents=True)
        if (source / "web").is_dir():
            shutil.copytree(source / "web", target / "web")
        relative = Path(os.path.relpath(target, config.parent)).as_posix()
        entry["rootUri"] = quote(relative, safe="/.")
    config.write_text(json.dumps(data))


# Each case mutates the fixture in place; the guard must exit non-zero.
def with_speech(app: Path, environments: str | None) -> Path:
    """Make the fixture depend on flutter_edge_ai_speech, and give its codelab a
    claat header with this environments line (None: no header at all)."""
    pubspec = app / "pubspec.yaml"
    pubspec.write_text(pubspec.read_text() + "  flutter_edge_ai_speech: ^0.5.3\n")
    if environments is not None:
        header = app.parents[2] / "website" / "codelabs" / app.parent.name / "index.md"
        header.parent.mkdir(parents=True, exist_ok=True)
        header.write_text(f"id: demo\nenvironments: {environments}\n\n# Demo\n")
    return app


MUST_FAIL = {
    # The header promises the web to an app that cannot run there.
    "native-only app, header lists web": lambda app: with_speech(app, "android, ios, web"),
    "native-only app, header lists web as a flow list": lambda app: with_speech(
        app, "[android, 'Web']"
    ),
    "native-only app, header lists web before a trailing comment": lambda app: (
        with_speech(app, "android, web # native caveat")
    ),
    # Nothing to check the claim against is not a pass.
    "native-only app, no header": lambda app: with_speech(app, None),
    "missing js": lambda app: (app / "web" / "opfs_helper.js").unlink(),
    "js differs by a byte": lambda app: (app / "web" / "cache_api.js").write_bytes(
        (app / "web" / "cache_api.js").read_bytes() + b";"
    ),
    "tag removed": lambda app: (app / "web" / "index.html").write_text(
        INDEX.replace('<script src="opfs_helper.js"></script>', "")
    ),
    "tag in an HTML comment": lambda app: (app / "web" / "index.html").write_text(
        INDEX.replace(
            '<script src="cache_api.js"></script>',
            '<!-- <script src="cache_api.js"></script> -->',
        )
    ),
    "tag inside <template>": lambda app: (app / "web" / "index.html").write_text(
        INDEX.replace(
            '<script src="cache_api.js"></script>',
            '<template><script src="cache_api.js"></script></template>',
        )
    ),
    "handshake commented out in JS": lambda app: (app / "web" / "index.html").write_text(
        INDEX.replace(
            "window.litertLmReady = (async () => 1)();",
            "// window.litertLmReady = (async () => 1)();",
        )
    ),
    "handshake only as prose": lambda app: (app / "web" / "index.html").write_text(
        INDEX.replace(
            "window.litertLmReady = (async () => 1)();",
            "console.log('litertLmReady is set up in step 4');",
        )
    ),
    "no webStorageMode": lambda app: (app / "lib" / "main.dart").write_text(
        MAIN.replace("    webStorageMode: WebStorageMode.streaming,\n", "")
    ),
    "webStorageMode only in a comment": lambda app: (app / "lib" / "main.dart").write_text(
        MAIN.replace(
            "    webStorageMode: WebStorageMode.streaming,",
            "    // webStorageMode: WebStorageMode.streaming, dropped, see #123",
        )
    ),
    "webStorageMode only in a nested comment": lambda app: (app / "lib" / "main.dart").write_text(
        MAIN.replace(
            "    webStorageMode: WebStorageMode.streaming,",
            "    /* off /* why */ webStorageMode: WebStorageMode.streaming, */",
        )
    ),
    "webStorageMode only in a string": lambda app: (app / "lib" / "main.dart").write_text(
        MAIN.replace(
            "    webStorageMode: WebStorageMode.streaming,",
            "",
        ).replace(
            "void main() async {",
            "const hint = 'pass webStorageMode: WebStorageMode.streaming on web';\n\nvoid main() async {",
        )
    ),
    "webStorageMode in another file": lambda app: (
        (app / "lib" / "main.dart").write_text(
            MAIN.replace("    webStorageMode: WebStorageMode.streaming,\n", "")
        ),
        (app / "lib" / "notes.dart").write_text(
            "// TODO: webStorageMode: WebStorageMode.streaming goes here.\n"
        ),
    ),
    "a second call site without it": lambda app: (app / "lib" / "main.dart").write_text(
        MAIN + "\nFuture<void> reset() async {\n"
        "  await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);\n}\n"
    ),
    "call without await": lambda app: (app / "lib" / "main.dart").write_text(
        "void main() {\n  FlutterEdgeAi.initialize(inferenceEngines: []);\n}\n"
    ),
    "call wrapped across lines": lambda app: (app / "lib" / "main.dart").write_text(
        "void main() async {\n  await FlutterEdgeAi\n      .initialize(inferenceEngines: []);\n}\n"
    ),
    "4-space dependencies block": lambda app: (
        (app / "pubspec.yaml").write_text(
            PUBSPEC.replace("  flutter_edge_ai: ^2.0.0", "    flutter_edge_ai: ^2.0.0")
        ),
        (app / "web" / "cache_api.js").unlink(),
    ),
    "flow-style dependencies": lambda app: (
        (app / "pubspec.yaml").write_text(
            "name: demo\ndependencies: {flutter_edge_ai: ^2.0.0, flutter_edge_ai_litertlm: ^1.8.7}\n"
        ),
        (app / "web" / "cache_api.js").unlink(),
    ),
    "lib/ missing": lambda app: shutil.rmtree(app / "lib"),
    "web/index.html missing": lambda app: (app / "web" / "index.html").unlink(),
    "package unresolved": lambda app: (app / ".dart_tool" / "package_config.json").unlink(),
}

# The guard must NOT fire on these: they are correct, just spelled differently.
MUST_PASS = {
    "relative URI-escaped package roots": use_relative_encoded_root_uris,
    "native-only app, header leaves web out": lambda app: with_speech(
        app, "android, ios, macos"
    ),
    "embeddings backend registered for native only": lambda app: (
        (app / "lib" / "main.dart").write_text(
            MAIN.replace(
                "    inferenceEngines: [LiteRtLmEngine()],",
                "    inferenceEngines: [LiteRtLmEngine()],\n"
                "    embeddingBackends: kIsWeb ? const [] : const [LiteRtEmbeddingBackend()],",
            )
        )
    ),
    "defer and ./ prefix": lambda app: (app / "web" / "index.html").write_text(
        INDEX.replace(
            '<script src="cache_api.js"></script>',
            '<script defer src="./cache_api.js"></script>',
        )
    ),
    "argument wrapped across lines": lambda app: (app / "lib" / "main.dart").write_text(
        MAIN.replace(
            "    webStorageMode: WebStorageMode.streaming,",
            "    webStorageMode:\n        WebStorageMode.streaming,",
        )
    ),
    "initialize named in a doc comment": lambda app: (app / "lib" / "main.dart").write_text(
        "/// Call FlutterEdgeAi.initialize( before runApp.\n" + MAIN
    ),
    "dev_dependencies only": lambda app: (
        (app / "pubspec.yaml").write_text(
            "name: demo\ndev_dependencies:\n  flutter_edge_ai: ^2.0.0\n"
        ),
        (app / "web" / "cache_api.js").unlink(),
        (app / "web" / "opfs_helper.js").unlink(),
        (app / "web" / "index.html").write_text("<html><head></head><body></body></html>"),
    ),
}


def main() -> int:
    core = package_dir("flutter_edge_ai")
    litertlm = package_dir("flutter_edge_ai_litertlm")
    if core is None or litertlm is None:
        print("::error::no resolved flutter_edge_ai in codelabs/ — run flutter pub get first")
        return 1

    failures = []
    for label, mutate in MUST_FAIL.items():
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mutate(build(root, core, litertlm))
            if run(root) == 0:
                failures.append(f"MISSED: {label}")
    for label, mutate in MUST_PASS.items():
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mutate(build(root, core, litertlm))
            if run(root) != 0:
                failures.append(f"FALSE ALARM: {label}")

    total = len(MUST_FAIL) + len(MUST_PASS)
    for line in failures:
        print(f"::error::web storage guard {line}")
    print(f"Guard mutation tests: {total - len(failures)}/{total} as expected.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
