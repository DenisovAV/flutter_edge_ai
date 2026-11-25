#!/usr/bin/env python3
"""Link closure and symbol binding of a Linux native archive, on the bytes
that ship.

From LiteRT-LM v0.20.0 upstream's prebuilt/ carries no libLiteRt.so and no
GPU accelerator, so both are built here from LiteRT's source beside
libLiteRtLm.so; only the constraint provider and Dawn stay Google's. The Dart
client opens the bundle with dlopen(RTLD_LAZY | RTLD_GLOBAL) in the order of
`linuxGlobalLibraries` (lib/src/ffi/litert_lm_client.dart). Under lazy binding
an unresolved FUNCTION symbol does not fail the load: it surfaces at the first
call as ld.so's "symbol lookup error", which exits the process with no Dart
exception and no reason (review-linux B2). Nothing else in the build calls the
GPU, so this checks the property directly:

  1. every expected file is there, and is ELF;
  2. no DT_NEEDED holds a '/', and every DT_NEEDED is a file of the bundle or
     a system library from SYSTEM_LIBRARIES;
  3. a DT_SONAME, where present, equals the file name, and is present on the
     libraries other libraries NEED by name (SONAME_REQUIRED);
  4. RUNPATH is exactly $ORIGIN (patchelf, in the workflow);
  5. every non-weak undefined symbol is defined in the library's own NEEDED
     closure, or in a library loaded RTLD_GLOBAL before it (PRELOAD_ORDER);
     a symbol found only through the preload order is printed, not failed;
  6. no library needs a GLIBC, GLIBCXX or CXXABI version above the floor the
     workflow promises (Ubuntu 22.04: glibc 2.35, GCC 12's libstdc++);
  7. the accelerator exports LiteRtAcceleratorImpl and nothing else of its
     own (export_litert_gpu_accelerator_linux.lds).

System libraries are read from the machine running the check (ldconfig -p),
so run it on the runner that built the bundle, or one of the same release.

Usage: check_linux_bundle.py <artifact_dir>
Tools: $READELF (default readelf). Exit 1 on any failure.
"""
import os
import platform
import re
import subprocess
import sys

READELF = os.environ.get("READELF", "readelf")

# What the bundle must hold. libLiteRt.so and the accelerator are ours from
# v0.20.0 (built from LiteRT at the LiteRT-LM tag's pin); the provider and
# Dawn are Google's prebuilts from the tag.
EXPECTED = [
    "libLiteRtLm.so",
    "libStreamProxy.so",
    "libLiteRt.so",
    "libLiteRtWebGpuAccelerator.so",
    "libwebgpu_dawn.so",
    "libGemmaModelConstraintProvider.so",
]

# The order the Dart client dlopens with RTLD_GLOBAL (linuxGlobalLibraries in
# lib/src/ffi/litert_lm_client.dart). Keep the two equal.
PRELOAD_ORDER = [
    "libLiteRt.so",
    "libGemmaModelConstraintProvider.so",
    "libLiteRtWebGpuAccelerator.so",
    "libLiteRtLm.so",
]

# Libraries other libraries NEED by name: without a SONAME the NEEDED entry is
# whatever path the linker was given. Dawn has none (0.19.1 and 0.20.0 alike),
# which is why rule 2 refuses a NEEDED with a '/'.
SONAME_REQUIRED = [
    "libLiteRt.so",
    "libLiteRtWebGpuAccelerator.so",
    "libGemmaModelConstraintProvider.so",
]

# What any glibc system provides, plus GCC's C++ runtime (Ubuntu 22.04+,
# Debian 12+ ship both). Nothing else may be NEEDED: Vulkan, X11 and the GPU
# drivers are dlopened at run time, never linked.
SYSTEM_LIBRARIES = {
    "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1",
    "libstdc++.so.6", "libgcc_s.so.1",
    "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1",
}

# The floor the workflow promises: Ubuntu 22.04 (glibc 2.35, GCC 12).
CEILINGS = {"GLIBC": (2, 35), "GLIBCXX": (3, 4, 30), "CXXABI": (1, 3, 13)}

