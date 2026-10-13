// Just enough of the FlatBuffers wire format to walk a `.litertlm` header —
// shared by the LLM sampler reader (`litertlm_bundle_sampler.dart`) and the
// embedding container reader (`embedding/litertlm_container.dart`) — and the
// 32-byte preamble in front of it. Package-private: nothing exports it.
// Web-safe, dart2js included: no dart:io, and the path the web EmbeddingGemma 2
// pass takes (`litertlmHeaderEnd`, tables, vectors, strings, uint8) reads no
// 64-bit value — `getUint64` throws UnsupportedError under dart2js. Only
// [LitertlmFlatBuffer.uint64] does, and only native readers call it (section
// offsets in the sampler and the NPU-target reader).

import 'dart:convert';
import 'dart:typed_data';

/// The container major version this reader understands, as LiteRT-LM's own
/// reader (`LITERTLM_MAJOR_VERSION`).
const _majorVersion = 1;

/// Larger than any header seen (a few KB); a bigger value is a corrupt file,
/// not one to read into memory.
const _maxHeaderBytes = 1 << 20;

/// Where the header flatbuffer ends, from the 32-byte preamble: the magic
/// `LITERTLM`, three uint32 version fields, 4 bytes of padding and a uint64
/// header end (LiteRT-LM `schema/core/litertlm_read.cc`, pin b2f686e2).
///
/// The uint64 is read as two uint32 halves, so this runs under dart2js too; a
/// non-zero high half is past [_maxHeaderBytes] anyway.
int litertlmHeaderEnd(Uint8List preamble) {
  final data = ByteData.sublistView(preamble);
  if (preamble.length < 32 ||
      String.fromCharCodes(preamble.sublist(0, 8)) != 'LITERTLM') {
    throw const FormatException('not a .litertlm file: no LITERTLM magic');
  }
  final major = data.getUint32(8, Endian.little);
  if (major != _majorVersion) {
    throw FormatException(
      '.litertlm container version $major is not supported '
      '(expected $_majorVersion)',
    );
  }
  final low = data.getUint32(24, Endian.little);
  final high = data.getUint32(28, Endian.little);
  final end = high * 0x100000000 + low;
  if (high != 0 || end < 32 || end - 32 > _maxHeaderBytes) {
    throw FormatException('.litertlm header end $end is out of range');
  }
  return end;
}

/// Tables, vectors of tables, strings, union discriminators and scalar
/// fields, little-endian, over the header bytes. Out-of-range offsets throw
/// [RangeError] — checked here, before every read, rather than left to
/// `ByteData`: on the web the bytes are a JS-backed view, and an out-of-range
/// read there is the DataView's own JS RangeError, which dart2js delivers as
/// an `ArgumentError` and dart2wasm as a JS exception no `on` clause matches
/// (measured in the browser suite on Chrome 155).
final class LitertlmFlatBuffer {
  LitertlmFlatBuffer(Uint8List bytes)
    : _bytes = bytes,
      _data = ByteData.sublistView(bytes);

  final Uint8List _bytes;
  final ByteData _data;

  int root() => _ref(0);

  /// Throws [RangeError] unless [size] bytes from [position] are in the
  /// buffer.
  void _check(int position, int size) {
    if (position < 0 || position + size > _bytes.length) {
      throw RangeError.range(position, 0, _bytes.length - size, 'position');
    }
  }

  int _uint32(int position) {
    _check(position, 4);
    return _data.getUint32(position, Endian.little);
  }

  /// Position of field [index]'s value in [table], or null when absent.
  int? _field(int table, int index) {
    _check(table, 4);
    final vtable = table - _data.getInt32(table, Endian.little);
    _check(vtable, 2);
    final vtableSize = _data.getUint16(vtable, Endian.little);
    final slot = 4 + 2 * index;
    if (slot >= vtableSize) return null;
    _check(vtable + slot, 2);
    final offset = _data.getUint16(vtable + slot, Endian.little);
    return offset == 0 ? null : table + offset;
  }

  int _ref(int position) => position + _uint32(position);

  int? table(int table, int index) {
    final at = _field(table, index);
    return at == null ? null : _ref(at);
  }

  int? vector(int table, int index) => this.table(table, index);

  int length(int vector) => _uint32(vector);

  int element(int vector, int i) {
    if (i >= length(vector)) throw RangeError.index(i, vector);
    return _ref(vector + 4 + 4 * i);
  }

  int uint8(int table, int index) {
    final at = _field(table, index);
    if (at == null) return 0;
    _check(at, 1);
    return _data.getUint8(at);
  }

  /// Native only: dart2js has no `ByteData.getUint64`.
  int uint64(int table, int index) {
    final at = _field(table, index);
    if (at == null) return 0;
    _check(at, 8);
    return _data.getUint64(at, Endian.little);
  }

  /// The string in field [index] of [table], or null when absent. Decoded as
  /// UTF-8; malformed bytes become U+FFFD rather than throwing.
  String? string(int table, int index) {
    final at = this.table(table, index);
    if (at == null) return null;
    final length = this.length(at);
    final start = at + 4;
    if (start + length > _bytes.length) {
      throw RangeError.range(start + length, 0, _bytes.length);
    }
    return utf8.decode(
      Uint8List.sublistView(_bytes, start, start + length),
      allowMalformed: true,
    );
  }
}
