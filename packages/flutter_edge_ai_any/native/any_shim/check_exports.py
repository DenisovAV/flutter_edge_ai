#!/usr/bin/env python3
"""Release gate for a libany_shim build: the library exports exactly the C
functions of include/any_shim.h (ANY_SHIM_EXPORTS, held equal to the header
by abi_test.go), and its container fits the target:

  android_arm64        ELF aarch64, every PT_LOAD aligned to >= 16 KB
                       (Google Play, Android 15+)
  ios_arm64            Mach-O arm64, LC_BUILD_VERSION platform iOS, minos 13.0
  ios_sim_arm64        Mach-O arm64, platform iOS simulator, minos 13.0
                       (Flutter's Native Assets framework wrapper says 13.0;
                       any other value is ITMS-90208)
  macos_arm64          Mach-O arm64, platform macOS
                       (every Mach-O: >= 4 KB of header room, so Native
                       Assets can rewrite the install name)
  linux_x86_64         ELF x86-64
  linux_arm64          ELF aarch64
  windows_x86_64       PE x86-64

Imports: Android and Linux libraries may need only the system libraries
listed in ANDROID_NEEDED / LINUX_NEEDED, and Linux at most GLIBC_MAX;
Windows must not import a MinGW runtime DLL; Apple only /usr/lib and
/System/Library.

Reads the bytes itself (ELF .dynsym, Mach-O LC_SYMTAB, PE export directory;
the parsers are copied from flutter_edge_ai_litertlm's
check_embedding_exports.py), so it needs no platform toolchain and checks
what ships.

Usage: check_exports.py <library> <target>
Exit 1 on any mismatch.
"""
import struct
import sys

ANY_SHIM_EXPORTS = [
    "any_shim_abi_version",
    "any_shim_account_cancel",
    "any_shim_account_close_start",
    "any_shim_account_info",
    "any_shim_account_open",
    "any_shim_account_release",
    "any_shim_changes_since",
    "any_shim_events_poll",
    "any_shim_file_attach",
    "any_shim_file_list",
    "any_shim_file_read_start",
    "any_shim_file_status",
    "any_shim_free",
    "any_shim_index_apply",
    "any_shim_index_bind",
    "any_shim_index_close",
    "any_shim_index_count",
    "any_shim_index_count_vectors",
    "any_shim_index_flush",
    "any_shim_index_get",
    "any_shim_index_info",
    "any_shim_index_knn",
    "any_shim_index_open",
    "any_shim_index_release",
    "any_shim_index_scan",
    "any_shim_index_text",
    "any_shim_new_device_key",
    "any_shim_new_mnemonic",
    "any_shim_object_delete",
    "any_shim_object_patch",
    "any_shim_object_read",
    "any_shim_object_set_body",
    "any_shim_object_sync_state",
    "any_shim_op_cancel",
    "any_shim_op_wait",
    "any_shim_rag_bundles",
    "any_shim_records_modify",
    "any_shim_records_read",
    "any_shim_set_local_discovery",
    "any_shim_space_create",
    "any_shim_space_list",
    "any_shim_space_list_sync_start",
    "any_shim_space_resolve_start",
    "any_shim_space_status",
    "any_shim_space_sync_heads_start",
    "any_shim_unwatch",
    "any_shim_version",
    "any_shim_watch_changes",
    "any_shim_watch_sync_status",
]


class FormatError(Exception):
    pass


def _cstr(data, offset):
    end = data.index(b"\0", offset)
    return data[offset:end].decode("utf-8", "replace")


