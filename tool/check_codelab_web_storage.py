#!/usr/bin/env python3
"""Assert every codelab app is set up to install a model in a browser.

Core binds with `@JS` to globals that only exist once the page has loaded
flutter_edge_ai's `cache_api.js` (Cache API storage) and `opfs_helper.js` (OPFS
streaming), which an app has to copy out of the package's own `web/`. Without
them a web install downloads the whole model and then dies on
`window.cachePut`. `flutter build web` cannot see that — it never opens a
browser — so every codelab app shipped broken on web until this check existed.

Asserted per app, and why each oracle is the one it is:

- Does the app depend on flutter_edge_ai? Parsed out of `pubspec.yaml`'s
  `dependencies:` block — not a `grep`, which also matched `dev_dependencies:`
  and `dependency_overrides:`, and missed the equally valid 4-space and flow
  (`{a: ^1, b: ^2}`) spellings, silently skipping every check for that app.
- Are the JS files the ones the app actually resolves? Compared against THIS
  app's `.dart_tool/package_config.json` resolution. `web/opfs_helper.js`
  reached the package only in 1.8.2 (#505), so "the repo's copy" and "the
  published copy" do diverge, and two apps may pin different versions.
- Are the scripts loaded? Matched against live markup only: HTML comments,
  `<template>` and `<noscript>` are removed first, since none of them loads
  anything. `litert_embeddings.js` additionally needs `type="module"` — it is
  an ES module, and as a classic script its first `import` is a SyntaxError.
- Is the `@litert-lm/core` handshake published? A live `<script>` must ASSIGN
  `window.litertLmReady`; the word in prose or in a `//`-commented line is not
  a handshake.
- An app that ships `litert_embeddings.js` must ship the whole module graph it
  imports and load it as a module. The rule is "if you ship it, ship it whole",
  not "if you register the backend, ship it": registering
  `LiteRtEmbeddingBackend` behind a `!kIsWeb` gate is legitimate — on web the
  LiteRT.js runtime needs a WASM bundle no published package ships.
- Does every `FlutterEdgeAi.initialize(` call ask for OPFS streaming? Checked
  per CALL SITE, over that call's own argument list, with Dart comments and
  string literals removed — one compliant call used to license every other
  call in the same file.

Scope, stated plainly: only `lib/` is scanned for call sites. `integration_test/`
suites run on a device, where `webStorageMode` does not apply.

Fail closed: anything this cannot read is reported against that app and the run
continues, so one unreadable file cannot hide the other 22 apps.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import url2pathname

STORAGE_JS = ("cache_api.js", "opfs_helper.js")
# `litert_embeddings.js` imports the other three by relative path, so all four
# have to sit together. They all ship from one package as of litertlm 1.8.0 —
# the split that made a CDN one-liner 404 on two of them is gone.
EMBEDDINGS_JS = {
    "flutter_edge_ai_litertlm": (
        "litert_embeddings.js",
        "sentencepiece.js",
        "litert.js",
        "tensorflow.js",
    ),
}

HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
INERT_ELEMENT = re.compile(
    r"<(template|noscript)\b.*?</\1\s*>", re.DOTALL | re.IGNORECASE
)
SCRIPT_TAG = re.compile(r"<script\b[^>]*>", re.IGNORECASE)
SCRIPT_ELEMENT = re.compile(
    r"<script\b[^>]*>(.*?)</script\s*>", re.DOTALL | re.IGNORECASE
)
HANDSHAKE_ASSIGNMENT = re.compile(r"(?:window\s*\.\s*)?litertLmReady\s*=")
INITIALIZE_CALL = re.compile(r"FlutterEdgeAi\s*\.\s*initialize\s*\(")
STREAMING_ARG = re.compile(r"webStorageMode:\s*WebStorageMode\s*\.\s*streaming")

errors: list[str] = []
root = Path.cwd()


def fail(message: str) -> None:
    errors.append(message)
    print(f"::error::{message}")


def rel(path: Path) -> str:
    """Repo-relative where possible, so CI can annotate the file in the diff."""
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def read(path: Path, app: Path) -> str | None:
    """Text of `path`, or None after reporting why it could not be read."""
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        fail(
            f"{rel(path)} cannot be read ({type(error).__name__}) — "
            f"{rel(app)} not fully checked"
        )
        return None


def dependencies(app: Path) -> set[str] | None:
    """The names under pubspec.yaml's top-level `dependencies:` key.

    Hand-rolled rather than a YAML library: this runs on a CI image with
    nothing installed but python3. It reads the block form at any indent and
    the inline flow form; both are valid and pub resolves both.
    """
    text = read(app / "pubspec.yaml", app)
    if text is None:
        return None
    names: set[str] = set()
    in_block = False
    for line in text.splitlines():
        if not line.strip() or line.strip().startswith("#"):
            continue
        head = re.match(r"^dependencies:\s*(.*)$", line)
        if head:
            flow = head.group(1).strip()
            if flow.startswith("{"):  # dependencies: {a: ^1, b: ^2}
                names.update(re.findall(r"([A-Za-z_]\w*)\s*:", flow))
                in_block = False
            else:
                in_block = True
            continue
        if in_block:
            if not line[:1].isspace():  # a new top-level key ends the block
                in_block = False
                continue
            entry = re.match(r"^\s+([A-Za-z_]\w*)\s*:", line)
            if entry:
                names.add(entry.group(1))
    return names


def resolved_package_dir(app: Path, package: str) -> Path | None:
    """Where `package` resolves for THIS app, or None if it cannot be read."""
    config = app / ".dart_tool" / "package_config.json"
    try:
        entries = json.loads(config.read_text())["packages"]
    except (OSError, ValueError, KeyError):
        return None
    for entry in entries:
        if entry.get("name") == package:
            uri = entry.get("rootUri", "")
            if uri.startswith("file://"):
                return Path(url2pathname(urlparse(uri).path))
            relative_path = url2pathname(urlparse(uri).path)
            return (config.parent / relative_path).resolve()
    return None


def live_markup(html: str) -> str:
    """The markup a browser would act on: no comments, no inert elements."""
    return INERT_ELEMENT.sub("", HTML_COMMENT.sub("", html))


def loads_script(html: str, src: str, *, module: bool = False) -> bool:
    for tag in SCRIPT_TAG.finditer(live_markup(html)):
        text = tag.group(0)
        if not re.search(
            rf"""\bsrc\s*=\s*["']\.?/?{re.escape(src)}["']""", text, re.IGNORECASE
        ):
            continue
        if module and not re.search(
            r"""\btype\s*=\s*["']module["']""", text, re.IGNORECASE
        ):
            continue
        return True
    return False


