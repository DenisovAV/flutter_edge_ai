// The prefill signatures of a `.litertlm` LLM, read in Dart the way LiteRT-LM's
// CPU/GPU executor reads them, and the rule they set: with fewer entries left
// in the context window than the smallest, LiteRT-LM refuses any input
// (`GetOptimizedPrefillWorkGroups`; section 23 reports it as context_full),
// so such a conversation needs a new one, not a rewind (core 2.6.0 design
// §6.4b).
//
// The real-bundle cases are opt-in: GEMMA4_E2B_LITERTLM and
// FUNCTIONGEMMA_LITERTLM, the registry's files, whose smallest prefill
// signatures the L1 probes measured as 128 and 256
// (doc/research/litertlm-0.19-phase1.md, "prefillroom").
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/bundle/litertlm_bundle_reader.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_npu_target.dart'
    show readLiteRtLmLinearAttentionState, readLiteRtLmPrefillLengths;
import 'package:flutter_test/flutter_test.dart';

/// A minimal FlatBuffer writer: objects are appended in order, and a
/// reference is patched once its target, always written later (a FlatBuffer
/// `uoffset` points forward), is placed.
final class _Fb {
  final _bytes = BytesBuilder();
  final _patches = <(int at, Object target)>[];
  final _placed = <Object, int>{};

  int get _end => _bytes.length;

  void _u32(int v) => _bytes.add(
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
  );

  void _u16(int v) => _bytes.add(
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List(),
  );

  /// A table of 4-byte fields: an int (inline uint32) or another object
  /// (a reference). A null field is absent.
  void table(Object id, List<Object?> fields) {
    final vtable = _end;
    _u16(4 + 2 * fields.length);
    _u16(4 + 4 * fields.length);
    for (var i = 0; i < fields.length; i++) {
      _u16(fields[i] == null ? 0 : 4 + 4 * i);
    }
    if (_end % 4 != 0) _u16(0);
    final at = _end;
    _placed[id] = at;
    _bytes.add(
      (ByteData(
        4,
      )..setInt32(0, at - vtable, Endian.little)).buffer.asUint8List(),
    );
    for (final field in fields) {
      if (field is int) {
        _u32(field);
      } else {
        if (field != null) _patches.add((_end, field));
        _u32(0);
      }
    }
  }

  /// A vector of references.
  void refs(Object id, List<Object> targets) {
    _placed[id] = _end;
    _u32(targets.length);
    for (final t in targets) {
      _patches.add((_end, t));
      _u32(0);
    }
  }

  void ints(Object id, List<int> values) {
    _placed[id] = _end;
    _u32(values.length);
    values.forEach(_u32);
  }

  void string(Object id, String value) {
    _placed[id] = _end;
    _u32(value.length);
    _bytes.add([...value.codeUnits, 0]);
    while (_end % 4 != 0) {
      _bytes.addByte(0);
    }
  }

  /// The buffer, its root (a uoffset at 0) referring to [root].
  Uint8List finish(Object root) {
    final body = _bytes.toBytes();
    final out = ByteData(4 + body.length);
    for (var i = 0; i < body.length; i++) {
      out.setUint8(4 + i, body[i]);
    }
    out.setUint32(0, 4 + _placed[root]!, Endian.little);
    for (final (at, target) in _patches) {
      final to = _placed[target]!;
      out.setUint32(4 + at, to - at, Endian.little);
    }
    return out.buffer.asUint8List();
  }
}

/// A TFLite model with [signatures]: (key, input name, shape) each, one
/// subgraph per signature with that one tensor.
Uint8List _tflite(List<(String, String, List<int>)> signatures) {
  final fb = _Fb()
    // Model: version, operator_codes, subgraphs, description, buffers,
    // metadata_buffer, metadata, signature_defs.
    ..table('model', [3, null, 'subgraphs', null, null, null, null, 'sigs'])
    ..refs('subgraphs', [
      for (var i = 0; i < signatures.length; i++) 'subgraph$i',
    ])
    ..refs('sigs', [for (var i = 0; i < signatures.length; i++) 'sig$i']);
  for (var i = 0; i < signatures.length; i++) {
    final (key, input, shape) = signatures[i];
    fb
      // SubGraph.tensors; Tensor.shape.
      ..table('subgraph$i', ['tensors$i'])
      ..refs('tensors$i', ['tensor$i'])
      ..table('tensor$i', ['shape$i'])
      ..ints('shape$i', shape)
      // SignatureDef: inputs, outputs, signature_key, deprecated_tag,
      // subgraph_index; TensorMap: name, tensor_index.
      ..table('sig$i', ['inputs$i', null, 'key$i', null, i])
      ..refs('inputs$i', ['map$i'])
      ..table('map$i', ['name$i', 0])
      ..string('key$i', key)
      ..string('name$i', input);
  }
  return fb.finish('model');
}

Future<List<int>> _lengthsOf(Uint8List model) async {
  final dir = Directory.systemTemp.createTempSync('prefill_signatures');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/model.tflite')..writeAsBytesSync(model);
  final open = await file.open();
  try {
    return await readLiteRtLmPrefillLengths(
      open,
      model.length,
      0,
      model.length,
    );
  } finally {
    await open.close();
  }
}

String? _env(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty && File(value).existsSync()
      ? value
      : null;
}

