#!/usr/bin/env python3
"""Every symbol an Android library imports must be reachable through its own
DT_NEEDED chain.

Bionic gives each library its own namespace view: an undefined symbol resolves
only against the libraries in that library's NEEDED closure, never against
whatever else happens to be loaded in the process. A GLOBAL import that misses
fails dlopen. A WEAK one does not fail anything — it binds to NULL, dlopen
succeeds, and the process jumps to address 0 the first time a code path calls
it. That is #545: the v0.17.0 OpenCL accelerator imports AHardwareBuffer_*
weakly without libandroid.so, and only Mali GPUs take the path that calls it.
#270 was the same rule broken by a sampler importing LiteRtCreateEnvironment
without libLiteRtLm.so.

For every aarch64 ELF in <bundle_dir>, each UND symbol is looked up in the NDK
platform stubs and in the bundle's own exports. If it has a provider and no
provider is in the library's NEEDED closure, that is a FAIL. Symbols with no
known provider are not ours to judge (absl leak-check hooks, gcov, …).

Every NEEDED entry must itself be loadable: in the bundle, an NDK platform
library, or a vendor library the plugin manifest requests. A NEEDED library
that is none of those fails dlopen outright — and the symbol check above cannot
see it, because the missing library's exports are unknown to it. That is how
three Dawn-dependent accelerators shipped unloadable from native-v0.14.0 to
v0.17.x: their libwebgpu_dawn.so was never in the bundle.

Usage: check_android_needed.py <bundle_dir>
NDK: $ANDROID_NDK_HOME / $ANDROID_NDK_ROOT, else the newest ndk/* under
$ANDROID_HOME, $ANDROID_SDK_ROOT, ~/Library/Android/sdk or ~/Android/Sdk.
"""
import glob
import os
import re
import subprocess
import sys

EM_AARCH64 = 183
# On a device libGLESv3.so is a symlink to libGLESv2.so; the NDK stubs split
# the GLES 3 entry points out. Needing either one reaches both.
ALIAS = {"libGLESv3.so": "libGLESv2.so"}
# Platform libraries whose own NEEDED the stubs do not record. AHardwareBuffer
# lives in libnativewindow, which libandroid links — needing libandroid reaches
# it, and that is exactly how upstream fixed #545.
PLATFORM_NEEDED = {"libandroid.so": ["libnativewindow.so"]}
# Vendor libraries that come from /vendor, not the NDK stubs, and that the core
# plugin's AndroidManifest.xml requests with <uses-native-library>.
VENDOR = {"libcdsprpc.so", "libOpenCL.so", "libOpenCL-car.so",
          "libOpenCL-pixel.so", "libvndksupport.so"}


def norm(lib):
    return ALIAS.get(lib, lib)


def find_ndk():
    for var in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        if os.environ.get(var) and os.path.isdir(os.environ[var]):
            return os.environ[var]
    roots = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
             os.path.expanduser("~/Library/Android/sdk"),
             os.path.expanduser("~/Android/Sdk")]
    found = []
    for r in filter(None, roots):
        found += glob.glob(os.path.join(r, "ndk", "*"))
    if not found:
        return None
    key = lambda p: [int(x) for x in re.findall(r"\d+", os.path.basename(p))]
    return sorted(found, key=key)[-1]


def die(msg):
    # A check that cannot read its input must not pass.
    print(f"  [FAIL] {msg}")
    sys.exit(1)


if len(sys.argv) != 2:
    sys.exit(__doc__)
bundle = sys.argv[1]
ndk = find_ndk() or die("no Android NDK found — set ANDROID_NDK_HOME")
tc = (glob.glob(os.path.join(ndk, "toolchains/llvm/prebuilt/*/")) or [None])[0]
tc or die(f"{ndk} has no llvm toolchain")
readelf, nm = tc + "bin/llvm-readelf", tc + "bin/llvm-nm"
apis = glob.glob(tc + "sysroot/usr/lib/aarch64-linux-android/[0-9]*")
apis or die(f"{ndk} has no aarch64 platform stubs")
stubs = max(apis, key=lambda p: int(os.path.basename(p)))


