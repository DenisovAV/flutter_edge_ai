#!/usr/bin/env python3
"""Fetch the slice of the QAIRT SDK the Qualcomm dispatch build needs.

The dispatch compiles against QAIRT's headers only (@qairt//:qnn_lib_headers in
LiteRT's dispatch BUILD), but LiteRT's repository rule downloads the whole SDK
zip — 2.6 GB, ~6 GB unpacked, more than a hosted arm64 runner can spare beside
a Bazel build of LiteRT. This reads the zip's central directory and the wanted
entries with HTTP range requests (~5 MB) and writes them out as an SDK root
that LITERT_QAIRT_SDK can point at:

  include/QNN/**                 what the dispatch compiles against
  sdk.yaml                       build_qualcomm_dispatch.sh checks its version
  lib/<host>/libQnnHtp.so        so the script's SDK check finds a real host
  lib/<host>/libQnnSystem.so     directory, not a stand-in
  LICENSE.pdf                    Qualcomm's licence for the headers

Usage: fetch_qairt_sdk_slim.py <out-dir> [--host aarch64-oe-linux-gcc11.2]

The URL, build and archive size are LiteRT's pin at the v0.18.0 LiteRT commit
(third_party/qairt/workspace.bzl) and the hook's (lib/src/hook/qairt_linux.dart).
A different total size in a range answer means a different file, and stops.

Integrity: the dispatch we ship is compiled from these headers, so a tampered
header would reach every app. Size, CRC32 and the archive length catch a wrong
file, not a forged one, so the whole slice is pinned: SLICE_SHA256 is the
SHA-256 of its sorted `sha256sum` listing (`<hash>  <path>` per file). The
slice is checked in memory and nothing is written unless it matches.
"""

import hashlib
import os
import re
import struct
import sys
import urllib.request
import zlib

BUILD = "2.50.0.260828"
URL = ("https://softwarecenter.qualcomm.com/api/download/software/sdks/"
       f"Qualcomm_AI_Runtime_Community/All/{BUILD}/v{BUILD}.zip")
LENGTH = 2601473189
ROOT = f"qairt/{BUILD}/"
# 216 headers + sdk.yaml + LICENSE.pdf + the two host libraries; the libraries
# are the same bytes the hook pins (lib/src/hook/qairt_linux.dart).
SLICE_FILES = 220
SLICE_SHA256 = "1f77a3a5012fe27802dec528f97903f85fad838a47895c5445814eef9cf90617"


def ranged(url, start, end):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        if resp.status != 206:
            sys.exit(f"ERROR: HTTP {resp.status} for a range request — "
                     "the server does not serve byte ranges")
        want = f"bytes {start}-{end}/{LENGTH}"
        got = resp.headers.get("Content-Range")
        if got != want:
            sys.exit(f"ERROR: Content-Range {got!r}, expected {want!r} — "
                     "not the pinned QAIRT zip")
        data = resp.read()
        final = resp.geturl()
    if len(data) != end - start + 1:
        sys.exit(f"ERROR: got {len(data)} of {end - start + 1} bytes")
    return data, final


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    out = args[0]
    host = "aarch64-oe-linux-gcc11.2"
    if "--host" in args:
        host = args[args.index("--host") + 1]
    wanted = re.compile(
        rf"^{re.escape(ROOT)}(include/QNN/.+\.h|sdk\.yaml|LICENSE\.pdf|"
        rf"lib/{re.escape(host)}/lib(QnnHtp|QnnSystem)\.so)$")

    tail, url = ranged(URL, LENGTH - 65557, LENGTH - 1)  # follows the redirect once
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        sys.exit("ERROR: no end-of-central-directory record")
    _, _, _, _, count, cd_size, cd_off, _ = struct.unpack("<IHHHHIIH", tail[i:i + 22])
    if count == 0xFFFF or cd_off == 0xFFFFFFFF:
        sys.exit("ERROR: zip64 archive, not the pinned QAIRT zip")
    cd, _ = ranged(url, cd_off, cd_off + cd_size - 1)

    entries, p = [], 0
    while p < len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        method, crc, csize, usize = struct.unpack("<HxxxxIII", cd[p + 10:p + 28])
        nlen, xlen, clen = struct.unpack("<HHH", cd[p + 28:p + 34])
        local = struct.unpack("<I", cd[p + 42:p + 46])[0]
        name = cd[p + 46:p + 46 + nlen].decode()
        if wanted.match(name):
            entries.append((name, method, crc, csize, usize, local))
        p += 46 + nlen + xlen + clen

    names = {e[0] for e in entries}
    for must in (f"{ROOT}sdk.yaml", f"{ROOT}lib/{host}/libQnnHtp.so",
                 f"{ROOT}include/QNN/QnnInterface.h"):
        if must not in names:
            sys.exit(f"ERROR: {must} is not in the zip")

    # Entries next to each other in the zip (the headers are) are read as one
    # range: the gateway is slow per request, and ~150 headers one by one take
    # minutes. A cluster ends where the next wanted entry is more than GAP away.
    GAP = 4 << 20
    entries.sort(key=lambda e: e[5])
    clusters, cur = [], []
    for e in entries:
        if cur and e[5] - (cur[-1][5] + 30 + 1024 + cur[-1][3]) > GAP:
            clusters.append(cur)
            cur = []
        cur.append(e)
    if cur:
        clusters.append(cur)

    total = 0
    files = {}
    for cluster in clusters:
        lo = cluster[0][5]
        last = cluster[-1]
        # Local headers repeat the name and may carry their own extra field;
        # 64 KB of slack covers any extra field a zip writer emits.
        hi = min(LENGTH - 1, last[5] + 30 + 65536 + last[3])
        blob, _ = ranged(url, lo, hi)
        total += len(blob)
        for name, method, crc, csize, usize, local in cluster:
            o = local - lo
            if blob[o:o + 4] != b"PK\x03\x04":
                sys.exit(f"ERROR: bad local header for {name}")
            nlen, xlen = struct.unpack("<HH", blob[o + 26:o + 30])
            start = o + 30 + nlen + xlen
            raw = blob[start:start + csize]
            if len(raw) != csize:
                sys.exit(f"ERROR: {name} runs past the range read")
            data = zlib.decompress(raw, -15) if method == 8 else raw
            if len(data) != usize or (zlib.crc32(data) & 0xFFFFFFFF) != crc:
                sys.exit(f"ERROR: {name} failed its size/CRC check")
            files[name[len(ROOT):]] = data
    listing = "".join(f"{hashlib.sha256(files[rel]).hexdigest()}  {rel}\n"
                      for rel in sorted(files))
    digest = hashlib.sha256(listing.encode()).hexdigest()
    if len(files) != SLICE_FILES or digest != SLICE_SHA256:
        sys.exit(f"ERROR: the QAIRT slice is {len(files)} files with digest "
                 f"{digest}; pinned {SLICE_FILES} files, {SLICE_SHA256}. "
                 "Nothing was written.")
    for rel, data in files.items():
        dest = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
    headers = sum(1 for n in names if "/include/QNN/" in n)
    print(f"QAIRT {BUILD}: {len(entries)} files ({headers} headers), "
          f"{len(clusters)} ranges, {total / 1e6:.1f} MB read -> {out}")


if __name__ == "__main__":
    main()