ACCELERATOR = "libLiteRtWebGpuAccelerator.so"
ACCELERATOR_EXPORTS = {"LiteRtAcceleratorImpl"}
# Defined by the linker, not by the code, and exported whatever the version
# script says: Google's own 0.19.1 accelerator exports __start_/__stop_ of
# google_malloc and malloc_hook beside LiteRtAcceleratorImpl.
LINKER_DEFINED = re.compile(r"^(__start_|__stop_)|^(_init|_fini|_edata|_end|__bss_start)$")

SYMBOL_LINE = re.compile(
    r"^\s*\d+:\s+[0-9a-fA-F]+\s+\S+\s+(\S+)\s+(\S+)\s+(\S+)\s+"
    r"(?:\[[^\]]*\]\s+)?(\S+)\s+(\S+)")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True,
                          text=True).stdout


class Elf:
    def __init__(self, path):
        self.path = path
        dyn = run(READELF, "-dW", path)
        self.needed = re.findall(r"\(NEEDED\)\s+Shared library: \[(.*?)\]", dyn)
        soname = re.findall(r"\(SONAME\)\s+Library soname: \[(.*?)\]", dyn)
        self.soname = soname[0] if soname else None
        self.runpath = re.findall(r"\((?:RUNPATH|RPATH)\)\s+Library r(?:un)?path: \[(.*?)\]", dyn)
        self.defined, self.undefined, self.exported = set(), set(), set()
        for line in run(READELF, "--dyn-syms", "-W", path).splitlines():
            m = SYMBOL_LINE.match(line)
            if not m:
                continue
            typ, bind, vis, ndx, name = m.groups()
            name = name.split("@")[0]
            if not name or typ in ("SECTION", "FILE"):
                continue
            if ndx == "UND":
                if bind == "GLOBAL":
                    self.undefined.add(name)
                continue
            if bind in ("GLOBAL", "WEAK", "UNIQUE") and vis in ("DEFAULT", "PROTECTED"):
                self.defined.add(name)
                if ndx != "ABS":
                    self.exported.add(name)
        versions = run(READELF, "-VW", path)
        needs = versions.split("Version needs section", 1)
        self.version_needs = set(re.findall(
            r"Name: ((?:GLIBC|GLIBCXX|CXXABI)_[0-9.]+)",
            needs[1] if len(needs) == 2 else ""))


def system_paths():
    """soname -> path for this machine's architecture, from ldconfig -p."""
    arch = {"x86_64": "x86-64", "aarch64": "AArch64"}[platform.machine()]
    out = run("/sbin/ldconfig", "-p")
    paths = {}
    for line in out.splitlines():
        m = re.match(r"\s+(\S+) \((.*?)\) => (\S+)", line)
        # Another architecture's copy (multiarch i386: flags "libc6") is not
        # what this bundle loads against.
        if m and arch in m.group(2) and m.group(1) not in paths:
            paths[m.group(1)] = m.group(3)
    return paths


