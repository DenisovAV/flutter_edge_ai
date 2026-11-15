"""Compares two litert_drift output directories, output by output.

  python3 litert_drift_compare.py <dir A> <dir B>

For float outputs: identical, cosine, largest absolute difference and that
difference relative to the largest magnitude in A. Integer outputs: identical
or the number of elements that differ.
"""
import math
import os
import struct
import sys

FORMATS = {"f32": "f", "f16": "e", "i32": "i", "i64": "q", "i16": "h",
           "i8": "b", "u8": "B", "bool": "B"}


def load(path, kind):
    data = open(path, "rb").read()
    fmt = FORMATS[kind]
    n = len(data) // struct.calcsize(fmt)
    return struct.unpack("<%d%s" % (n, fmt), data)


def main(a_dir, b_dir):
    names = sorted(n for n in os.listdir(a_dir) if n.endswith(".bin"))
    missing = sorted(set(n for n in os.listdir(b_dir) if n.endswith(".bin")) ^
                     set(names))
    for name in names:
        if name in missing:
            continue
        kind = name.rsplit(".", 2)[1]
        a = load(os.path.join(a_dir, name), kind)
        b = load(os.path.join(b_dir, name), kind)
        if a == b:
            print(f"{name}: identical ({len(a)} values)")
            continue
        if kind in ("f32", "f16"):
            fin = [(x, y) for x, y in zip(a, b)
                   if math.isfinite(x) and math.isfinite(y)]
            dot = sum(x * y for x, y in fin)
            na = math.sqrt(sum(x * x for x, _ in fin))
            nb = math.sqrt(sum(y * y for _, y in fin))
            cos = dot / (na * nb) if na and nb else float("nan")
            diff = max(abs(x - y) for x, y in fin) if fin else float("nan")
            scale = max(abs(x) for x, _ in fin) if fin else float("nan")
            print(f"{name}: differs, cos {cos:.7f}, max |diff| {diff:.3e} "
                  f"({diff / scale if scale else float('nan'):.2e} of max |A|), "
                  f"{len(a) - len(fin)} non-finite")
        else:
            n = sum(x != y for x, y in zip(a, b))
            print(f"{name}: differs in {n} of {len(a)} values")
    for name in missing:
        print(f"{name}: only in one directory")


main(sys.argv[1], sys.argv[2])
