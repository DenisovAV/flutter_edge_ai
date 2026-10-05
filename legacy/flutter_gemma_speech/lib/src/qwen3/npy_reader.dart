// .npy / .npz reader for the Qwen3-TTS host tables (embedding tables,
// projection matrices, prompt caches) shipped as NumPy arrays.
//
// Supports:
//  - whole-array reads of `<f4` (float32) and `<f2` (float16, up-cast to
//    float32) arrays,
//  - single-row lookup by byte offset into a 2-D `<f2` array (avoids loading
//    the whole table into memory for a single embedding lookup),
//  - `.npz` archives (a ZIP of `.npy` members) — STORED entries only, as
//    produced by `numpy.savez` for these tables.
//
// Format reference: .npy v1 = 6-byte magic `\x93NUMPY`, 1 byte major
// version, 1 byte minor version, a 2-byte little-endian header length, then
// an ASCII Python-dict literal header (e.g.
// `{'descr': '<f4', 'fortran_order': False, 'shape': (2, 3), }`) padded with
// spaces (and a trailing `\n`) so that `10 + headerLength` is a multiple of
// 64, followed by the raw little-endian array data.
//
// This file is pure Dart (`dart:io` + `dart:typed_data`) — no Flutter, no
// FFI, no native dependency — so it can be unit-tested without a device.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Parsed `.npy` header: array shape, NumPy dtype string (e.g. `'<f4'`,
/// `'<f2'`), and the byte offset in the file where raw array data begins.
class NpyHeader {
  const NpyHeader({
    required this.shape,
    required this.dtype,
    required this.dataOffset,
  });

  final List<int> shape;
  final String dtype;
  final int dataOffset;
}

const int _npyMagicAndVersionLength = 8; // 6-byte magic + major + minor.

/// Parses the `.npy` v1 header from an already-open [RandomAccessFile].
/// Leaves the file position at [NpyHeader.dataOffset] on return.
NpyHeader parseNpyHeader(RandomAccessFile f) {
  f.setPositionSync(0);
  final magicAndVersion = f.readSync(_npyMagicAndVersionLength);
  if (magicAndVersion.length != _npyMagicAndVersionLength ||
      magicAndVersion[0] != 0x93 ||
      String.fromCharCodes(magicAndVersion.sublist(1, 6)) != 'NUMPY') {
    throw const FormatException('not a .npy file (bad magic)');
  }
  final major = magicAndVersion[6];
  if (major != 1) {
    throw FormatException('unsupported .npy version: $major');
  }

  final headerLenBytes = f.readSync(2);
  final headerLen = ByteData.sublistView(
    headerLenBytes,
  ).getUint16(0, Endian.little);
  final headerBytes = f.readSync(headerLen);
  final headerStr = ascii.decode(headerBytes);

  final dtype = _extractDictString(headerStr, 'descr');
  final shape = _extractShape(headerStr);

  final dataOffset = _npyMagicAndVersionLength + 2 + headerLen;
  f.setPositionSync(dataOffset);
  return NpyHeader(shape: shape, dtype: dtype, dataOffset: dataOffset);
}

String _extractDictString(String header, String key) {
  final match = RegExp("'$key'\\s*:\\s*'([^']*)'").firstMatch(header);
  if (match == null) {
    throw FormatException(".npy header missing '$key': $header");
  }
  return match.group(1)!;
}

List<int> _extractShape(String header) {
  final match = RegExp(r"'shape'\s*:\s*\(([^)]*)\)").firstMatch(header);
  if (match == null) {
    throw FormatException('.npy header missing shape: $header');
  }
  final inner = match.group(1)!.trim();
  if (inner.isEmpty) return const [];
  return inner
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map(int.parse)
      .toList(growable: false);
}

int _elementCount(List<int> shape) =>
    shape.isEmpty ? 1 : shape.reduce((a, b) => a * b);

/// Reads a whole `<f4` (little-endian float32) `.npy` array into a flat
/// [Float32List] (row-major / C order).
Float32List readNpyF32(String path) {
  final f = File(path).openSync();
  try {
    final h = parseNpyHeader(f);
    if (h.dtype != '<f4') {
      throw StateError(
        'readNpyF32: expected dtype <f4, got ${h.dtype} ($path)',
      );
    }
    final count = _elementCount(h.shape);
    final bytes = f.readSync(count * 4);
    if (bytes.length != count * 4) {
      throw StateError(
        'readNpyF32: truncated file $path (expected ${count * 4} bytes, '
        'got ${bytes.length})',
      );
    }
    return Float32List.view(_copyToAlignedBuffer(bytes).buffer);
  } finally {
    f.closeSync();
  }
}

