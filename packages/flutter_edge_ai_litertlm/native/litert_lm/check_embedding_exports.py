#!/usr/bin/env python3
"""The LiteRT-LM main library must export every C function the EmbeddingGemma 2
pass calls (R5 §4.11).

flutter_edge_ai_litertlm's `.litertlm` embedding pass binds the EmbeddingEngine,
ModelInfo and error-reporter C API out of libLiteRtLm. Nothing else gates those
exports: they leave the library through visibility attributes, not the Windows
`.def` whitelist in patch_c_api.sh, and none of the LLM tests calls them. A
rebuild that loses one ships an embedder that fails at load on that platform
only. The pass refuses such a library by name at runtime; this refuses to
publish it.

Reads the export table itself — ELF `.dynsym`, Mach-O `LC_SYMTAB` (thin or
fat), PE export directory — so it needs no platform toolchain and checks the
bytes that ship.

REQUIRED must equal `liteRtLmEmbeddingSymbols` in
lib/src/embedding/litert_lm_embedding_pass.dart (a VM test compares them).

Usage: check_embedding_exports.py <extracted_bundle_dir> [<label>]
Exit 1 when the main library is missing, unreadable, or misses a symbol.
"""
import os
import struct
import sys

REQUIRED = [
    "litert_lm_clear_last_error",
    "litert_lm_get_last_error_code",
    "litert_lm_get_last_error_message",
    "litert_lm_loaded_file_create",
    "litert_lm_loaded_file_delete",
    "litert_lm_loaded_file_model_type",
    "litert_lm_loaded_file_embedding_dimension",
    "litert_lm_loaded_file_embedding_signature_selection",
    "litert_lm_loaded_file_vision_signature_selection",
    "litert_lm_embedding_engine_settings_create",
    "litert_lm_embedding_engine_settings_delete",
    "litert_lm_embedding_engine_settings_set_cache_dir",
    "litert_lm_embedding_engine_settings_set_max_input_length",
    "litert_lm_embedding_engine_settings_set_num_threads",
    "litert_lm_embedding_engine_settings_set_vision_tokens_per_image",
    "litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir",
    "litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir",
    "litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir",
    "litert_lm_embedding_engine_create",
    "litert_lm_embedding_engine_delete",
    "litert_lm_embedding_engine_compute_embedding",
    "litert_lm_embedding_options_create",
    "litert_lm_embedding_options_delete",
    "litert_lm_embedding_options_set_normalize",
    "litert_lm_embedding_options_set_insert_special_tokens",
    "litert_lm_embedding_options_set_input_overflow_strategy",
    "litert_lm_input_data_create",
    "litert_lm_input_data_delete",
    "litert_lm_embedding_response_get_size",
    "litert_lm_embedding_response_get_values",
    # Exported from native-v0.18.0-e on (patch_c_api.sh section 14); the pass
    # reads both for every request since flutter_edge_ai_litertlm 1.13.1.
    "litert_lm_embedding_response_get_input_length",
    "litert_lm_embedding_response_get_truncated_length",
    "litert_lm_embedding_response_delete",
]

MAIN_LIBRARY = ("libLiteRtLm.dylib", "libLiteRtLm.so", "LiteRtLm.dll")


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


def find_main_library(bundle):
    found = []
    for root, _, files in os.walk(bundle):
        for name in files:
            if name in MAIN_LIBRARY:
                found.append(os.path.join(root, name))
    return found


def main(argv):
    if len(argv) not in (2, 3):
        sys.exit(__doc__)
    bundle = argv[1]
    label = argv[2] if len(argv) == 3 else os.path.basename(bundle.rstrip("/"))
    libraries = find_main_library(bundle)
    if len(libraries) != 1:
        # "inspected nothing" must not pass as "found nothing missing".
        print(f"  [FAIL] {label} — expected one of {', '.join(MAIN_LIBRARY)}, "
              f"found {len(libraries)}: {libraries}")
        return 1
    library = libraries[0]
    try:
        names = exports(library)
    except (FormatError, struct.error, ValueError, IndexError) as e:
        print(f"  [FAIL] {label} — cannot read the exports of "
              f"{os.path.basename(library)}: {e}")
        return 1
    wanted = REQUIRED
    missing = [s for s in wanted if s not in names]
    if missing:
        print(f"  [FAIL] {label} — {os.path.basename(library)} does not export "
              f"{len(missing)} of the {len(wanted)} EmbeddingEngine functions "
              f"the EmbeddingGemma 2 pass calls:")
        for symbol in missing:
            print(f"         {symbol}")
        return 1
    print(f"  [ok]   {label} — {os.path.basename(library)} exports all "
          f"{len(wanted)} EmbeddingEngine functions")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
