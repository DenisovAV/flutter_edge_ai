import 'dart:typed_data';

/// Reads [length] bytes at [offset]; a shorter result means end of file.
typedef GgufRangeReader = Future<Uint8List> Function(int offset, int length);

/// The layer count and KV-cache width of a GGUF model.
final class GgufModelShape {
  /// Creates a shape with [blockCount] repeating layers.
  const GgufModelShape({
    required this.blockCount,
    required this.kvBytesPerToken,
  });

  /// Repeating transformer layers (`{arch}.block_count`).
  final int blockCount;

  /// Bytes one context token costs in an f16 K and V cache, over all layers.
  final int kvBytesPerToken;
}

const _ggufTypeString = 8;
const _ggufTypeArray = 9;
const _ggufScalarBytes = {
  0: 1,
  1: 1,
  2: 2,
  3: 2,
  4: 4,
  5: 4,
  6: 4,
  7: 1,
  10: 8,
  11: 8,
  12: 8,
};
const _ggufIntegerTypes = {0, 1, 2, 3, 4, 5, 10, 11};
const _ggufArchitectureKey = 'general.architecture';
const _ggufListKeys = {'attention.head_count', 'attention.head_count_kv'};
const _f16Bytes = 2;
const _maxGgufKeyBytes = 4096;
const _maxGgufListLength = 1 << 16;
const _readWindowBytes = 64 * 1024;

/// Reads the [GgufModelShape] of the GGUF file that [read] serves.
///
/// Only the metadata is read. Large arrays such as tokenizer vocabularies are
/// skipped, not loaded. Throws a [FormatException] when the file is not GGUF
/// or lacks the keys that size the KV cache.
Future<GgufModelShape> readGgufModelShape(GgufRangeReader read) async {
  final cursor = _GgufCursor(read);
  if (String.fromCharCodes(await cursor.take(4)) != 'GGUF') {
    throw const FormatException('Not a GGUF file.');
  }
  final version = _readUnsigned(await cursor.take(4), 4);
  if (version != 2 && version != 3) {
    throw FormatException('Unsupported GGUF version $version.');
  }
  await cursor.take(8); // Tensor count, not needed.
  final metadataCount = _readUnsigned(await cursor.take(8), 8);

  final integers = <String, int>{};
  final lists = <String, List<int>>{};
  String? architecture;
  for (var entry = 0; entry < metadataCount; entry++) {
    final key = await cursor.readString();
    final type = _readUnsigned(await cursor.take(4), 4);
    if (type == _ggufTypeString && key == _ggufArchitectureKey) {
      architecture = await cursor.readString();
    } else if (_ggufIntegerTypes.contains(type)) {
      integers[key] = await cursor.readInteger(type);
    } else if (type == _ggufTypeArray) {
      final elementType = _readUnsigned(await cursor.take(4), 4);
      final count = _readUnsigned(await cursor.take(8), 8);
      final wanted =
          _ggufIntegerTypes.contains(elementType) &&
          _ggufListKeys.any(key.endsWith) &&
          count <= _maxGgufListLength;
      if (wanted) {
        lists[key] = [
          for (var i = 0; i < count; i++) await cursor.readInteger(elementType),
        ];
      } else {
        await cursor.skipArray(elementType, count);
      }
    } else {
      await cursor.skipValue(type);
    }
  }

  if (architecture == null) {
    throw const FormatException('GGUF has no general.architecture.');
  }
  final prefix = '$architecture.';
  int requireInteger(String name) =>
      integers['$prefix$name'] ??
      (throw FormatException('GGUF lacks $prefix$name.'));

  final blockCount = requireInteger('block_count');
  if (blockCount <= 0) {
    throw FormatException('GGUF has $blockCount layers.');
  }
  final headCount = _perLayer(
    '${prefix}attention.head_count',
    blockCount,
    integers,
    lists,
  );
  final headCountKv = _perLayer(
    '${prefix}attention.head_count_kv',
    blockCount,
    integers,
    lists,
    fallback: headCount,
  );
  final keyLength =
      integers['${prefix}attention.key_length'] ??
      requireInteger('embedding_length') ~/ headCount.first;
  final valueLength =
      integers['${prefix}attention.value_length'] ??
      requireInteger('embedding_length') ~/ headCount.first;

  var kvBytesPerToken = 0;
  for (final kvHeads in headCountKv) {
    kvBytesPerToken += kvHeads * (keyLength + valueLength) * _f16Bytes;
  }
  return GgufModelShape(
    blockCount: blockCount,
    kvBytesPerToken: kvBytesPerToken,
  );
}

