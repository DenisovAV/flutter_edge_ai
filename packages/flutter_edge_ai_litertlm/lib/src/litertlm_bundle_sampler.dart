import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/sampling.dart';

/// The sampler a `.litertlm` bundle ships, read from the file itself: the
/// container header and its `LlmMetadata` section, a few kilobytes.
///
/// Not LiteRT-LM's `litert_lm_loaded_file_create`: that runs a capability scan
/// which copies vision sections, and the whole main graph when the metadata
/// sets no `max_num_tokens`, into the heap — about 1 GB for Gemma 4 E2B — to
/// return four numbers.
///
/// The layout is LiteRT-LM's `schema/core/litertlm_read.cc` and
/// `litertlm_header_schema.fbs` (pin b2f686e2): the magic `LITERTLM`, three
/// uint32 version fields, 4 bytes of padding and a uint64 header end; from
/// byte 32 to the header end a `LiteRTLMMetaData` flatbuffer listing the
/// sections; the `LlmMetadataProto` section is a serialized
/// `litert.lm.proto.LlmMetadata`.
Future<SamplingParams> readBundleSampler(String modelPath) async {
  final file = await File(modelPath).open();
  try {
    final headerEnd = litertlmHeaderEnd(await _readExactly(file, 0, 32));
    final header = await _readExactly(file, 32, headerEnd - 32);
    final section = llmMetadataRange(header);
    if (section == null) return const SamplingParams();
    final (begin, end) = section;
    return samplerFromLlmMetadata(await _readExactly(file, begin, end - begin));
  } finally {
    await file.close();
  }
}

/// [readBundleSampler], with any failure returned instead of thrown.
Future<BundleSamplerRead> tryReadBundleSampler(String modelPath) async {
  try {
    return BundleSamplerRead(await readBundleSampler(modelPath));
  } on Object catch (e, st) {
    return BundleSamplerRead.failed('${e.runtimeType}: $e\n$st');
  }
}

/// The outcome of reading a bundle's sampler: [sampler], empty when the bundle
/// ships none, or the [error] that stopped the read.
final class BundleSamplerRead {
  const BundleSamplerRead(this.sampler) : error = null;

  const BundleSamplerRead.failed(String this.error)
    : sampler = const SamplingParams();

  const BundleSamplerRead.notRead()
    : sampler = const SamplingParams(),
      error = null;

  final SamplingParams sampler;

  /// Why the read failed, with its type and stack; null when it worked.
  final String? error;
}

/// The container major version this reader understands, as LiteRT-LM's own
/// reader (`LITERTLM_MAJOR_VERSION`).
const _majorVersion = 1;

/// Larger than any header or `LlmMetadata` seen (a few KB); a bigger value is
/// a corrupt file, not one to read into memory.
const _maxHeaderBytes = 1 << 20;
const _maxLlmMetadataBytes = 10 << 20;

/// `AnySectionDataType.LlmMetadataProto` in `litertlm_header_schema.fbs`.
const _llmMetadataProto = 5;

/// Where the header flatbuffer ends, from the 32-byte preamble.
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
  final end = data.getUint64(24, Endian.little);
  if (end < 32 || end - 32 > _maxHeaderBytes) {
    throw FormatException('.litertlm header end $end is out of range');
  }
  return end;
}

/// The `[begin, end)` byte range of the `LlmMetadataProto` section, from the
/// header flatbuffer, or null when the bundle has none.
(int, int)? llmMetadataRange(Uint8List header) {
  try {
    final fb = _FlatBuffer(header);
    final root = fb.root();
    final sectionMetadata = fb.table(root, 1);
    if (sectionMetadata == null) return null;
    final objects = fb.vector(sectionMetadata, 0);
    if (objects == null) return null;
    for (var i = 0; i < fb.length(objects); i++) {
      final object = fb.element(objects, i);
      if (fb.uint8(object, 3) != _llmMetadataProto) continue;
      final begin = fb.uint64(object, 1);
      final end = fb.uint64(object, 2);
      if (end < begin || end - begin > _maxLlmMetadataBytes) {
        throw FormatException('LlmMetadata section $begin..$end is invalid');
      }
      return (begin, end);
    }
    return null;
  } on RangeError {
    throw const FormatException('.litertlm header flatbuffer is truncated');
  }
}

