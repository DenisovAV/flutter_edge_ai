#!/usr/bin/env python3
"""Regenerate packages/flutter_edge_ai_litertlm/NOTICES.

Flutter's LicenseCollector reads a package's NOTICES in place of its LICENSE
and folds every entry into each consuming app's licence page, so this file is
how an app that ships our native bundles carries the notices of the code in
them. Rerun it whenever a pin below moves (the build-native skill's bump list
says when):

    python3 -I native/litert_lm/build_notices.py

Every source is read straight out of the published archive it ships in, by
HTTP range requests, so only the licence entries are transferred — not the
200 MB OpenVINO zip or the 20 MB LiteRT-LM AAR around them.

Format (flutter_tools/lib/src/license_collector.dart): entries separated by a
line of exactly 80 hyphens; each entry is the component names one per line, a
blank line, then the text. A line of 80 hyphens INSIDE a text would split it
into fragments whose first paragraph is read as package names, so those lines
are shortened by one hyphen. That is the only change made to any text.
"""

import hashlib
import io
import os
import sys
import urllib.request
import zipfile

# LiteRT-LM tag the native bundles are built from (build_*.sh DEFAULT_REF).
LITERTLM_REF = "b2f686e2ed4718fb84ec398a61dd59ca0f0aff27"  # v0.18.0
# Google's Android library for the same LiteRT-LM release: its
# THIRD_PARTY_NOTICE.txt is Google's own list for the code the runtime links.
LITERTLM_AAR = (
    "https://dl.google.com/android/maven2/com/google/ai/edge/litertlm/"
    "litertlm-android/0.18.0/litertlm-android-0.18.0.aar"
)
# Windows bundle: DXC runtime (build-litertlm-native*.yml $dxcVer).
DXC_ZIP = (
    "https://github.com/microsoft/DirectXShaderCompiler/releases/download/"
    "v1.9.2602/dxc_2026_02_20.zip"
)
# Windows bundle: OpenVINO + oneTBB, the build LiteRT pins in
# third_party/intel_openvino/openvino_version.bzl at the LiteRT ref.
OPENVINO_ZIP = (
    "https://storage.openvinotoolkit.org/repositories/openvino/packages/"
    "2026.3.1/windows/"
    "openvino_toolkit_windows_2026.3.1.22476.56d9685302d_x86_64.zip"
)
OPENVINO_ROOT = "openvino_toolkit_windows_2026.3.1.22476.56d9685302d_x86_64/"
# Android opt-in: what the hook fetches (lib/src/hook/qnn_runtime.dart).
QNN_AAR = (
    "https://repo1.maven.org/maven2/com/qualcomm/qti/qnn-runtime/2.50.0/"
    "qnn-runtime-2.50.0.aar"
)

SEPARATOR = "-" * 80
HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = os.path.normpath(os.path.join(HERE, "..", ".."))


class _HttpRange(io.RawIOBase):
    """A seekable read-only view of a URL, one range request per read."""

    def __init__(self, url):
        self.url = url
        self.pos = 0
        head = urllib.request.urlopen(
            urllib.request.Request(url, method="HEAD"), timeout=60)
        self.size = int(head.headers["Content-Length"])

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        base = {0: 0, 1: self.pos, 2: self.size}[whence]
        self.pos = base + offset
        return self.pos

    def readinto(self, buf):
        if self.pos >= self.size:
            return 0
        end = min(self.pos + len(buf), self.size) - 1
        req = urllib.request.Request(
            self.url, headers={"Range": f"bytes={self.pos}-{end}"})
        with urllib.request.urlopen(req, timeout=60) as r:
            if r.status != 206:
                raise IOError(f"{self.url}: server ignored Range (HTTP {r.status})")
            data = r.read()
        buf[: len(data)] = data
        self.pos += len(data)
        return len(data)


def _zip_members(url, names):
    z = zipfile.ZipFile(io.BufferedReader(_HttpRange(url), buffer_size=1 << 20))
    out = {}
    for name in names:
        data = z.read(name)  # KeyError names the missing member
        print(f"  {hashlib.sha256(data).hexdigest()[:16]}  {len(data):>8}  {name}",
              file=sys.stderr)
        out[name] = data
    return out


def _fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    print(f"  {hashlib.sha256(data).hexdigest()[:16]}  {len(data):>8}  {url}",
          file=sys.stderr)
    return data


def _text(data):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        # onetbb_third-party-programs.txt carries one Latin-1 byte
        # ("Universit\xe9 Bordeaux").
        text = data.decode("cp1252")
    text = text.lstrip("﻿").replace("\r\n", "\n").replace("\r", "\n")
    lines = [("-" * 79 if line == SEPARATOR else line) for line in text.split("\n")]
    return "\n".join(lines).strip("\n")


def _entry(names, *parts):
    for name in names:
        assert name and "\n" not in name, name
    body = "\n\n".join(p.strip("\n") for p in parts)
    assert body and not body.startswith("\n"), names
    return "\n".join(names) + "\n\n" + body


