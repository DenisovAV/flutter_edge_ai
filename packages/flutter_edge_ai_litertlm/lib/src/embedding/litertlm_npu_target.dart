// Which NPU, if any, a `.litertlm` bundle was compiled for — read from the
// file itself, before any engine exists.
//
// Google publishes EmbeddingGemma 2 per SoC (`…_Qualcomm_SM8850.litertlm`,
// `…_Google_Tensor_G5…`, `…_Intel_PTL…`): the encoder towers are compiled
// ahead of time into one `DISPATCH_OP` that only that SoC's NPU runs. Nothing
// LiteRT-LM reports tells such a bundle apart (measured on native-v0.18.0-e,
// 270m and 440m SM8850): ModelInfo gives the generic bundle's answers —
// backends [cpu, gpu], NPU brand unknown, no SoC name — and
// `embedding_engine_create` SUCCEEDS on macOS with "cpu" and with "npu", only
// logging a failed warm-up; the first `compute_embedding` then fails with
// "Encountered unresolved custom op: DISPATCH_OP". So the answer is read here.
//
// What marks the bundle: LiteRT's AOT compiler stamps every model it compiles
// with a `LiteRtStamp` metadata entry (`litert/core/build_stamp.h`, LiteRT pin
// 26895c9f): a 250-byte buffer of two NUL-padded fields, the SoC manufacturer
// (125 bytes) and the SoC model (125 bytes) — `Qualcomm` / `SM8850` in the
// SM8850 bundles, `IntelOpenVINO` / `PTL` in the Intel ones. The generic
// bundles carry no stamp in any section.
//
// How it is read: the container header (LiteRT-LM `litertlm_header_schema.fbs`,
// pin b2f686e2) lists the sections; each `TFLiteModel` section is a TFLite
// flatbuffer whose `Model.metadata` (field 6) names its entries and whose
// `Model.buffers` (field 4) holds their bytes. Only the few hundred bytes those
// lookups touch are read — the compiled sections are 127-434 MB — so this is
// cheap enough for every load (a few dozen small reads).

import 'dart:io';
import 'dart:typed_data';

import '../bundle/litertlm_bundle_info.dart' show LiteRtLmNpuTarget;
import '../litertlm_bundle_sampler.dart' show litertlmHeaderEnd;

export '../bundle/litertlm_bundle_info.dart' show LiteRtLmNpuTarget;

/// The NPU [modelPath] was compiled for, or null for a bundle with no
/// compiled section (the generic CPU bundles).
///
/// Every `TFLiteModel` section is checked; a stamp in any of them makes the
/// bundle an NPU bundle, and two sections stamped for different SoCs are a
/// [FormatException]. Throws [FileSystemException] when the file cannot be
/// read and [FormatException] when it is not a `.litertlm` container or its
/// structure is out of range.
Future<LiteRtLmNpuTarget?> readLiteRtLmNpuTarget(String modelPath) async {
  final file = await File(modelPath).open();
  try {
    final reader = _FileReader(file, await file.length());
    final headerEnd = litertlmHeaderEnd(await reader.bytes(0, 32));
    final header = await reader.bytes(32, headerEnd - 32);
    LiteRtLmNpuTarget? found;
    for (final (begin, end) in tfliteModelSections(header)) {
      final target = await _stampOf(reader, begin, end);
      if (target == null) continue;
      if (found != null && found != target) {
        throw FormatException(
          '$modelPath has sections compiled for $found and for $target',
        );
      }
      found = target;
    }
    return found;
  } on RangeError catch (e) {
    throw FormatException(
      '$modelPath: a .litertlm structure is out of range '
      '($e)',
    );
  } finally {
    await file.close();
  }
}

/// The stamp of each of [sections] (`[begin, end)` of `TFLiteModel`
/// sections) in the open [file] of [length] bytes, by range: null for a
/// section that is not compiled for an NPU. A section that ends past the end
/// of the file is left out. Throws [FormatException] for a stamp this reader
/// cannot read and [RangeError] for a structure out of range.
Future<Map<(int, int), LiteRtLmNpuTarget?>> readLiteRtLmSectionStamps(
  RandomAccessFile file,
  int length,
  Iterable<(int, int)> sections,
) async {
  final reader = _FileReader(file, length);
  return {
    for (final (begin, end) in sections)
      if (end <= length) (begin, end): await _stampOf(reader, begin, end),
  };
}

