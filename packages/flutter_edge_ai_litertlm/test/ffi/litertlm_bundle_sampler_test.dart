import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/sampling.dart';
import 'package:flutter_edge_ai_litertlm/src/litertlm_bundle_sampler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The first bytes of two real bundles, up to the end of their LlmMetadata
/// section: header, zero padding, proto. See fixtures/README.md.
const _qwen3 = 'test/ffi/fixtures/qwen3_0_6b_prefix.litertlm';
const _gemma3 = 'test/ffi/fixtures/gemma3_1b_prefix.litertlm';

List<int> _varint(int v) {
  final out = <int>[];
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  return out..add(v);
}

List<int> _int(int field, int v) => [..._varint(field << 3), ..._varint(v)];

List<int> _float(int field, double v) => [
  ..._varint(field << 3 | 5),
  ...(ByteData(4)..setFloat32(0, v, Endian.little)).buffer.asUint8List(),
];

List<int> _bytes(int field, List<int> body) => [
  ..._varint(field << 3 | 2),
  ..._varint(body.length),
  ...body,
];

/// An LlmMetadata with a few unrelated fields around `sampler_params`.
Uint8List _llmMetadata(List<int> samplerParams) => Uint8List.fromList([
  ..._bytes(1, 'unrelated'.codeUnits),
  ..._bytes(4, samplerParams),
  ..._int(5, 4096),
]);

String _tempCopy(String fixture, void Function(Uint8List bytes) mutate) {
  final dir = Directory.systemTemp.createTempSync('bundle_sampler_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final bytes = File(fixture).readAsBytesSync();
  mutate(bytes);
  final path = '${dir.path}/model.litertlm';
  File(path).writeAsBytesSync(bytes);
  return path;
}

void main() {
  group('readBundleSampler on real bundle headers', () {
    test('Qwen3-0.6B ships TOP_P 0.6 / 20 / 0.95', () async {
      expect(
        await readBundleSampler(_qwen3),
        const SamplingParams(temperature: 0.6, topK: 20, topP: 0.95),
      );
    });

    test('Gemma3-1B (container 1.0) ships none', () async {
      expect((await readBundleSampler(_gemma3)).isEmpty, isTrue);
    });
  });

  group('tryReadBundleSampler reports a file it cannot read', () {
    test('wrong magic', () async {
      final read = await tryReadBundleSampler(
        _tempCopy(_qwen3, (b) => b[0] = 0x58),
      );
      expect(read.error, contains('LITERTLM'));
      expect(read.sampler.isEmpty, isTrue);
    });

    test('a container major version it does not know', () async {
      final read = await tryReadBundleSampler(
        _tempCopy(_qwen3, (b) => b[8] = 2),
      );
      expect(read.error, contains('version 2'));
    });

    test('a file cut before its LlmMetadata section ends', () async {
      final dir = Directory.systemTemp.createTempSync('bundle_sampler_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/model.litertlm';
      File(
        path,
      ).writeAsBytesSync(File(_qwen3).readAsBytesSync().sublist(0, 16400));
      expect((await tryReadBundleSampler(path)).error, contains('ends at'));
    });

    test('a missing file', () async {
      final read = await tryReadBundleSampler('/nonexistent/model.litertlm');
      expect(read.error, contains('Cannot open file'));
    });
  });

  group('samplerFromLlmMetadata', () {
    test('TOP_P keeps every field, the seed included', () {
      expect(
        samplerFromLlmMetadata(
          _llmMetadata([
            ..._int(1, 2),
            ..._int(2, 20),
            ..._float(3, 0.95),
            ..._float(4, 0.6),
            ..._int(5, 7),
          ]),
        ),
        const SamplingParams(
          temperature: 0.6,
          topK: 20,
          topP: 0.95,
          randomSeed: 7,
        ),
      );
    });

    test('TOP_K gets topP 1.0, so no nucleus cut is added', () {
      expect(
        samplerFromLlmMetadata(
          _llmMetadata([..._int(1, 1), ..._int(2, 40), ..._float(4, 1.0)]),
        ),
        const SamplingParams(temperature: 1.0, topK: 40, topP: 1.0),
      );
    });

    test('GREEDY becomes topK 1', () {
      expect(
        samplerFromLlmMetadata(_llmMetadata(_int(1, 3))),
        const SamplingParams(topK: 1),
      );
    });

    test('an unspecified type, or no sampler_params, is empty', () {
      expect(
        samplerFromLlmMetadata(
          _llmMetadata([..._int(1, 0), ..._int(2, 40)]),
        ).isEmpty,
        isTrue,
      );
      expect(
        samplerFromLlmMetadata(
          Uint8List.fromList(_bytes(1, 'no sampler'.codeUnits)),
        ).isEmpty,
        isTrue,
      );
    });

    test('a sampler type it does not know is an error', () {
      expect(
        () => samplerFromLlmMetadata(_llmMetadata(_int(1, 7))),
        throwsFormatException,
      );
    });

    test('a value no engine can sample with is an error', () {
      expect(
        () => samplerFromLlmMetadata(
          _llmMetadata([..._int(1, 2), ..._int(2, 20), ..._float(3, 1.5)]),
        ),
        throwsArgumentError,
      );
    });

    test('a truncated proto is an error', () {
      final bytes = _llmMetadata([..._int(1, 2), ..._float(3, 0.95)]);
      expect(
        () => samplerFromLlmMetadata(
          Uint8List.sublistView(bytes, 0, bytes.length - 6),
        ),
        throwsFormatException,
      );
    });
  });
}