def version_tuple(v):
    return tuple(int(x) for x in v.split("."))


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    root = argv[1]
    fail = False

    def bad(msg):
        nonlocal fail
        fail = True
        print(f"  [FAIL] {msg}")

    files = sorted(f for f in os.listdir(root) if f.endswith(".so"))
    for want in EXPECTED:
        if want not in files:
            bad(f"{want} is not in the bundle")
    for f in files:
        with open(os.path.join(root, f), "rb") as fh:
            if fh.read(4) != b"\x7fELF":
                bad(f"{f} is not an ELF file (git-lfs pointer?)")
    if fail:
        return 1

    libs = {f: Elf(os.path.join(root, f)) for f in files}
    sys_paths = system_paths()
    sys_elfs = {}

    def system_elf(name):
        if name not in sys_elfs:
            path = sys_paths.get(name)
            sys_elfs[name] = Elf(path) if path else None
        return sys_elfs[name]

    # 2 + 3 + 4 + 6, per library.
    for f, e in libs.items():
        for n in e.needed:
            if "/" in n:
                bad(f"{f} NEEDs a path, not a name: {n}")
            elif n not in libs and n not in SYSTEM_LIBRARIES:
                bad(f"{f} NEEDs {n}, which is neither shipped nor a system library")
            elif n not in libs and system_elf(n) is None:
                bad(f"{f} NEEDs {n}, which this machine does not have (ldconfig -p)")
        if e.soname is not None and e.soname != f:
            bad(f"{f} has SONAME {e.soname}; a NEEDED on it would not find the shipped file")
        if f in SONAME_REQUIRED and e.soname is None:
            bad(f"{f} has no SONAME")
        if e.runpath != ["$ORIGIN"]:
            bad(f"{f} RUNPATH is {e.runpath or 'unset'}, not exactly $ORIGIN")
        top = {}
        for v in e.version_needs:
            family, _, number = v.partition("_")
            if version_tuple(number) > top.get(family, (0,)):
                top[family] = version_tuple(number)
        for family, ceiling in CEILINGS.items():
            if family in top and top[family] > ceiling:
                bad(f"{f} needs {family}_{'.'.join(map(str, top[family]))}, above "
                    f"the {family}_{'.'.join(map(str, ceiling))} floor (Ubuntu 22.04)")
        shown = ", ".join(f"{k}_{'.'.join(map(str, v))}" for k, v in sorted(top.items()))
        print(f"    {f}: NEEDED [{', '.join(e.needed)}], SONAME {e.soname}, "
              f"max {shown or 'none'}")

    # 5. Symbol binding.
    def closure(name):
        seen, todo, out = set(), [name], []
        while todo:
            n = todo.pop()
            if n in seen:
                continue
            seen.add(n)
            elf = libs.get(n) or system_elf(n)
            if elf is None:
                continue
            out.append(elf)
            todo.extend(elf.needed)
        return out

    def provided(elfs):
        names = set()
        for elf in elfs:
            names |= elf.defined
        return names

    earlier = []
    for f in sorted(libs, key=lambda n: (PRELOAD_ORDER.index(n)
                                         if n in PRELOAD_ORDER else -1, n)):
        own = provided(closure(f))
        missing = sorted(libs[f].undefined - own)
        if f in PRELOAD_ORDER:
            via_preload = provided(c for p in earlier for c in closure(p))
            late = [s for s in missing if s in via_preload]
            missing = [s for s in missing if s not in via_preload]
            if late:
                print(f"  [info] {f}: {len(late)} symbol(s) resolve only through "
                      f"a library loaded RTLD_GLOBAL before it, not its NEEDED: "
                      f"{', '.join(late[:8])}{' …' if len(late) > 8 else ''}")
            earlier.append(f)
        if missing:
            bad(f"{f}: {len(missing)} undefined symbol(s) nothing in its NEEDED "
                f"closure or the preload order defines (a lazy-bound call would "
                f"kill the process): {', '.join(missing[:20])}"
                f"{' …' if len(missing) > 20 else ''}")
        else:
            print(f"  [ok]   {f}: every non-weak undefined symbol resolves")

    # 7. The accelerator's export surface.
    acc = libs.get(ACCELERATOR)
    if acc is not None:
        own = {s for s in acc.exported if not LINKER_DEFINED.match(s)}
        if not ACCELERATOR_EXPORTS <= own:
            bad(f"{ACCELERATOR} does not export {', '.join(sorted(ACCELERATOR_EXPORTS - own))}")
        extra = sorted(own - ACCELERATOR_EXPORTS)
        if extra:
            bad(f"{ACCELERATOR} exports {len(extra)} symbol(s) beyond "
                f"LiteRtAcceleratorImpl: {', '.join(extra[:20])}")
        else:
            print(f"  [ok]   {ACCELERATOR} exports only LiteRtAcceleratorImpl")
        dawn = "libwebgpu_dawn.so"
        print(f"  [info] {ACCELERATOR} {'NEEDs' if dawn in acc.needed else 'does not NEED'} {dawn}")

    # Two LiteRT runtimes in one process (review-linux m3): print the overlap.
    lm, rt = libs.get("libLiteRtLm.so"), libs.get("libLiteRt.so")
    if lm is not None and rt is not None:
        both = sorted(s for s in lm.exported & rt.exported if s.startswith("LiteRt"))
        print(f"  [info] LiteRt* exported by both libLiteRtLm.so and libLiteRt.so: "
              f"{len(both)}{': ' + ', '.join(both[:30]) if both else ''}"
              f"{' …' if len(both) > 30 else ''}")

    if fail:
        print("  Linux bundle check FAILED")
        return 1
    print("  Linux bundle check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