def strip_code_noise(text: str) -> str:
    """`text` with comments and string literals blanked out.

    Shared by the Dart and inline-JS readers. Handles NESTED block comments
    (legal in Dart) and strings, so neither `/* off /* why */ webStorageMode:
    … */` nor `'pass webStorageMode: …'` can satisfy a check.
    """
    out: list[str] = []
    i, depth, n = 0, 0, len(text)
    while i < n:
        two = text[i : i + 2]
        if depth:
            if two == "/*":
                depth += 1
                i += 2
            elif two == "*/":
                depth -= 1
                i += 2
            else:
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            continue
        if two == "/*":
            depth = 1
            i += 2
            continue
        if two == "//":
            end = text.find("\n", i)
            i = n if end == -1 else end
            continue
        char = text[i]
        if char in "'\"":
            triple = text[i : i + 3]
            quote = triple if triple in ("'''", '"""') else char
            i += len(quote)
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text.startswith(quote, i):
                    i += len(quote)
                    break
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            continue
        out.append(char)
        i += 1
    return "".join(out)


def call_arguments(code: str, open_paren: int) -> str:
    """The argument list of the call whose `(` is at `open_paren`."""
    depth, i, n = 0, open_paren, len(code)
    while i < n:
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return code[open_paren + 1 : i]
        i += 1
    return code[open_paren:]


def publishes_handshake(html: str) -> bool:
    """True when a live inline script assigns `window.litertLmReady`."""
    for script in SCRIPT_ELEMENT.finditer(live_markup(html)):
        if HANDSHAKE_ASSIGNMENT.search(strip_code_noise(script.group(1))):
            return True
    return False


# Packages whose web export is a stub: an app that depends on one cannot run in
# a browser, so its codelab must not tell readers it does.
NATIVE_ONLY = {"flutter_edge_ai_speech"}


def check_platform_claim(app: Path, deps: set[str]) -> None:
    """The codelab's claat header must not promise the web to a native-only app.

    `environments:` in `website/codelabs/<id>/index.md` is what the codelab page
    shows readers. This makes it a checked claim: an app that depends on a
    package with no web implementation belongs to a codelab that leaves `web`
    out. Fails closed when the header or the line cannot be read.
    """
    native_only = deps & NATIVE_ONLY
    if not native_only:
        return
    header = root / "website" / "codelabs" / app.parent.name / "index.md"
    try:
        text = header.read_text(encoding="utf-8")
    except OSError:
        fail(f"{rel(header)} is missing or unreadable — cannot check that "
             f"{rel(app)} ({', '.join(sorted(native_only))}) is not promised on web")
        return
    match = re.search(r"^environments:[ \t]*(.*)$", text, re.MULTILINE)
    if match is None:
        fail(f"{rel(header)} has no environments: line — cannot check that "
             f"{rel(app)} is not promised on web")
        return
    # claat writes a bare comma list; a trailing `#` comment, brackets, quotes
    # or case must not hide `web` from this check.
    listed = match.group(1).split("#", 1)[0]
    listed = re.sub(r"[\[\]\"']", "", listed).lower()
    if "web" in {e.strip() for e in listed.split(",")}:
        fail(f"{rel(header)} lists web, but {rel(app)} depends on "
             f"{', '.join(sorted(native_only))}, which has no web implementation")