def elf_exports(data):
    if data[4] != 2:
        raise FormatError("32-bit ELF is not a LiteRT-LM target")
    if data[5] != 1:
        raise FormatError("big-endian ELF is not a LiteRT-LM target")
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    sections = []
    for i in range(shnum):
        base = shoff + i * shentsize
        sh_type = struct.unpack_from("<I", data, base + 4)[0]
        sh_offset, sh_size = struct.unpack_from("<QQ", data, base + 0x18)
        sh_link = struct.unpack_from("<I", data, base + 0x28)[0]
        sh_entsize = struct.unpack_from("<Q", data, base + 0x38)[0]
        sections.append((sh_type, sh_offset, sh_size, sh_link, sh_entsize))
    names = set()
    found = False
    for sh_type, offset, size, link, entsize in sections:
        if sh_type != 11:  # SHT_DYNSYM
            continue
        found = True
        strtab = sections[link][1]
        for i in range(size // (entsize or 24)):
            sym = offset + i * (entsize or 24)
            st_name, st_info, _, st_shndx = struct.unpack_from("<IBBH", data, sym)
            binding = st_info >> 4
            if st_shndx != 0 and binding in (1, 2) and st_name:  # defined GLOBAL/WEAK
                names.add(_cstr(data, strtab + st_name))
    if not found:
        raise FormatError("no .dynsym section")
    return names


def _macho_thin_exports(data, base=0):
    magic = struct.unpack_from("<I", data, base)[0]
    if magic != 0xFEEDFACF:
        raise FormatError(f"not a 64-bit little-endian Mach-O (magic {magic:#x})")
    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    cmd_offset = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, cmd_offset)
        if cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, cmd_offset + 8)
            names = set()
            for i in range(nsyms):
                entry = base + symoff + i * 16
                n_strx, n_type = struct.unpack_from("<IB", data, entry)
                # N_EXT, defined in a section (N_SECT), not a debug entry.
                if n_type & 0xE0 == 0 and n_type & 0x01 and n_type & 0x0E == 0x0E:
                    name = _cstr(data, base + stroff + n_strx)
                    names.add(name[1:] if name.startswith("_") else name)
            return names
        cmd_offset += cmdsize
    raise FormatError("no LC_SYMTAB")


def macho_exports(data):
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):  # fat: every slice must export it
        nfat = struct.unpack_from(">I", data, 4)[0]
        wide = magic == 0xCAFEBABF
        slices = []
        for i in range(nfat):
            if wide:
                offset = struct.unpack_from(">Q", data, 8 + i * 32 + 8)[0]
            else:
                offset = struct.unpack_from(">I", data, 8 + i * 20 + 8)[0]
            slices.append(_macho_thin_exports(data, offset))
        return set.intersection(*slices) if slices else set()
    return _macho_thin_exports(data)


