#!/usr/bin/env python3
"""The LiteRT-LM runtime gate: the runtime side imports neither Flutter nor
core, nor anything outside itself.

usage: check_litertlm_runtime_gate.py <lib dir> <package name> <runtime dir>...

<lib dir> is a package's lib/; a file under lib/src/<runtime dir>/ is on the
runtime side. Every import, export and part directive of a runtime file is
read, wherever its URIs sit: the conditional branches (`if (dart.library.x)
'...'`), double quotes, a directive over several lines, `part of`. A
violation is:
  - dart:ui, package:flutter*, package:path_provider* (Flutter, its
    plugins, and flutter_edge_ai*: core and its satellites);
  - a URI of this package, relative or package:<name>/, that resolves outside
    the runtime side.
Exits 1 on a violation, on a missing lib dir, or when no runtime file was
found: a gate that examined nothing is not a pass.
"""
import os
import re
import sys

DIRECTIVE = re.compile(r"\b(import|export|part(?:\s+of)?)\b(.*?);", re.S)
URI = re.compile(r"""(['"])([^'"]+)\1""")
FORBIDDEN = re.compile(r"^(dart:ui$|package:flutter|package:path_provider)")


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    lib, package, runtime_dirs = argv[1], argv[2], argv[3:]
    src = os.path.join(lib, "src")
    if not os.path.isdir(lib):
        print(f"::error::runtime gate: no such directory {lib}")
        return 1

    def on_runtime_side(path):
        rel = os.path.relpath(path, src)
        return not rel.startswith("..") and rel.split(os.sep)[0] in runtime_dirs

    violations = []
    files = 0
    for root, _, names in os.walk(src):
        for name in names:
            if not name.endswith(".dart"):
                continue
            path = os.path.join(root, name)
            if not on_runtime_side(path):
                continue
            files += 1
            text = strip_comments(open(path, encoding="utf-8").read())
            for directive in DIRECTIVE.finditer(text):
                for match in URI.finditer(directive.group(2)):
                    uri = match.group(2)
                    rel = os.path.relpath(path, lib)
                    target = None
                    if uri.startswith(f"package:{package}/"):
                        target = os.path.join(lib, uri[len(f"package:{package}/"):])
                    elif FORBIDDEN.match(uri):
                        violations.append(f"{rel}: {uri} (Flutter or core)")
                        continue
                    elif ":" not in uri:
                        target = os.path.normpath(os.path.join(os.path.dirname(path), uri))
                    if target is not None and not on_runtime_side(target):
                        violations.append(
                            f"{rel}: {uri} is outside the runtime side"
                        )
    for v in violations:
        print(f"[runtime] {v}")
    print(f"runtime gate: {files} runtime file(s), {len(violations)} violation(s)")
    if files == 0:
        print("::error::runtime gate: no runtime file found; a check that "
              "examined nothing is not a pass")
        return 1
    if violations:
        print("::error::runtime gate: the runtime side imports Flutter, core or "
              "a file outside it")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
