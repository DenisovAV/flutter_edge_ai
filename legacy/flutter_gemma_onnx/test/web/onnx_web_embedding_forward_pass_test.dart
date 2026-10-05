// Fake-backed unit tests for `OnnxWebEmbeddingForwardPass` — zero
// `dart:js_interop`, zero real ORT session. This file intentionally imports
// ONLY `onnx_web_embedding_forward_pass.dart` (pure Dart) and
// `../embedding/ort_client.dart` (also pure Dart) — never
// `ort_web_client.dart` — so it runs on the VM under plain `flutter test`,
// exactly like the native `onnx_embedding_forward_pass_test.dart` suite this
// mirrors.

import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_onnx/src/embedding/ort_client.dart';
import 'package:flutter_gemma_onnx/src/web/onnx_web_embedding_forward_pass.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeOrtClient implements OrtClient {
  _FakeOrtClient({required this.ioSpec, required this.runResult});

  final OrtIoSpec ioSpec;
  final OrtRunResult Function(
    List<int> ids,
    List<int>? mask,
    List<int>? typeIds,
  )
  runResult;

  int loadCallCount = 0;
  int closeCallCount = 0;
  List<int>? lastIds;
  List<int>? lastMask;
  List<int>? lastTypeIds;

  @override
  Future<OrtIoSpec> load(String modelPath) async {
    loadCallCount++;
    return ioSpec;
  }

  @override
  Future<OrtRunResult> run({
    required List<int> ids,
    List<int>? mask,
    List<int>? typeIds,
  }) async {
    lastIds = ids;
    lastMask = mask;
    lastTypeIds = typeIds;
    return runResult(ids, mask, typeIds);
  }

  @override
  Future<void> close() async {
    closeCallCount++;
  }
}

void main() {
  group('OnnxWebEmbeddingForwardPass input routing (design D-T3, web)', () {
    test('mask/typeIds are forwarded only when the graph declares those '
        'inputs', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask', 'token_type_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: 384,
        ),
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List.fromList([1, 0]),
          shape: const [1, 2],
        ),
      );
      final pass = OnnxWebEmbeddingForwardPass(
        'https://example.com/m.onnx',
        fake,
      );
      await pass.load();

      await pass.run(
        tokenIds: [1, 2, 3],
        attentionMask: [1, 1, 1],
        tokenTypeIds: [0, 0, 0],
      );

      expect(fake.lastMask, [1, 1, 1]);
      expect(fake.lastTypeIds, [0, 0, 0]);
    });

    test('mask/typeIds are withheld when the graph does not declare those '
        'inputs', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: 384,
        ),
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List.fromList([1, 0]),
          shape: const [1, 2],
        ),
      );
      final pass = OnnxWebEmbeddingForwardPass(
        'https://example.com/m.onnx',
        fake,
      );
      await pass.load();

      await pass.run(
        tokenIds: [1, 2, 3],
        attentionMask: [1, 1, 1],
        tokenTypeIds: [0, 0, 0],
      );

      expect(fake.lastMask, isNull);
      expect(fake.lastTypeIds, isNull);
    });

    test('a declared attention_mask/token_type_ids input the tokenizer '
        'never produces defaults to all-ones/all-zeros over the token '
        'length', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask', 'token_type_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: 768,
        ),
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List.fromList([1, 0]),
          shape: const [1, 2],
        ),
      );
      final pass = OnnxWebEmbeddingForwardPass(
        'https://example.com/m.onnx',
        fake,
      );
      await pass.load();

      await pass.run(tokenIds: [2, 10, 11, 1]);

      expect(fake.lastMask, [1, 1, 1, 1]);
      expect(fake.lastTypeIds, [0, 0, 0, 0]);
    });
  });

  group(
    'OnnxWebEmbeddingForwardPass output-contract dispatch (design D-T2)',
    () {
      test('hasLastHiddenStateOutput:true reports tokenLevel', () async {
        final fake = _FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'last_hidden_state',
            hasLastHiddenStateOutput: true,
            staticDim: 384,
          ),
          runResult: (ids, mask, typeIds) => OrtRunResult(
            values: Float32List.fromList([1, 0]),
            shape: const [1, 1, 2],
          ),
        );
        final pass = OnnxWebEmbeddingForwardPass(
          'https://example.com/m.onnx',
          fake,
        );

        expect(pass.outputContract, isNull); // before load(): unknown
        await pass.load();
        expect(pass.outputContract, EmbeddingOutputContract.tokenLevel);
      });

      test('hasLastHiddenStateOutput:false reports pooledFinal', () async {
        final fake = _FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'sentence_embedding',
            hasLastHiddenStateOutput: false,
            staticDim: 384,
          ),
          runResult: (ids, mask, typeIds) => OrtRunResult(
            values: Float32List.fromList([1, 0]),
            shape: const [1, 2],
          ),
        );
        final pass = OnnxWebEmbeddingForwardPass(
          'https://example.com/m.onnx',
          fake,
        );
        await pass.load();
        expect(pass.outputContract, EmbeddingOutputContract.pooledFinal);
      });
    },
  );

  group('OnnxWebEmbeddingForwardPass dimension probe', () {
    test('probes a 1-token forward pass when staticDim is null', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: null,
        ),
        runResult: (ids, mask, typeIds) {
          expect(ids, [0]); // the 1-token probe
          return OrtRunResult(values: Float32List(384), shape: const [1, 384]);
        },
      );
      final pass = OnnxWebEmbeddingForwardPass(
        'https://example.com/m.onnx',
        fake,
      );
      await pass.load();
      expect(pass.outputDimension, 384);
    });
  });

  group('OnnxWebEmbeddingForwardPass lifecycle', () {
    test(
      'close() is idempotent and forwards to the client exactly once',
      () async {
        final fake = _FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'sentence_embedding',
            hasLastHiddenStateOutput: false,
            staticDim: 2,
          ),
          runResult: (ids, mask, typeIds) => OrtRunResult(
            values: Float32List.fromList([1, 0]),
            shape: const [1, 2],
          ),
        );
        final pass = OnnxWebEmbeddingForwardPass(
          'https://example.com/m.onnx',
          fake,
        );
        await pass.load();
        await pass.close();
        await pass.close();
        expect(fake.closeCallCount, 1);
      },
    );

    test('run() before load() throws', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: 2,
        ),
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List.fromList([1, 0]),
          shape: const [1, 2],
        ),
      );
      final pass = OnnxWebEmbeddingForwardPass(
        'https://example.com/m.onnx',
        fake,
      );
      await expectLater(
        pass.run(tokenIds: const [1]),
        throwsA(isA<StateError>()),
      );
    });
  });
}