def pe_exports(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise FormatError("no PE signature")
    coff = pe + 4
    nsections, = struct.unpack_from("<H", data, coff + 2)
    opt_size, = struct.unpack_from("<H", data, coff + 16)
    opt = coff + 20
    magic, = struct.unpack_from("<H", data, opt)
    if magic == 0x20B:  # PE32+
        data_dirs = opt + 112
    elif magic == 0x10B:  # PE32
        data_dirs = opt + 96
    else:
        raise FormatError(f"unknown optional header magic {magic:#x}")
    export_rva, export_size = struct.unpack_from("<II", data, data_dirs)
    if export_rva == 0 or export_size == 0:
        return set()
    sections = []
    table = opt + opt_size
    for i in range(nsections):
        entry = table + i * 40
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, entry + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def at(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size:
                return rawptr + rva - vaddr
        raise FormatError(f"RVA {rva:#x} is in no section")

    directory = at(export_rva)
    number_of_names, = struct.unpack_from("<I", data, directory + 24)
    names_rva, = struct.unpack_from("<I", data, directory + 32)
    names_table = at(names_rva)
    names = set()
    for i in range(number_of_names):
        name_rva, = struct.unpack_from("<I", data, names_table + i * 4)
        names.add(_cstr(data, at(name_rva)))
    return names


def exports(path):
    data = open(path, "rb").read()
    if data[:4] == b"\x7fELF":
        return elf_exports(data)
    if data[:2] == b"MZ":
        return pe_exports(data)
    if struct.unpack_from("<I", data, 0)[0] == 0xFEEDFACF or data[:4] in (
        b"\xca\xfe\xba\xbe",
        b"\xca\xfe\xba\xbf",
    ):
        return macho_exports(data)
    raise FormatError("neither ELF, Mach-O nor PE")


def elf_sections(data):
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    out = []
    for i in range(shnum):
        base = shoff + i * shentsize
        sh_type = struct.unpack_from("<I", data, base + 4)[0]
        sh_offset, sh_size = struct.unpack_from("<QQ", data, base + 0x18)
        sh_link, sh_info = struct.unpack_from("<II", data, base + 0x28)
        out.append((sh_type, sh_offset, sh_size, sh_link, sh_info))
    return out


def elf_imports(data):
    """(DT_NEEDED names, symbol version names such as GLIBC_2.17)."""
    secs = elf_sections(data)
    needed, versions = [], set()
    for sh_type, off, size, link, info in secs:
        strtab = secs[link][1]
        if sh_type == 6:  # SHT_DYNAMIC
            for i in range(size // 16):
                tag, val = struct.unpack_from("<qQ", data, off + i * 16)
                if tag == 1:  # DT_NEEDED
                    needed.append(_cstr(data, strtab + val))
        elif sh_type == 0x6FFFFFFE:  # SHT_GNU_verneed
            vn = off
            for _ in range(info):
                _, cnt, _, aux, nxt = struct.unpack_from("<HHIII", data, vn)
                va = vn + aux
                for _ in range(cnt):
                    _, _, _, name, vnext = struct.unpack_from("<IHHII", data, va)
                    versions.add(_cstr(data, strtab + name))
                    va += vnext
                vn += nxt
    return needed, versions


def pe_imports(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe + 4
    nsections, = struct.unpack_from("<H", data, coff + 2)
    opt_size, = struct.unpack_from("<H", data, coff + 16)
    opt = coff + 20
    dirs = opt + (112 if struct.unpack_from("<H", data, opt)[0] == 0x20B else 96)
    imp_rva, _ = struct.unpack_from("<II", data, dirs + 8)
    sections = []
    for i in range(nsections):
        e = opt + opt_size + i * 40
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, e + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def at(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size:
                return rawptr + rva - vaddr
        raise FormatError(f"RVA {rva:#x} is in no section")

    names = []
    if imp_rva:
        d = at(imp_rva)
        while True:
            name_rva = struct.unpack_from("<I", data, d + 12)[0]
            if name_rva == 0:
                break
            names.append(_cstr(data, at(name_rva)))
            d += 20
    return names


def macho_dylibs(data):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd in (0xC, 0x80000018, 0x8000001F):  # LOAD_DYLIB, WEAK, REEXPORT
            out.append(_cstr(data, off + struct.unpack_from("<I", data, off + 8)[0]))
        off += size
    return out


# What a library may load besides itself. Anything else is a file the app
# does not ship (a MinGW runtime DLL, a newer glibc), found on a user's
# machine as a load failure, not here.
ANDROID_NEEDED = {"libc.so", "libdl.so", "libm.so", "liblog.so"}
LINUX_NEEDED = {"libc.so.6", "libpthread.so.0", "libdl.so.2", "libm.so.6", "libresolv.so.2"}
# The dynamic loader is NEEDED on some builds (arm64); only the target's own.
LINUX_LOADER = {"linux_arm64": "ld-linux-aarch64.so.1", "linux_x86_64": "ld-linux-x86-64.so.2"}
# Oldest glibc a Linux build may require (Ubuntu 22.04 ships 2.35).
GLIBC_MAX = (2, 34)
WINDOWS_FORBIDDEN = {"libwinpthread-1.dll", "libgcc_s_seh-1.dll", "libstdc++-6.dll"}


def check_imports(data, target):
    problems = []
    if target.startswith(("android_", "linux_")):
        needed, versions = elf_imports(data)
        allowed = ANDROID_NEEDED if target.startswith("android_") else LINUX_NEEDED | {LINUX_LOADER[target]}
        extra = sorted(set(needed) - allowed)
        if extra:
            problems.append(f"needs {extra}, allowed {sorted(allowed)}")
        glibc = sorted(tuple(int(x) for x in v[6:].split(".")) for v in versions if v.startswith("GLIBC_2"))
        if glibc:
            print(f"     {target}: needs {needed}, glibc up to {'.'.join(map(str, glibc[-1]))}")
            if glibc[-1] > GLIBC_MAX:
                problems.append(f"needs glibc {'.'.join(map(str, glibc[-1]))} > {'.'.join(map(str, GLIBC_MAX))}")
        else:
            print(f"     {target}: needs {needed}")
    elif target.startswith("windows_"):
        dlls = pe_imports(data)
        print(f"     {target}: imports {dlls}")
        bad = sorted(d for d in dlls if d.lower() in WINDOWS_FORBIDDEN)
        if bad:
            problems.append(f"imports MinGW runtime DLLs {bad}: link them statically")
    else:
        libs = macho_dylibs(data)
        bad = [l for l in libs if not l.startswith(("/usr/lib/", "/System/Library/"))]
        if bad:
            problems.append(f"loads {bad}, outside the system")
    return problems


def elf_machine(data):
    return struct.unpack_from("<H", data, 0x12)[0]


def elf_load_aligns(data):
    phoff = struct.unpack_from("<Q", data, 0x20)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    aligns = []
    for i in range(phnum):
        base = phoff + i * phentsize
        p_type = struct.unpack_from("<I", data, base)[0]
        if p_type == 1:  # PT_LOAD
            aligns.append(struct.unpack_from("<Q", data, base + 0x30)[0])
    return aligns


def macho_header_room(data):
    """Bytes free between the load commands and the first section's data."""
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    first = None
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for i in range(nsects):
                sect = off + 72 + i * 80
                offset = struct.unpack_from("<I", data, sect + 48)[0]
                if offset and (first is None or offset < first):
                    first = offset
        off += size
    if first is None:
        raise FormatError("no section with file data")
    return first - (32 + sizeofcmds)


MIN_HEADER_ROOM = 4096


def macho_build_version(data):
    """(cputype, platform, minos) of a thin 64-bit Mach-O."""
    magic, cputype = struct.unpack_from("<II", data, 0)
    if magic != 0xFEEDFACF:
        raise FormatError("not a thin 64-bit Mach-O")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x32:  # LC_BUILD_VERSION
            platform, minos = struct.unpack_from("<II", data, off + 8)
            return cputype, platform, f"{minos >> 16}.{(minos >> 8) & 0xFF}"
        if cmd in (0x24, 0x25):  # LC_VERSION_MIN_MACOSX / _IPHONEOS
            raise FormatError("legacy LC_VERSION_MIN_* instead of LC_BUILD_VERSION")
        off += size
    raise FormatError("no LC_BUILD_VERSION")


def pe_machine(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    return struct.unpack_from("<H", data, pe + 4)[0]


EM_X86_64, EM_AARCH64 = 62, 183
CPU_ARM64 = 0x0100000C
PLATFORM_MACOS, PLATFORM_IOS, PLATFORM_IOSSIM = 1, 2, 7
IMAGE_FILE_MACHINE_AMD64 = 0x8664


def check_container(data, target):
    problems = []
    if target.startswith(("android_", "linux_")):
        if data[:4] != b"\x7fELF":
            return ["not an ELF file"]
        want = EM_X86_64 if target.endswith("x86_64") else EM_AARCH64
        if elf_machine(data) != want:
            problems.append(f"ELF machine {elf_machine(data)}, expected {want}")
        if target.startswith("android_"):
            bad = [a for a in elf_load_aligns(data) if a < 0x4000]
            if bad:
                problems.append(f"PT_LOAD alignment {[hex(a) for a in bad]} < 16 KB")
    elif target.startswith(("ios_", "macos_")):
        cputype, platform, minos = macho_build_version(data)
        if cputype != CPU_ARM64:
            problems.append(f"Mach-O cputype {cputype:#x}, expected arm64")
        want = {"ios_arm64": PLATFORM_IOS, "ios_sim_arm64": PLATFORM_IOSSIM,
                "macos_arm64": PLATFORM_MACOS}[target]
        if platform != want:
            problems.append(f"platform {platform}, expected {want}")
        room = macho_header_room(data)
        if room < MIN_HEADER_ROOM:
            problems.append(f"{room} bytes of header room < {MIN_HEADER_ROOM}: "
                            "install names cannot be rewritten "
                            "(link with -headerpad_max_install_names)")
        if target.startswith("ios_") and minos != "13.0":
            problems.append(f"minos {minos}, expected 13.0 (ITMS-90208)")
    elif target.startswith("windows_"):
        if data[:2] != b"MZ":
            return ["not a PE file"]
        if pe_machine(data) != IMAGE_FILE_MACHINE_AMD64:
            problems.append(f"PE machine {pe_machine(data):#x}, expected x86-64")
    else:
        problems.append(f"unknown target {target}")
    return problems


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    path, target = argv[1], argv[2]
    data = open(path, "rb").read()
    try:
        problems = check_container(data, target)
        if not problems:
            problems = check_imports(data, target)
        got = {n for n in exports(path) if n.startswith("any_shim_")}
    except (FormatError, struct.error, ValueError) as e:
        print(f"FAIL {target}: {path}: {e}")
        return 1
    want = set(ANY_SHIM_EXPORTS)
    if got - want:
        problems.append(f"exports not in the header: {sorted(got - want)}")
    if want - got:
        problems.append(f"missing exports: {sorted(want - got)}")
    if problems:
        for p in problems:
            print(f"FAIL {target}: {p}")
        return 1
    print(f"ok   {target}: {len(got)} exports, container matches")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