/// A per-layer list from [lists], or a scalar from [integers] repeated.
List<int> _perLayer(
  String key,
  int blockCount,
  Map<String, int> integers,
  Map<String, List<int>> lists, {
  List<int>? fallback,
}) {
  final list = lists[key];
  if (list != null) {
    if (list.length != blockCount) {
      throw FormatException('GGUF $key has ${list.length} values.');
    }
    return list;
  }
  final scalar = integers[key];
  if (scalar != null) return List.filled(blockCount, scalar);
  if (fallback != null) return fallback;
  throw FormatException('GGUF lacks $key.');
}

int _readUnsigned(Uint8List bytes, int length) {
  final data = ByteData.sublistView(bytes);
  return switch (length) {
    4 => data.getUint32(0, Endian.little),
    _ => data.getUint64(0, Endian.little),
  };
}

final class _GgufCursor {
  _GgufCursor(this._read);

  final GgufRangeReader _read;
  int _position = 0;
  Uint8List _window = Uint8List(0);
  int _windowStart = 0;

  /// The next [length] bytes; the view is only valid until the next call.
  Future<Uint8List> take(int length) async {
    if (length < 0) {
      throw FormatException('Invalid GGUF length $length.');
    }
    var start = _position - _windowStart;
    if (start < 0 || start + length > _window.length) {
      _window = await _read(
        _position,
        length > _readWindowBytes ? length : _readWindowBytes,
      );
      _windowStart = _position;
      start = 0;
      if (length > _window.length) {
        throw const FormatException('Truncated GGUF file.');
      }
    }
    _position += length;
    return Uint8List.sublistView(_window, start, start + length);
  }

  Future<String> readString() async {
    final length = _readUnsigned(await take(8), 8);
    if (length > _maxGgufKeyBytes) {
      throw FormatException('GGUF string of $length bytes.');
    }
    return String.fromCharCodes(await take(length));
  }

  Future<int> readInteger(int type) async {
    final bytes = await take(_ggufScalarBytes[type]!);
    final data = ByteData.sublistView(bytes);
    return switch (type) {
      0 => data.getUint8(0),
      1 => data.getInt8(0),
      2 => data.getUint16(0, Endian.little),
      3 => data.getInt16(0, Endian.little),
      4 => data.getUint32(0, Endian.little),
      5 => data.getInt32(0, Endian.little),
      10 => data.getUint64(0, Endian.little),
      _ => data.getInt64(0, Endian.little),
    };
  }

  /// Moves past [length] bytes without reading them.
  void skip(int length) {
    if (length < 0) {
      throw FormatException('Invalid GGUF length $length.');
    }
    _position += length;
  }

  Future<void> skipValue(int type) async {
    final scalar = _ggufScalarBytes[type];
    if (scalar != null) {
      skip(scalar);
    } else if (type == _ggufTypeString) {
      skip(_readUnsigned(await take(8), 8));
    } else if (type == _ggufTypeArray) {
      final elementType = _readUnsigned(await take(4), 4);
      await skipArray(elementType, _readUnsigned(await take(8), 8));
    } else {
      throw FormatException('Unknown GGUF value type $type.');
    }
  }

  Future<void> skipArray(int elementType, int count) async {
    final scalar = _ggufScalarBytes[elementType];
    if (scalar != null) {
      skip(scalar * count);
      return;
    }
    for (var i = 0; i < count; i++) {
      await skipValue(elementType);
    }
  }
}
