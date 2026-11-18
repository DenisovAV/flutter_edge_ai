#!/usr/bin/env python3
"""Release layout for libany_shim (tag native-any-v<version>).

  release.py pack <out_dir> <release_dir> <target>...
      out_dir/<target>/<lib> (build.sh output) -> release_dir/
      any-shim-<target>.tar.gz, the library alone at the archive root.
      Deterministic: entries sorted, mtime 0, uid/gid 0, mode 0644, gzip
      header mtime 0, so one build gives one sha256 on every host.

  release.py manifest <release_dir> <version>
      Writes checksums_any_shim.txt (`<sha256>  <archive>`, the format
      `shasum -a 256 -c` reads) and manifest.json (per target: archive,
      archive size and sha256, library name, size and sha256).

  release.py verify <release_dir> <version> [--hook <hook/build.dart>]
      Every archive matches checksums_any_shim.txt and manifest.json, holds
      exactly its library under the expected name, and that library passes
      check_exports.py for its target. With --hook, the hook's _bundleVersion
      is <version> and its _checksums map equals the checksums file (an empty
      map is allowed only before the release: it is reported, not failed).

The published tag must never change: a rebuild goes out under a new
version with a letter suffix (0.1.0-a), never by re-uploading assets.
"""
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
TARGETS = {
    "android_arm64": "libany_shim.so",
    "ios_arm64": "libany_shim.dylib",
    "ios_sim_arm64": "libany_shim.dylib",
    "macos_arm64": "libany_shim.dylib",
    "linux_x86_64": "libany_shim.so",
    "linux_arm64": "libany_shim.so",
    "windows_x86_64": "any_shim.dll",
}
CHECKSUMS = "checksums_any_shim.txt"
MANIFEST = "manifest.json"


def archive_name(target):
    return f"any-shim-{target}.tar.gz"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def pack(out_dir, release_dir, targets):
    os.makedirs(release_dir, exist_ok=True)
    for target in targets:
        lib = TARGETS[target]
        data = open(os.path.join(out_dir, target, lib), "rb").read()
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            info = tarfile.TarInfo(lib)
            info.size, info.mtime, info.mode = len(data), 0, 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            tar.addfile(info, io.BytesIO(data))
        gz = io.BytesIO()
        with gzip.GzipFile(filename="", mode="wb", fileobj=gz, mtime=0, compresslevel=9) as f:
            f.write(raw.getvalue())
        path = os.path.join(release_dir, archive_name(target))
        open(path, "wb").write(gz.getvalue())
        print(f"{archive_name(target)}  {len(gz.getvalue())} bytes  {sha256(gz.getvalue())}")


def read_archive(path, target):
    with tarfile.open(path, "r:gz") as tar:
        members = tar.getmembers()
        names = [m.name for m in members]
        if names != [TARGETS[target]] or not members[0].isfile():
            raise ValueError(f"{path} holds {names}, expected [{TARGETS[target]}]")
        return tar.extractfile(members[0]).read()


def manifest(release_dir, version):
    entries, lines = {}, []
    for target in sorted(TARGETS):
        path = os.path.join(release_dir, archive_name(target))
        if not os.path.exists(path):
            continue
        blob = open(path, "rb").read()
        lib = read_archive(path, target)
        entries[target] = {
            "archive": archive_name(target),
            "archiveBytes": len(blob),
            "archiveSha256": sha256(blob),
            "library": TARGETS[target],
            "libraryBytes": len(lib),
            "librarySha256": sha256(lib),
        }
        lines.append(f"{sha256(blob)}  {archive_name(target)}\n")
    if not entries:
        raise SystemExit(f"no archives in {release_dir}")
    open(os.path.join(release_dir, CHECKSUMS), "w").writelines(lines)
    json.dump(
        {"tag": f"native-any-v{version}", "version": version, "targets": entries},
        open(os.path.join(release_dir, MANIFEST), "w"),
        indent=2,
        sort_keys=True,
    )
    print(open(os.path.join(release_dir, CHECKSUMS)).read(), end="")


def hook_pins(hook_path):
    src = open(hook_path).read()
    version = re.search(r"const _bundleVersion = '([^']+)';", src).group(1)
    block = re.search(r"const Map<String, String> _checksums = \{(.*?)\};", src, re.S).group(1)
    pins = dict((a, s) for a, s in re.findall(r"'(any-shim-[a-z0-9_]+\.tar\.gz)':\s*'([0-9a-f]{64})'", block))
    return version, pins


def verify(release_dir, version, hook=None):
    problems = []
    sums = {}
    for line in open(os.path.join(release_dir, CHECKSUMS)):
        digest, name = line.split()
        sums[name] = digest
    man = json.load(open(os.path.join(release_dir, MANIFEST)))
    if man["version"] != version or man["tag"] != f"native-any-v{version}":
        problems.append(f"manifest says {man['tag']}, expected native-any-v{version}")
    if set(sums) != {e["archive"] for e in man["targets"].values()}:
        problems.append("checksums and manifest list different archives")
    for target, entry in sorted(man["targets"].items()):
        path = os.path.join(release_dir, entry["archive"])
        blob = open(path, "rb").read()
        if sha256(blob) != sums.get(entry["archive"]) or sha256(blob) != entry["archiveSha256"]:
            problems.append(f"{entry['archive']}: sha256 differs from the checksums/manifest")
            continue
        lib = read_archive(path, target)
        if sha256(lib) != entry["librarySha256"]:
            problems.append(f"{target}: library sha256 differs from the manifest")
        tmp = os.path.join(release_dir, f".verify-{target}-{TARGETS[target]}")
        open(tmp, "wb").write(lib)
        try:
            r = subprocess.run([sys.executable, os.path.join(HERE, "check_exports.py"), tmp, target],
                               capture_output=True, text=True)
            print(r.stdout, end="")
            if r.returncode != 0:
                problems.append(f"{target}: check_exports.py failed")
        finally:
            os.remove(tmp)
    if hook:
        hv, pins = hook_pins(hook)
        if hv != version:
            problems.append(f"hook pins version {hv}, release is {version}")
        if not pins:
            print(f"note: {hook} pins no checksums yet (expected before the upload)")
        elif pins != sums:
            problems.append(f"hook checksums differ from {CHECKSUMS}: hook {pins}, release {sums}")
    for p in problems:
        print(f"FAIL {p}")
    if not problems:
        print(f"ok   release {version}: {len(man['targets'])} targets verified")
    return 1 if problems else 0


def main(argv):
    if len(argv) >= 5 and argv[1] == "pack":
        pack(argv[2], argv[3], argv[4:])
        return 0
    if len(argv) == 4 and argv[1] == "manifest":
        manifest(argv[2], argv[3])
        return 0
    if len(argv) in (4, 6) and argv[1] == "verify":
        hook = argv[5] if len(argv) == 6 and argv[4] == "--hook" else None
        return verify(argv[2], argv[3], hook)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
