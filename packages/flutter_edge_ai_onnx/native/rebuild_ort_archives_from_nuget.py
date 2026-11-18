#!/usr/bin/env python3
"""Rebuild the ONNX Runtime / ORT-GenAI archives that vanished with
microsoft/onnxruntime and microsoft/onnxruntime-genai (2026-11-17) from the
official NuGet packages on api.nuget.org.

Each output archive holds Microsoft's signed library, unmodified, at the path
the original GitHub release archive used (so flutter_edge_ai_onnx's hook
extracts it with the same `extractedLibPath`), plus the package's LICENSE,
ThirdPartyNotices.txt and a SOURCE.txt naming the nupkg and its sha256.
The archive bytes are deterministic: fixed member order, mtime, uid/gid and
modes, and a gzip header without a timestamp.

  rebuild_ort_archives_from_nuget.py NUPKG_DIR OUT_DIR
"""
import gzip
import hashlib
import io
import os
import sys
import tarfile
import zipfile

MTIME = 1767225600  # 2026-01-01T00:00:00Z

ORT = 'Microsoft.ML.OnnxRuntime'
GENAI = 'Microsoft.ML.OnnxRuntimeGenAI'

# (output name, package id, version, rid, library in the nupkg, path in the archive)
TARGETS = [
    ('onnxruntime-linux-x64-1.27.0-nuget.tgz', ORT, '1.27.0', 'linux-x64',
     'libonnxruntime.so', 'onnxruntime-linux-x64-1.27.0/lib/libonnxruntime.so.1.27.0'),
    ('onnxruntime-win-arm64-1.27.0-nuget.zip', ORT, '1.27.0', 'win-arm64',
     'onnxruntime.dll', 'onnxruntime-win-arm64-1.27.0/lib/onnxruntime.dll'),
    ('onnxruntime-osx-arm64-1.32.0-nuget.tgz', ORT, '1.32.0', 'osx-arm64',
     'libonnxruntime.dylib', 'onnxruntime-osx-arm64-1.32.0/lib/libonnxruntime.1.32.0.dylib'),
    ('onnxruntime-linux-x64-1.32.0-nuget.tgz', ORT, '1.32.0', 'linux-x64',
     'libonnxruntime.so', 'onnxruntime-linux-x64-1.32.0/lib/libonnxruntime.so.1.32.0'),
    ('onnxruntime-win-arm64-1.32.0-nuget.zip', ORT, '1.32.0', 'win-arm64',
     'onnxruntime.dll', 'onnxruntime-win-arm64-1.32.0/lib/onnxruntime.dll'),
    ('onnxruntime-genai-0.20.0-osx-arm64-nuget.tar.gz', GENAI, '0.20.0', 'osx-arm64',
     'libonnxruntime-genai.dylib', 'onnxruntime-genai-0.20.0-osx-arm64/lib/libonnxruntime-genai.dylib'),
    ('onnxruntime-genai-0.20.0-linux-x64-nuget.tar.gz', GENAI, '0.20.0', 'linux-x64',
     'libonnxruntime-genai.so', 'onnxruntime-genai-0.20.0-linux-x64/lib/libonnxruntime-genai.so'),
    ('onnxruntime-genai-0.20.0-win-arm64-nuget.zip', GENAI, '0.20.0', 'win-arm64',
     'onnxruntime-genai.dll', 'onnxruntime-genai-0.20.0-win-arm64/lib/onnxruntime-genai.dll'),
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def members(nupkg_path, pkg, version, rid, lib, path):
    raw = open(nupkg_path, 'rb').read()
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        library = z.read(f'runtimes/{rid}/native/{lib}')
        license_ = z.read('LICENSE')
        notices = z.read('ThirdPartyNotices.txt')
    root = path.split('/')[0]
    source = (
        f'{path.split("/")[-1]} in this archive is {lib} from the official NuGet package\n'
        f'{pkg} {version} (runtimes/{rid}/native/{lib}), unmodified:\n'
        f'  https://api.nuget.org/v3-flatcontainer/{pkg.lower()}/{version}/{pkg.lower()}.{version}.nupkg\n'
        f'  nupkg sha256 {sha256(raw)}\n'
        f'  library sha256 {sha256(library)}\n'
        f'Microsoft\'s GitHub release archive with this name is no longer available\n'
        f'(github.com/microsoft/onnxruntime and onnxruntime-genai return 404 since\n'
        f'2026-11-17). Rebuilt by flutter_edge_ai for its build hook. MIT, see LICENSE.\n'
    ).encode()
    return [
        (f'{root}/LICENSE', license_, 0o644),
        (f'{root}/SOURCE.txt', source, 0o644),
        (f'{root}/ThirdPartyNotices.txt', notices, 0o644),
        (path, library, 0o755),
    ]


def write_tgz(out, entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.PAX_FORMAT) as t:
        dirs = sorted({'/'.join(p.split('/')[:i]) for p, _, _ in entries
                       for i in range(1, len(p.split('/')))})
        for d in dirs:
            ti = tarfile.TarInfo(d)
            ti.type = tarfile.DIRTYPE
            ti.mode, ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = 0o755, MTIME, 0, 0, '', ''
            t.addfile(ti)
        for p, data, mode in sorted(entries):
            ti = tarfile.TarInfo(p)
            ti.size, ti.mode, ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = (
                len(data), mode, MTIME, 0, 0, '', '')
            t.addfile(ti, io.BytesIO(data))
    with open(out, 'wb') as f, gzip.GzipFile(fileobj=f, mode='wb', mtime=0, filename='') as g:
        g.write(buf.getvalue())


def write_zip(out, entries):
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for p, data, mode in sorted(entries):
            zi = zipfile.ZipInfo(p, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (0o100000 | mode) << 16
            z.writestr(zi, data)


def main():
    nupkg_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    for name, pkg, version, rid, lib, path in TARGETS:
        nupkg = os.path.join(nupkg_dir, f'{pkg.lower()}.{version}.nupkg')
        entries = members(nupkg, pkg, version, rid, lib, path)
        out = os.path.join(out_dir, name)
        (write_zip if name.endswith('.zip') else write_tgz)(out, entries)
        print(sha256(open(out, 'rb').read()), name)


if __name__ == '__main__':
    main()