/// Reads a whole `<f2` (little-endian float16) `.npy` array, up-cast
/// element-wise to a flat [Float32List] (row-major / C order).
Float32List readNpyF16AsF32(String path) {
  final f = File(path).openSync();
  try {
    final h = parseNpyHeader(f);
    if (h.dtype != '<f2') {
      throw StateError(
        'readNpyF16AsF32: expected dtype <f2, got ${h.dtype} ($path)',
      );
    }
    final count = _elementCount(h.shape);
    final bytes = f.readSync(count * 2);
    if (bytes.length != count * 2) {
      throw StateError(
        'readNpyF16AsF32: truncated file $path (expected ${count * 2} '
        'bytes, got ${bytes.length})',
      );
    }
    final view = ByteData.sublistView(_copyToAlignedBuffer(bytes));
    final out = Float32List(count);
    for (var i = 0; i < count; i++) {
      out[i] = _halfToFloat(view.getUint16(i * 2, Endian.little));
    }
    return out;
  } finally {
    f.closeSync();
  }
}

/// Reads a single row of a 2-D `<f2` `.npy` array by seeking directly to its
/// byte offset (`header.dataOffset + row * cols * 2`), avoiding a whole-array
/// load. [h] must have been produced by [parseNpyHeader] on [f].
Float32List npyRowF16AsF32(RandomAccessFile f, NpyHeader h, int row) {
  if (h.dtype != '<f2') {
    throw StateError('npyRowF16AsF32: expected dtype <f2, got ${h.dtype}');
  }
  if (h.shape.length != 2) {
    throw StateError(
      'npyRowF16AsF32: expected a 2-D array, got shape ${h.shape}',
    );
  }
  final rows = h.shape[0];
  final cols = h.shape[1];
  if (row < 0 || row >= rows) {
    throw RangeError.range(row, 0, rows - 1, 'row');
  }
  final offset = h.dataOffset + row * cols * 2;
  f.setPositionSync(offset);
  final bytes = f.readSync(cols * 2);
  if (bytes.length != cols * 2) {
    throw StateError(
      'npyRowF16AsF32: truncated file at row $row (expected ${cols * 2} '
      'bytes, got ${bytes.length})',
    );
  }
  final view = ByteData.sublistView(_copyToAlignedBuffer(bytes));
  final out = Float32List(cols);
  for (var i = 0; i < cols; i++) {
    out[i] = _halfToFloat(view.getUint16(i * 2, Endian.little));
  }
  return out;
}

/// Copies [bytes] into a fresh, 0-offset [Uint8List] so it is safe to wrap
/// with [Float32List.view] / [ByteData.sublistView] regardless of the
/// underlying buffer's alignment or offset (`RandomAccessFile.readSync`
/// results are not guaranteed to start at a buffer offset divisible by 4).
Uint8List _copyToAlignedBuffer(Uint8List bytes) => Uint8List.fromList(bytes);

/// IEEE-754 binary16 -> IEEE-754 binary64 (Dart `double`) conversion,
/// handling zero, subnormals, normals, infinities, and NaN.
double _halfToFloat(int h) {
  final s = (h >> 15) & 1;
  final e = (h >> 10) & 0x1f;
  final m = h & 0x3ff;
  if (e == 0) {
    // Zero (m == 0) or subnormal: value = m * 2^-24.
    return (s == 1 ? -1 : 1) * m * 5.9604644775390625e-8;
  }
  if (e == 31) {
    if (m == 0) {
      return s == 1 ? double.negativeInfinity : double.infinity;
    }
    return double.nan;
  }
  return (s == 1 ? -1 : 1) * (1 + m / 1024.0) * _pow2(e - 15);
}

double _pow2(int exp) => exp >= 0 ? (1 << exp).toDouble() : 1.0 / (1 << -exp);

// --- Minimal ZIP reader for .npz (STORED entries only) ----------------

/// Reads every member of a `.npz` archive (a ZIP of `.npy` files, as
/// produced by `numpy.savez`) and up-casts each to a flat [Float32List],
/// keyed by member name without the `.npy` suffix.
///
/// Only STORED (uncompressed) entries are supported — `numpy.savez` (as
/// opposed to `savez_compressed`) always writes STORED entries. A DEFLATE
/// member throws a [StateError] rather than being silently misread.
Map<String, Float32List> readNpzF32(String path) {
  final bytes = File(path).readAsBytesSync();
  final entries = _readZipStoredEntries(bytes);
  final out = <String, Float32List>{};
  for (final entry in entries.entries) {
    var name = entry.key;
    if (name.endsWith('.npy')) {
      name = name.substring(0, name.length - '.npy'.length);
    }
    out[name] = _npyBytesToF32(entry.value, name);
  }
  return out;
}