/// The `[begin, end)` ranges of the `TFLiteModel` sections listed in a
/// container [header] (the flatbuffer from byte 32 to the header end).
List<(int, int)> tfliteModelSections(Uint8List header) {
  final fb = _Table(ByteData.sublistView(header));
  final root = fb.ref(0);
  final sectionMetadata = fb.table(root, 1);
  if (sectionMetadata == null) return const [];
  final objects = fb.table(sectionMetadata, 0);
  if (objects == null) return const [];
  return [
    for (var i = 0; i < fb.length(objects); i++)
      if (fb.uint8(fb.element(objects, i), 3) == _tfliteModel)
        (
          fb.uint64(fb.element(objects, i), 1),
          fb.uint64(fb.element(objects, i), 2),
        ),
  ];
}

/// The SoC fields of a `LiteRtStamp` buffer: two NUL-padded fields of
/// [_stampFieldBytes] each. Null when the buffer is not a stamp (wrong size)
/// or names no SoC.
LiteRtLmNpuTarget? parseLiteRtStamp(Uint8List stamp) {
  if (stamp.length != 2 * _stampFieldBytes) return null;
  String field(int start) {
    final bytes = stamp.sublist(start, start + _stampFieldBytes);
    final nul = bytes.indexOf(0);
    return String.fromCharCodes(nul < 0 ? bytes : bytes.sublist(0, nul));
  }

  final vendor = field(0);
  final soc = field(_stampFieldBytes);
  if (vendor.isEmpty || soc.isEmpty) return null;
  return LiteRtLmNpuTarget(vendor: vendor, soc: soc);
}

/// `AnySectionDataType.TFLiteModel` in `litertlm_header_schema.fbs`.
const _tfliteModel = 3;

/// `kSocManufacturerMaxLen + 1` and `kSocModelMaxLen + 1` in LiteRT's
/// `build_stamp.h`.
const _stampFieldBytes = 125;

/// `kLiteRtBuildStampKey`.
const _stampKey = 'LiteRtStamp';

/// Larger than any metadata list a model carries; a bigger count is a corrupt
/// file, not one to walk.
const _maxMetadataEntries = 4096;

/// The stamp of the TFLite model in `[begin, end)`, or null when it has none.
Future<LiteRtLmNpuTarget?> _stampOf(
  _FileReader file,
  int begin,
  int end,
) async {
  if (end <= begin || end > file.length) {
    throw RangeError('TFLiteModel section $begin..$end');
  }
  final model = _AsyncTable(file, begin, end);
  final root = await model.ref(0);
  final metadata = await model.table(root, 6); // Model.metadata
  if (metadata == null) return null;
  final count = await model.length(metadata);
  if (count > _maxMetadataEntries) {
    throw RangeError.range(count, 0, _maxMetadataEntries, 'metadata entries');
  }
  for (var i = 0; i < count; i++) {
    final entry = await model.element(metadata, i);
    final name = await model.string(entry, 0); // Metadata.name
    if (name != _stampKey) continue;
    final bufferIndex = await model.uint32(entry, 1); // Metadata.buffer
    final buffers = await model.table(root, 4); // Model.buffers
    if (buffers == null || bufferIndex >= await model.length(buffers)) {
      throw RangeError('$_stampKey names buffer $bufferIndex');
    }
    final buffer = await model.element(buffers, bufferIndex);
    final data = await model.table(buffer, 0); // Buffer.data
    final Uint8List bytes;
    if (data != null) {
      final length = await model.length(data);
      bytes = await model.bytes(data + 4, _stampLength(length));
    } else {
      // The buffer appended after the flatbuffer (Buffer.offset/size,
      // relative to the model's start), as large-model exports store them.
      final offset = await model.uint64(buffer, 1);
      final size = await model.uint64(buffer, 2);
      bytes = await model.bytes(offset, _stampLength(size));
    }
    return parseLiteRtStamp(bytes) ??
        (throw const FormatException(
          '$_stampKey names no SoC manufacturer and model',
        ));
  }
  return null;
}

