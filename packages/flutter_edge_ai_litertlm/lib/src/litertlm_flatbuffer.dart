// Just enough of the FlatBuffers wire format to walk a `.litertlm` header —
// shared by the LLM sampler reader (`litertlm_bundle_sampler.dart`) and the
// embedding container reader (`embedding/litertlm_container.dart`).
// Package-private: nothing exports it.

import 'dart:convert';
import 'dart:typed_data';

/// Tables, vectors of tables, strings, union discriminators and scalar
/// fields, little-endian, over the header bytes. Out-of-range offsets throw
/// [RangeError].
final class LitertlmFlatBuffer {
  LitertlmFlatBuffer(Uint8List bytes)
    : _bytes = bytes,
      _data = ByteData.sublistView(bytes);

  final Uint8List _bytes;
  final ByteData _data;

  int root() => _ref(0);

  /// Position of field [index]'s value in [table], or null when absent.
  int? _field(int table, int index) {
    final vtable = table - _data.getInt32(table, Endian.little);
    final vtableSize = _data.getUint16(vtable, Endian.little);
    final slot = 4 + 2 * index;
    if (slot >= vtableSize) return null;
    final offset = _data.getUint16(vtable + slot, Endian.little);
    return offset == 0 ? null : table + offset;
  }

  int _ref(int position) => position + _data.getUint32(position, Endian.little);

  int? table(int table, int index) {
    final at = _field(table, index);
    return at == null ? null : _ref(at);
  }

  int? vector(int table, int index) => this.table(table, index);

  int length(int vector) => _data.getUint32(vector, Endian.little);

  int element(int vector, int i) {
    if (i >= length(vector)) throw RangeError.index(i, vector);
    return _ref(vector + 4 + 4 * i);
  }

  int uint8(int table, int index) {
    final at = _field(table, index);
    return at == null ? 0 : _data.getUint8(at);
  }

  int uint64(int table, int index) {
    final at = _field(table, index);
    return at == null ? 0 : _data.getUint64(at, Endian.little);
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
