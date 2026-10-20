"""Lists the sections of a .litertlm bundle with their SHA-256: how the
example's EmbeddingGemma 2 profile ids are keyed. A profile id names the
text-encoder weights section (its SHA-256 prefix, 12 hex digits), so bundles
whose text towers are byte-identical share one id and the rest do not:
`4410a540ce75` for the generic 270m/440m/740m, `aaae57a31475` for the
SM8850 270m/440m, ...

The layout is LiteRT-LM's schema/core/litertlm_header_schema.fbs (the one
flutter_edge_ai_litertlm's litertlm_container.dart reads): a 32-byte preamble
("LITERTLM", major version, ..., the header's end offset at byte 24), then a
LiteRTLMMetaData flatbuffer whose SectionObjects carry items (KeyValuePairs,
`model_type` among them), begin_offset, end_offset and data_type.

usage: python3 -I litertlm_section_hashes.py <bundle.litertlm> [...]
"""
import hashlib
import struct
import sys

DATA_TYPES = {3: "TFLiteModel"}


class FlatBuffer:
    def __init__(self, data):
        self.d = data

    def u8(self, pos):
        return self.d[pos]

    def u16(self, pos):
        return struct.unpack_from("<H", self.d, pos)[0]

    def u32(self, pos):
        return struct.unpack_from("<I", self.d, pos)[0]

    def i32(self, pos):
        return struct.unpack_from("<i", self.d, pos)[0]

    def u64(self, pos):
        return struct.unpack_from("<Q", self.d, pos)[0]

    def root(self):
        return self.u32(0)

    def field(self, table, index):
        vtable = table - self.i32(table)
        size = self.u16(vtable)
        slot = 4 + 2 * index
        if slot >= size:
            return None
        offset = self.u16(vtable + slot)
        return None if offset == 0 else table + offset

    def table(self, table, index):
        pos = self.field(table, index)
        return None if pos is None else pos + self.u32(pos)

    def vector(self, table, index):
        pos = self.field(table, index)
        if pos is None:
            return []
        vec = pos + self.u32(pos)
        return [vec + 4 + 4 * i + self.u32(vec + 4 + 4 * i) for i in range(self.u32(vec))]

    def string(self, table, index):
        pos = self.field(table, index)
        if pos is None:
            return None
        s = pos + self.u32(pos)
        return self.d[s + 4 : s + 4 + self.u32(s)].decode()


def sections(path):
    with open(path, "rb") as f:
        preamble = f.read(32)
        if preamble[:8] != b"LITERTLM":
            raise SystemExit(f"{path}: not a .litertlm file")
        end = struct.unpack_from("<Q", preamble, 24)[0]
        fb = FlatBuffer(f.read(end - 32))
        meta = fb.table(fb.root(), 1)
        for section in fb.vector(meta, 0):
            model_type = None
            for item in fb.vector(section, 0):
                if fb.string(item, 0) == "model_type" and fb.u8(fb.field(item, 1)) == 9:
                    model_type = fb.string(fb.table(item, 2), 0)
            begin_pos = fb.field(section, 1)
            end_pos = fb.field(section, 2)
            begin = fb.u64(begin_pos) if begin_pos else 0
            stop = fb.u64(end_pos) if end_pos else 0
            data_type_pos = fb.field(section, 3)
            data_type = fb.u8(data_type_pos) if data_type_pos else 0
            f.seek(begin)
            digest = hashlib.sha256()
            left = stop - begin
            while left > 0:
                chunk = f.read(min(left, 1 << 24))
                digest.update(chunk)
                left -= len(chunk)
            yield model_type, DATA_TYPES.get(data_type, data_type), begin, stop, digest.hexdigest()


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for path in sys.argv[1:]:
        print(path)
        for model_type, data_type, begin, stop, digest in sections(path):
            print(f"  {digest[:12]}  {stop - begin:>11}  {data_type}  {model_type}")


if __name__ == "__main__":
    main()