void main() {
  group('liteRtLmPrefillFits', () {
    test('fits while the entries left reach the smallest signature', () {
      // Gemma 4 E2B, a 1024 window: refused at 125 left, on CPU and Metal.
      expect(
        liteRtLmPrefillFits(
          maxNumTokens: 1024,
          tokenCount: 899,
          prefillLengths: const [128, 256, 512, 1024],
        ),
        isFalse,
      );
      expect(
        liteRtLmPrefillFits(
          maxNumTokens: 1024,
          tokenCount: 896,
          prefillLengths: const [128, 256, 512, 1024],
        ),
        isTrue,
      );
      // FunctionGemma on Metal: refused at 249 left, its smallest is 256.
      expect(
        liteRtLmPrefillFits(
          maxNumTokens: 1024,
          tokenCount: 775,
          prefillLengths: const [256],
        ),
        isFalse,
      );
    });

    test('order does not matter, and no signature never fits', () {
      expect(
        liteRtLmPrefillFits(
          maxNumTokens: 1024,
          tokenCount: 0,
          prefillLengths: const [512, 128],
        ),
        isTrue,
      );
      expect(
        liteRtLmPrefillFits(
          maxNumTokens: 1024,
          tokenCount: 0,
          prefillLengths: const [],
        ),
        isFalse,
      );
    });
  });

  group('readLiteRtLmPrefillLengths', () {
    test('reads each prefill signature\'s input positions length, under '
        'either name and rank, sorted, once each; other signatures are not '
        'prefill ones', () async {
      final lengths = await _lengthsOf(
        _tflite([
          ('prefill_1024', 'input_pos', [1, 1024]),
          ('decode', 'input_pos', [1, 1]),
          ('prefill_128', 'positions', [128]),
          ('prefill_alt_128', 'input_pos', [1, 128]),
        ]),
      );
      expect(lengths, [128, 1024]);
    });

    test('a model without signatures has none', () async {
      final fb = _Fb()..table('model', [3]);
      expect(await _lengthsOf(fb.finish('model')), isEmpty);
    });

    test('a prefill signature without input positions, or of another rank, '
        'is a FormatException, not a signature skipped', () async {
      for (final (input, shape) in [
        ('tokens', [1, 128]),
        ('input_pos', [1, 1, 128]),
      ]) {
        await expectLater(
          _lengthsOf(_tflite([('prefill_128', input, shape)])),
          throwsFormatException,
          reason: '$input $shape',
        );
      }
    });
  });

  test(
    'a bundle whose main model is compiled for an NPU has no prefill '
    'signatures to report (GEMMA4_E2B_NPU_LITERTLM): its executor prefills '
    'in context groups',
    () async {
      final npu = _env('GEMMA4_E2B_NPU_LITERTLM')!;
      final info = await readLiteRtLmBundleInfo(npu);
      expect(info.textModel?.npuTarget, isNotNull, reason: 'an NPU bundle');
      expect(await readLiteRtLmPrefillSignatureLengths(npu), isEmpty);
    },
    skip: _env('GEMMA4_E2B_NPU_LITERTLM') == null
        ? 'GEMMA4_E2B_NPU_LITERTLM is not set'
        : null,
  );

  group('readLiteRtLmLinearAttentionState', () {
    Future<bool> stateOf(Uint8List model) async {
      final dir = Directory.systemTemp.createTempSync('linear_attention');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/model.tflite')..writeAsBytesSync(model);
      final open = await file.open();
      try {
        return await readLiteRtLmLinearAttentionState(
          open,
          model.length,
          0,
          model.length,
        );
      } finally {
        await open.close();
      }
    }

    test('a convolution or recurrent state input, in any signature, is '
        'linear attention state', () async {
      for (final name in ['kv_cache_c_0', 'kv_cache_r_12']) {
        expect(
          await stateOf(
            _tflite([
              ('prefill_128', 'input_pos', [1, 128]),
              ('decode', name, [1, 4, 1024]),
            ]),
          ),
          isTrue,
          reason: name,
        );
      }
    });

    test(
      'a KV cache, positions and a model without signatures are not',
      () async {
        expect(
          await stateOf(
            _tflite([
              ('prefill_128', 'kv_cache_k_0', [1, 128]),
              ('decode', 'kv_cache_v_0', [1, 1]),
              ('decode_alt', 'input_pos', [1, 1]),
              ('prefill_c', 'k_cache_0', [1, 128]),
            ]),
          ),
          isFalse,
        );
        expect(
          await stateOf((_Fb()..table('model', [3])).finish('model')),
          isFalse,
        );
      },
    );

    for (final (env, hybrid) in [
      ('LFM25_LITERTLM', true),
      ('GEMMA4_E2B_LITERTLM', false),
      ('FUNCTIONGEMMA_LITERTLM', false),
      ('GEMMA4_E2B_NPU_LITERTLM', false),
    ]) {
      final path = _env(env);
      test('$env: linear attention state $hybrid', () async {
        expect(await readLiteRtLmHasLinearAttentionState(path!), hybrid);
      }, skip: path == null ? '$env is not set' : null);
    }
  });

  group('readLiteRtLmPrefillSignatureLengths on real bundles', () {
    for (final (env, smallest) in [
      ('GEMMA4_E2B_LITERTLM', 128),
      ('FUNCTIONGEMMA_LITERTLM', 256),
    ]) {
      final path = _env(env);
      test('$env: sorted, the smallest is $smallest', () async {
        final lengths = await readLiteRtLmPrefillSignatureLengths(path!);
        // ignore: avoid_print
        print('$env prefill signatures: $lengths');
        expect(lengths, isNotEmpty);
        expect(lengths.first, smallest);
        expect(lengths, orderedEquals([...lengths]..sort()));
        expect(lengths.toSet(), hasLength(lengths.length));
      }, skip: path == null ? '$env is not set' : null);
    }
  });
}
