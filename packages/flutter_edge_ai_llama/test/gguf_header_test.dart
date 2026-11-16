@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai_llama/src/gguf_header.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads layers and f16 KV width from scalar head counts', () async {
    final shape = await _read(_model(blocks: 34, headCountKv: 8));

    expect(shape.blockCount, 34);
    expect(shape.kvBytesPerToken, 34 * 8 * (128 + 128) * 2);
  });

  test('sums per-layer head_count_kv arrays', () async {
    final shape = await _read(_model(blocks: 3, headCountKv: [8, 4, 2]));

    expect(shape.blockCount, 3);
    expect(shape.kvBytesPerToken, (8 + 4 + 2) * (128 + 128) * 2);
  });

  test('derives head width from embedding length and heads', () async {
    final shape = await _read(
      _model(
        blocks: 2,
        headCountKv: 8,
        keyLength: null,
        valueLength: null,
        embeddingLength: 4096,
      ),
    );

    expect(shape.kvBytesPerToken, 2 * 8 * (128 + 128) * 2);
  });

  test('skips a large tokenizer array and still reads later keys', () async {
    final shape = await _read(
      _model(blocks: 34, headCountKv: 8, tokenCount: 20000),
    );

    expect(shape.blockCount, 34);
    expect(shape.kvBytesPerToken, 34 * 8 * (128 + 128) * 2);
  });

  test('rejects a file that is not GGUF', () async {
    final bytes = Uint8List.fromList([...'NOPE'.codeUnits, 0, 0, 0, 0]);

    await expectLater(_read(bytes), throwsA(isA<FormatException>()));
  });

  test('rejects a GGUF file without a layer count', () async {
    final bytes = _model(blocks: 34, headCountKv: 8, omitBlockCount: true);

    await expectLater(_read(bytes), throwsA(isA<FormatException>()));
  });
}

Future<GgufModelShape> _read(Uint8List bytes) =>
    readGgufModelShape((offset, length) async {
      final start = math.min(offset, bytes.length);
      final end = math.min(offset + length, bytes.length);
      return Uint8List.sublistView(bytes, start, end);
    });

/// A llama-style GGUF v3 file with the metadata the KV estimate reads.
Uint8List _model({
  required int blocks,
  required Object headCountKv,
  int? keyLength = 128,
  int? valueLength = 128,
  int embeddingLength = 4096,
  int tokenCount = 0,
  bool omitBlockCount = false,
}) {
  final entries = _Entries()..string('general.architecture', 'llama');
  if (!omitBlockCount) entries.uint32('llama.block_count', blocks);
  if (tokenCount > 0) {
    entries.stringArray('tokenizer.ggml.tokens', tokenCount);
  }
  entries.uint32('llama.attention.head_count', 32);
  if (headCountKv is List<int>) {
    entries.int32Array('llama.attention.head_count_kv', headCountKv);
  } else {
    entries.uint32('llama.attention.head_count_kv', headCountKv as int);
  }
  if (keyLength != null) {
    entries.uint32('llama.attention.key_length', keyLength);
  }
  if (valueLength != null) {
    entries.uint32('llama.attention.value_length', valueLength);
  }
  entries.uint32('llama.embedding_length', embeddingLength);
  return entries.file();
}

final class _Entries {
  final BytesBuilder _body = BytesBuilder(copy: false);
  int _count = 0;

  void uint32(String key, int value) {
    _key(key, 4);
    _body.add(_bytes(4, (data) => data.setUint32(0, value, Endian.little)));
  }

  void string(String key, String value) {
    _key(key, 8);
    _text(value);
  }

  void int32Array(String key, List<int> values) {
    _key(key, 9);
    _u32(5);
    _u64(values.length);
    for (final value in values) {
      _body.add(_bytes(4, (data) => data.setInt32(0, value, Endian.little)));
    }
  }

  void stringArray(String key, int count) {
    _key(key, 9);
    _u32(8);
    _u64(count);
    for (var i = 0; i < count; i++) {
      _text('token$i');
    }
  }

  Uint8List file() {
    final header = BytesBuilder(copy: false)
      ..add('GGUF'.codeUnits)
      ..add(_bytes(4, (data) => data.setUint32(0, 3, Endian.little)))
      ..add(_bytes(8, (data) => data.setUint64(0, 0, Endian.little)))
      ..add(_bytes(8, (data) => data.setUint64(0, _count, Endian.little)));
    return (BytesBuilder(copy: false)
          ..add(header.takeBytes())
          ..add(_body.takeBytes()))
        .takeBytes();
  }

  void _key(String key, int type) {
    _count++;
    _text(key);
    _u32(type);
  }

  void _text(String value) {
    _u64(value.length);
    _body.add(value.codeUnits);
  }

  void _u32(int value) =>
      _body.add(_bytes(4, (data) => data.setUint32(0, value, Endian.little)));

  void _u64(int value) =>
      _body.add(_bytes(8, (data) => data.setUint64(0, value, Endian.little)));

  static Uint8List _bytes(int length, void Function(ByteData) write) {
    final data = ByteData(length);
    write(data);
    return data.buffer.asUint8List();
  }
}