def check_app(app: Path) -> None:
    deps = dependencies(app)
    if deps is None:
        return
    check_platform_claim(app, deps)
    uses_edge_ai = "flutter_edge_ai" in deps

    index = app / "web" / "index.html"
    html = read(index, app) if index.is_file() else None
    if html is None:
        fail(
            f"{rel(index)} is missing or unreadable — "
            "the web storage check cannot run"
        )
        return

    reference = resolved_package_dir(app, "flutter_edge_ai")
    if uses_edge_ai and reference is None:
        fail(
            f"{rel(app)} depends on flutter_edge_ai but it does not resolve "
            "(run flutter pub get) — the web storage check cannot run"
        )
        return

    for js in STORAGE_JS:
        copy = app / "web" / js
        source = None if reference is None else reference / "web" / js
        if not copy.exists():
            if uses_edge_ai:
                fail(f"{rel(copy)} is missing — copy it from {source}")
            continue
        if source is not None:
            if not source.is_file():
                fail(
                    f"{source} is not in the resolved package — "
                    f"cannot compare {rel(copy)}"
                )
            elif copy.read_bytes() != source.read_bytes():
                fail(f"{rel(copy)} differs from the resolved package's {source}")
        if not loads_script(html, js):
            fail(f"{rel(index)} does not load {js}")

    # The engine bootstrap is the third leg of the same tripod: without the
    # `@litert-lm/core` handshake the browser fails at engine creation, and the
    # storage scripts alone would report a clean bill of health.
    if "flutter_edge_ai_litertlm" in deps and not publishes_handshake(html):
        fail(f"{rel(index)} has no live script assigning window.litertLmReady")

    if not uses_edge_ai:
        return

    lib = app / "lib"
    if not lib.is_dir():
        fail(f"{rel(lib)} is missing — the web storage check cannot run")
        return

    sources: dict[Path, str] = {}
    for path in sorted(lib.rglob("*.dart")):
        text = read(path, app)
        if text is not None:
            sources[path] = strip_code_noise(text)

    # Keyed on the entry module being present, not on the Dart registration:
    # an app may legitimately register the backend on native only.
    if (app / "web" / "litert_embeddings.js").exists():
        for package, names in EMBEDDINGS_JS.items():
            package_dir = resolved_package_dir(app, package)
            if package_dir is None:
                fail(
                    f"{rel(app)} registers LiteRtEmbeddingBackend but {package} "
                    "does not resolve — the web storage check cannot run"
                )
                continue
            for js in names:
                source = package_dir / "web" / js
                copy = app / "web" / js
                if not source.is_file():
                    fail(f"{source} is not in the resolved package — cannot compare")
                elif not copy.exists():
                    fail(
                        f"{rel(copy)} is missing — litert_embeddings.js imports it; "
                        f"copy it from {source}"
                    )
                elif copy.read_bytes() != source.read_bytes():
                    fail(f"{rel(copy)} differs from the resolved package's {source}")
        if not loads_script(html, "litert_embeddings.js", module=True):
            fail(
                f"{rel(index)} does not load litert_embeddings.js as "
                '<script type="module">'
            )

    # Per CALL SITE, not per file: a "switch engines" path added next to a
    # compliant one must not inherit its argument.
    for path, code in sources.items():
        for match in INITIALIZE_CALL.finditer(code):
            if not STREAMING_ARG.search(call_arguments(code, match.end() - 1)):
                line = code.count("\n", 0, match.start()) + 1
                fail(
                    f"{rel(path)}:{line} calls FlutterEdgeAi.initialize without "
                    "webStorageMode: WebStorageMode.streaming"
                )


def main(argv: list[str]) -> int:
    global root
    root = Path(argv[1]).resolve() if len(argv) > 1 else Path.cwd()
    apps = [
        p.parent
        for p in sorted(root.glob("codelabs/*/*/pubspec.yaml"))
        if not p.parent.name.startswith("_")
    ]

    # Fail closed, the way discovery does in check_codelabs.sh. A glob that
    # finds nothing must not read as "every app is fine".
    if not apps:
        print("::error::no codelab apps found — the web storage check cannot run")
        return 1

    for app in apps:
        before = len(errors)
        check_app(app)
        print(f"  {rel(app)}: {'ok' if len(errors) == before else 'PROBLEM'}")

    print(f"Checked web model storage in {len(apps)} app(s); {len(errors)} problem(s).")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