def run(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    if r.returncode:
        die(f"{os.path.basename(a[0])} failed on {a[-1]}: {r.stderr.strip()[:200]}")
    return r.stdout


def exports(p):
    return {l.split()[-1].split("@")[0]
            for l in run(nm, "-D", "--defined-only", p).splitlines() if l.strip()}


def needed(p):
    # Basenames: providers are keyed by file name, and Android loads jniLibs by
    # name from one flat directory anyway.
    return [os.path.basename(n) for n in
            re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", run(readelf, "-d", p))]


def imports(p):
    out = []
    for l in run(readelf, "--dyn-syms", "-W", p).splitlines():
        f = l.split()
        if len(f) >= 8 and f[6] == "UND" and f[4] in ("WEAK", "GLOBAL"):
            out.append((f[4], f[7].split("@")[0]))
    return out


def is_aarch64(p):
    with open(p, "rb") as fh:
        h = fh.read(20)
    return h[:4] == b"\x7fELF" and int.from_bytes(h[18:20], "little") == EM_AARCH64


providers = {}
platform = set()
for s in glob.glob(os.path.join(stubs, "*.so")):
    with open(s, "rb") as fh:
        if fh.read(4) != b"\x7fELF":
            continue                  # libc++.so is a linker script, not a stub
    platform.add(norm(os.path.basename(s)))
    for sym in exports(s):
        providers.setdefault(sym, set()).add(norm(os.path.basename(s)))
# Skel blobs are Hexagon DSP images, not aarch64 — they never meet bionic.
# Android loads jniLibs from one flat lib/<abi>/ directory, so a library in a
# subdirectory is a packing error — and one this check would otherwise skip.
nested = [p for p in glob.glob(os.path.join(bundle, "**", "*.so"), recursive=True)
          if os.path.normpath(os.path.dirname(p)) != os.path.normpath(bundle)]
if nested:
    die("libraries outside the bundle's top level, which Android never loads: "
        + ", ".join(sorted(os.path.relpath(p, bundle) for p in nested)))
libs = [p for p in sorted(glob.glob(os.path.join(bundle, "*.so"))) if is_aarch64(p)]
libs or die(f"no aarch64 libraries in {bundle} — wrong path, nothing was checked")
for p in libs:
    for sym in exports(p):
        providers.setdefault(sym, set()).add(os.path.basename(p))


def closure(p):
    seen, todo = set(), list(needed(p))
    while todo:
        lib = norm(todo.pop())
        if lib in seen:
            continue
        seen.add(lib)
        own = os.path.join(bundle, lib)
        todo += needed(own) if os.path.exists(own) else PLATFORM_NEEDED.get(lib, [])
    return seen


fail = 0
for p in libs:
    name = os.path.basename(p)
    absent = [n for n in needed(p)
              if not os.path.exists(os.path.join(bundle, n))
              and norm(n) not in platform and n not in VENDOR]
    if absent:
        print(f"  [FAIL] {name}: NEEDED {', '.join(absent)} — neither in the bundle "
              f"nor a platform or manifest-requested vendor library (dlopen fails)")
        fail = 1
for p in libs:
    name, reach = os.path.basename(p), closure(p)
    missing = {}
    for bind, sym in imports(p):
        prov = providers.get(sym)
        if prov and not (prov & reach) and name not in prov:
            missing.setdefault((bind, tuple(sorted(prov))), []).append(sym)
    for (bind, prov), syms in sorted(missing.items()):
        what = "binds to NULL, crashes when called" if bind == "WEAK" else "dlopen fails"
        print(f"  [FAIL] {name}: {bind} {', '.join(sorted(syms))} — provided by "
              f"{', '.join(prov)}, none in its NEEDED ({what})")
        fail = 1
print(f"  [{'FAIL' if fail else 'ok'}]   {len(libs)} aarch64 librar"
      f"{'y' if len(libs) == 1 else 'ies'} checked against API {os.path.basename(stubs)} stubs")
sys.exit(fail)