/// The sampler in a serialized `LlmMetadata`; empty when it has none.
SamplingParams samplerFromLlmMetadata(Uint8List llmMetadata) {
  try {
    Uint8List? samplerParams;
    for (final f in _ProtoReader(llmMetadata).fields()) {
      // LlmMetadata.sampler_params = 4.
      if (f.number == 4 && f.bytes != null) samplerParams = f.bytes;
    }
    if (samplerParams == null) return const SamplingParams();
    var type = 0, k = 0;
    var p = 0.0, temperature = 0.0;
    int? seed;
    for (final f in _ProtoReader(samplerParams).fields()) {
      switch (f.number) {
        case 1:
          type = f.varint ?? 0;
        case 2:
          k = (f.varint ?? 0).toSigned(32);
        case 3:
          p = f.float32 ?? 0;
        case 4:
          temperature = f.float32 ?? 0;
        case 5:
          seed = f.varint?.toSigned(32);
      }
    }
    return bundleSamplerFrom(
      type: type,
      temperature: _shortestFloat32(temperature),
      topK: k,
      topP: _shortestFloat32(p),
      seed: seed,
    );
  } on RangeError {
    throw const FormatException('LlmMetadata proto is truncated');
  }
}

/// `SamplerParameters.Type`.
const _typeUnspecified = 0;
const _typeTopK = 1;
const _typeTopP = 2;
const _typeGreedy = 3;

/// The bundle's `SamplerParameters` as [SamplingParams].
///
/// The engine is always sent a TOP_P sampler, because LiteRT-LM's CPU sampler
/// rejects the other types, so the other types are written as TOP_P: a greedy
/// bundle becomes `topK: 1`, and a TOP_K bundle gets `topP: 1.0` so no
/// nucleus cut is added to it. A zero field is unset: proto3 does not store
/// one. Throws a [FormatException] for a type this reader does not know and an
/// [ArgumentError] for a value no engine can sample with.
SamplingParams bundleSamplerFrom({
  required int type,
  required double temperature,
  required int topK,
  required double topP,
  int? seed,
}) {
  final SamplingParams sampler;
  switch (type) {
    case _typeUnspecified:
      return const SamplingParams();
    case _typeGreedy:
      sampler = SamplingParams(topK: 1, randomSeed: seed);
    case _typeTopK || _typeTopP:
      sampler = SamplingParams(
        temperature: temperature > 0 ? temperature : null,
        topK: topK > 0 ? topK : null,
        topP: type == _typeTopK ? 1.0 : (topP > 0 ? topP : null),
        randomSeed: seed,
      );
    default:
      throw FormatException('unknown sampler type $type in the bundle');
  }
  sampler.validate();
  return sampler;
}

/// The shortest decimal that is the same float32 as [f]: the bundle stores
/// 0.95, which arrives as 0.949999988079071 and would not equal a caller's
/// 0.95.
double _shortestFloat32(double f) {
  final f32 = Float32List(1);
  for (var digits = 1; digits <= 9; digits++) {
    final d = double.parse(f.toStringAsPrecision(digits));
    f32[0] = d;
    if (f32[0] == f) return d;
  }
  return f;
}

Future<Uint8List> _readExactly(
  RandomAccessFile file,
  int position,
  int length,
) async {
  await file.setPosition(position);
  final bytes = await file.read(length);
  if (bytes.length != length) {
    throw FormatException(
      '.litertlm file ends at ${position + bytes.length}, '
      'expected ${position + length}',
    );
  }
  return bytes;
}

/// Just enough of the FlatBuffers wire format to walk the header: tables,
/// vectors of tables and scalar fields, little-endian. Out-of-range offsets
/// throw [RangeError].
final class _FlatBuffer {
  _FlatBuffer(Uint8List bytes) : _data = ByteData.sublistView(bytes);

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
}

typedef _ProtoField = ({
  int number,
  int? varint,
  double? float32,
  Uint8List? bytes,
});

/// Just enough of the protobuf wire format for two messages: varints,
/// fixed32/fixed64 and length-delimited fields. Out-of-range reads throw
/// [RangeError].
final class _ProtoReader {
  _ProtoReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _at = 0;

  Iterable<_ProtoField> fields() sync* {
    while (_at < _bytes.length) {
      final key = _varint();
      final number = key >> 3;
      switch (key & 7) {
        case 0:
          yield (number: number, varint: _varint(), float32: null, bytes: null);
        case 1:
          _skip(8);
        case 2:
          final length = _varint();
          final start = _at;
          _skip(length);
          yield (
            number: number,
            varint: null,
            float32: null,
            bytes: Uint8List.sublistView(_bytes, start, start + length),
          );
        case 5:
          final value = _data.getFloat32(_at, Endian.little);
          _skip(4);
          yield (number: number, varint: null, float32: value, bytes: null);
        default:
          throw FormatException('unsupported protobuf wire type ${key & 7}');
      }
    }
  }

  void _skip(int n) {
    if (n < 0 || _at + n > _bytes.length) {
      throw RangeError.range(n, 0, _bytes.length - _at);
    }
    _at += n;
  }

  int _varint() {
    var result = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      final b = _bytes[_at++];
      result |= (b & 0x7f) << shift;
      if (b < 0x80) return result;
    }
    throw const FormatException('protobuf varint is too long');
  }
}