Float32List _npyBytesToF32(Uint8List npyBytes, String memberName) {
  final byteData = ByteData.sublistView(npyBytes);
  if (npyBytes.length < 10 ||
      byteData.getUint8(0) != 0x93 ||
      String.fromCharCodes(npyBytes.sublist(1, 6)) != 'NUMPY') {
    throw FormatException('npz member $memberName: not a .npy file');
  }
  final headerLen = byteData.getUint16(8, Endian.little);
  final headerStr = ascii.decode(npyBytes.sublist(10, 10 + headerLen));
  final dtype = _extractDictString(headerStr, 'descr');
  final shape = _extractShape(headerStr);
  final dataOffset = 10 + headerLen;
  final count = _elementCount(shape);

  if (dtype == '<f4') {
    final data = npyBytes.sublist(dataOffset, dataOffset + count * 4);
    return Float32List.view(_copyToAlignedBuffer(data).buffer);
  } else if (dtype == '<f2') {
    final view = ByteData.sublistView(npyBytes, dataOffset);
    final out = Float32List(count);
    for (var i = 0; i < count; i++) {
      out[i] = _halfToFloat(view.getUint16(i * 2, Endian.little));
    }
    return out;
  }
  throw StateError('npz member $memberName: unsupported dtype $dtype');
}

/// Reads the ZIP End Of Central Directory record and Central Directory of
/// [bytes], returning the raw (uncompressed) data of every STORED member,
/// keyed by filename. Throws [StateError] on any non-STORED (compressed)
/// member.
Map<String, Uint8List> _readZipStoredEntries(Uint8List bytes) {
  const eocdSignature = 0x06054b50;
  const centralDirSignature = 0x02014b50;
  const localHeaderSignature = 0x04034b50;
  const storedMethod = 0;

  // The EOCD record is at least 22 bytes and sits at the end of the file,
  // optionally preceded by a variable-length comment — scan backward for
  // its signature (comment is capped at 65535 bytes by the ZIP spec, so this
  // terminates quickly).
  var eocdOffset = -1;
  final maxCommentLen = bytes.length < 65557 ? bytes.length - 22 : 65535;
  for (var back = 0; back <= maxCommentLen; back++) {
    final pos = bytes.length - 22 - back;
    if (pos < 0) break;
    final data = ByteData.sublistView(bytes, pos, pos + 4);
    if (data.getUint32(0, Endian.little) == eocdSignature) {
      eocdOffset = pos;
      break;
    }
  }
  if (eocdOffset < 0) {
    throw const FormatException('.npz: End Of Central Directory not found');
  }

  final eocd = ByteData.sublistView(bytes, eocdOffset, eocdOffset + 22);
  final entryCount = eocd.getUint16(10, Endian.little);
  final centralDirOffset = eocd.getUint32(16, Endian.little);

  final out = <String, Uint8List>{};
  var pos = centralDirOffset;
  for (var i = 0; i < entryCount; i++) {
    final header = ByteData.sublistView(bytes, pos, pos + 46);
    if (header.getUint32(0, Endian.little) != centralDirSignature) {
      throw const FormatException('.npz: malformed central directory entry');
    }
    final compressionMethod = header.getUint16(10, Endian.little);
    final compressedSize = header.getUint32(20, Endian.little);
    final nameLen = header.getUint16(28, Endian.little);
    final extraLen = header.getUint16(30, Endian.little);
    final commentLen = header.getUint16(32, Endian.little);
    final localHeaderOffset = header.getUint32(42, Endian.little);
    final name = utf8.decode(bytes.sublist(pos + 46, pos + 46 + nameLen));

    if (compressionMethod != storedMethod) {
      throw StateError('npz member $name is DEFLATE; STORED expected');
    }

    // Parse the local file header to find where the raw data actually
    // starts (its filename/extra-field lengths can differ in principle from
    // the central directory's, even though numpy writes them identically).
    final localHeader = ByteData.sublistView(
      bytes,
      localHeaderOffset,
      localHeaderOffset + 30,
    );
    if (localHeader.getUint32(0, Endian.little) != localHeaderSignature) {
      throw FormatException('.npz: malformed local file header for $name');
    }
    final localNameLen = localHeader.getUint16(26, Endian.little);
    final localExtraLen = localHeader.getUint16(28, Endian.little);
    final dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen;
    out[name] = bytes.sublist(dataStart, dataStart + compressedSize);

    pos += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}