def _section(title, data):
    return f"==== {title} ====\n\n{_text(data)}"


def main():
    print("Fetching licence sources:", file=sys.stderr)
    own = open(os.path.join(PACKAGE, "LICENSE"), "rb").read()
    litert = _fetch(
        "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/"
        f"{LITERTLM_REF}/LICENSE")
    google = _zip_members(LITERTLM_AAR, ["THIRD_PARTY_NOTICE.txt"])
    dxc = _zip_members(DXC_ZIP, ["LICENSE-MS.txt", "LICENSE-LLVM.txt", "LICENSE-MIT.txt"])
    ov = _zip_members(OPENVINO_ZIP, [
        OPENVINO_ROOT + "docs/licensing/EULA.txt",
        OPENVINO_ROOT + "docs/licensing/redist.txt",
        OPENVINO_ROOT + "docs/licensing/runtime-third-party-programs.txt",
        OPENVINO_ROOT + "runtime/3rdparty/tbb/TBB-LICENSE",
        OPENVINO_ROOT + "docs/licensing/onetbb_third-party-programs.txt",
    ])
    qnn = _zip_members(QNN_AAR, ["NOTICE.txt"])
    lic = OPENVINO_ROOT + "docs/licensing/"

    entries = [
        _entry(["flutter_edge_ai_litertlm"], _text(own)),
        _entry(["LiteRT", "LiteRT-LM"], _text(litert)),
        _entry(
            ["LiteRT-LM third-party components"],
            "The native LiteRT-LM runtime this package bundles statically "
            "links third-party code. The notices below are the ones Google "
            "publishes for the same release (THIRD_PARTY_NOTICE.txt in "
            "com.google.ai.edge.litertlm:litertlm-android:0.18.0, built from "
            "LiteRT-LM v0.18.0). They may name components that a given "
            "platform's build does not contain.",
            _text(google["THIRD_PARTY_NOTICE.txt"]),
        ),
        _entry(
            ["DirectX Shader Compiler"],
            "dxcompiler.dll and dxil.dll in the Windows bundle come unmodified "
            "from microsoft/DirectXShaderCompiler release v1.9.2602 "
            "(dxc_2026_02_20.zip), which carries the three licence files "
            "below.",
            _section("LICENSE-MS.txt", dxc["LICENSE-MS.txt"]),
            _section("LICENSE-LLVM.txt", dxc["LICENSE-LLVM.txt"]),
            _section("LICENSE-MIT.txt", dxc["LICENSE-MIT.txt"]),
        ),
        _entry(
            ["OpenVINO"],
            "The openvino*.dll libraries in the Windows bundle (the Intel NPU "
            "path) are Redistributables of the Intel Distribution of OpenVINO "
            "toolkit 2026.3.1, unmodified, and are licensed under the Intel "
            "OpenVINO Distribution License below. Their third-party programs "
            "follow it.",
            _section("EULA.txt", ov[lic + "EULA.txt"]),
            _section("redist.txt", ov[lic + "redist.txt"]),
            _section("runtime-third-party-programs.txt",
                     ov[lic + "runtime-third-party-programs.txt"]),
        ),
        _entry(
            ["oneTBB"],
            "The tbb*.dll libraries in the Windows bundle come unmodified from "
            "the same OpenVINO 2026.3.1 distribution.",
            _section("TBB-LICENSE", ov[OPENVINO_ROOT + "runtime/3rdparty/tbb/TBB-LICENSE"]),
            _section("onetbb_third-party-programs.txt",
                     ov[lic + "onetbb_third-party-programs.txt"]),
        ),
        _entry(
            ["Qualcomm AI Engine Direct (QNN) runtime"],
            "Applies only to Android apps built with `qualcomm_npu: true` in "
            "their pubspec's hooks: user_defines. The build hook of such an "
            "app fetches com.qualcomm.qti:qnn-runtime:2.50.0 from Maven "
            "Central and bundles its QNN libraries into the app. Those "
            "libraries are licensed by Qualcomm Technologies, Inc. under the "
            "AI Stack License, LICENSE.pdf in that artifact, which the hook "
            "copies next to the libraries in its cache and which is not "
            "reproduced here. The notices Qualcomm ships with them "
            "(NOTICE.txt in the same artifact) follow.",
            _text(qnn["NOTICE.txt"]),
        ),
    ]

    joined = ("\n" + SEPARATOR + "\n").join(entries) + "\n"
    # The property the whole file exists for: splitting it the way
    # flutter_tools does yields exactly these entries.
    assert len(joined.split("\n" + SEPARATOR + "\n")) == len(entries)
    path = os.path.join(PACKAGE, "NOTICES")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(joined)
    print(f"Wrote {path}: {len(entries)} entries, {len(joined.encode())} bytes",
          file=sys.stderr)


if __name__ == "__main__":
    main()