/// [length], when it is the size of a stamp this reader knows. Only LiteRT's
/// AOT compiler writes `LiteRtStamp`, so a model that has one IS compiled for
/// an NPU: a layout this reader does not know must not read as "no stamp" —
/// that would run a compiled bundle as the generic one.
int _stampLength(int length) {
  if (length != 2 * _stampFieldBytes) {
    throw FormatException(
      '$_stampKey is $length bytes; this version reads the '
      '${2 * _stampFieldBytes}-byte layout only',
    );
  }
  return length;
}

/// Reads exact byte ranges of an open file.
final class _FileReader {
  _FileReader(this._file, this.length);

  final RandomAccessFile _file;
  final int length;

  Future<Uint8List> bytes(int position, int count) async {
    if (position < 0 || count < 0 || position + count > length) {
      throw RangeError('bytes $position..${position + count} of $length');
    }
    await _file.setPosition(position);
    final bytes = await _file.read(count);
    if (bytes.length != count) {
      throw RangeError('read ${bytes.length} of $count bytes at $position');
    }
    return bytes;
  }
}

/// A flatbuffer inside `[_begin, _end)` of a file, read a field at a time.
/// Positions are relative to [_begin]; anything outside the range throws
/// [RangeError].
final class _AsyncTable {
  _AsyncTable(this._file, this._begin, this._end);

  final _FileReader _file;
  final int _begin;
  final int _end;

  Future<Uint8List> bytes(int position, int count) {
    if (position < 0 || count < 0 || _begin + position + count > _end) {
      throw RangeError('bytes $position..${position + count} of the section');
    }
    return _file.bytes(_begin + position, count);
  }

  Future<ByteData> _view(int position, int count) async =>
      ByteData.sublistView(await bytes(position, count));

  Future<int> uint32(int table, int index) async {
    final at = await _field(table, index);
    return at == null ? 0 : (await _view(at, 4)).getUint32(0, Endian.little);
  }

  Future<int> uint64(int table, int index) async {
    final at = await _field(table, index);
    return at == null ? 0 : (await _view(at, 8)).getUint64(0, Endian.little);
  }

  Future<int> ref(int position) async =>
      position + (await _view(position, 4)).getUint32(0, Endian.little);

  Future<int?> table(int table, int index) async {
    final at = await _field(table, index);
    return at == null ? null : ref(at);
  }

  Future<int> length(int vector) async =>
      (await _view(vector, 4)).getUint32(0, Endian.little);

  Future<int> element(int vector, int i) async {
    final count = await length(vector);
    if (i >= count) throw IndexError.withLength(i, count);
    return ref(vector + 4 + 4 * i);
  }

  Future<String?> string(int table, int index) async {
    final at = await this.table(table, index);
    if (at == null) return null;
    final length = await this.length(at);
    if (length > 256) return ''; // not a metadata name worth reading
    return String.fromCharCodes(await bytes(at + 4, length));
  }

  Future<int?> _field(int table, int index) async {
    final vtable = table - (await _view(table, 4)).getInt32(0, Endian.little);
    final vtableSize = (await _view(vtable, 2)).getUint16(0, Endian.little);
    final slot = 4 + 2 * index;
    if (slot >= vtableSize) return null;
    final offset = (await _view(vtable + slot, 2)).getUint16(0, Endian.little);
    return offset == 0 ? null : table + offset;
  }
}

/// Synchronous field access over the container header's flatbuffer, which
/// is in memory (a few KB).
final class _Table {
  _Table(this._data);

  final ByteData _data;

  int ref(int position) => position + _data.getUint32(position, Endian.little);

  int? _field(int table, int index) {
    final vtable = table - _data.getInt32(table, Endian.little);
    final vtableSize = _data.getUint16(vtable, Endian.little);
    final slot = 4 + 2 * index;
    if (slot >= vtableSize) return null;
    final offset = _data.getUint16(vtable + slot, Endian.little);
    return offset == 0 ? null : table + offset;
  }

  int? table(int table, int index) {
    final at = _field(table, index);
    return at == null ? null : ref(at);
  }

  int length(int vector) => _data.getUint32(vector, Endian.little);

  int element(int vector, int i) {
    final count = length(vector);
    if (i >= count) throw IndexError.withLength(i, count);
    return ref(vector + 4 + 4 * i);
  }

  int uint8(int table, int index) {
    final at = _field(table, index);
    return at == null ? 0 : _data.getUint8(at);
  }

  int uint64(int table, int index) {
    final at = _field(table, index);
    return at == null ? 0 : _data.getUint64(at, Endian.little);
  }
}
