// Fake-backed unit tests for `OnnxEmbeddingForwardPass` — zero dlopen, zero
// real ONNX session (design D-T4's "fake-testable" requirement; Phase 2
// hardened plan Task 3).

import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_onnx/src/embedding/onnx_embedding_forward_pass.dart';
import 'package:flutter_gemma_onnx/src/embedding/ort_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every `run()` call's arguments and returns a caller-supplied
/// result — the seam that makes `OnnxEmbeddingForwardPass`'s input-routing
/// and padding logic testable without any native session.
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
  group('OnnxEmbeddingForwardPass input routing (design D-T3)', () {
    test('mask/typeIds are forwarded to OrtClient.run() only when the graph '
        'declares those inputs', () async {
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
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
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
        'inputs (a Gemma SentencePiece ONNX export has neither), even '
        'though the caller supplied them', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids'], // no attention_mask, no token_type_ids
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: 384,
        ),
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List.fromList([1, 0]),
          shape: const [1, 2],
        ),
      );
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
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
        'never produces (Gemma SentencePiece has no mask/typeIds concept) '
        'defaults to all-ones/all-zeros over the token length, rather than '
        'omitting a tensor the graph requires — verified against a real '
        'EmbeddingGemma-300M-ONNX session hard-failing with "Missing Input: '
        'attention_mask" when this default is absent', () async {
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
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
      );
      await pass.load();

      // Gemma SentencePiece tokenizer output: no mask, no typeIds.
      await pass.run(tokenIds: [2, 10, 11, 1]);

      expect(fake.lastMask, [1, 1, 1, 1]);
      expect(fake.lastTypeIds, [0, 0, 0, 0]);
    });
  });

  group('OnnxEmbeddingForwardPass output-contract dispatch (design D-T2)', () {
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
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
      );

      expect(pass.outputContract, isNull); // before load(): unknown
      await pass.load();
      expect(pass.outputContract, EmbeddingOutputContract.tokenLevel);
    });

    test('hasLastHiddenStateOutput:false (sentence_embedding, or an '
        'unrecognized first-output fallback) reports pooledFinal', () async {
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
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
      );
      await pass.load();
      expect(pass.outputContract, EmbeddingOutputContract.pooledFinal);
    });
  });

  group('OnnxEmbeddingForwardPass padding (design D-T3, the anti-regression '
      'test for pooling-over-padding)', () {
    test('a static-seq graph pads ids/mask together to staticSeqLen and '
        'echoes the PADDED mask on ForwardResult.attentionMask — never the '
        'caller\'s unpadded one', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask'],
          outputName: 'last_hidden_state',
          hasLastHiddenStateOutput: true,
          staticSeqLen: 5,
          staticDim: 2,
        ),
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List.fromList([
            for (final _ in ids) ...[1.0, 0.0],
          ]),
          shape: [1, ids.length, 2],
        ),
      );
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
      );
      await pass.load();

      final result = await pass.run(tokenIds: [10, 11, 12]); // no mask supplied

      // ids padded 3 -> 5 with 0.
      expect(fake.lastIds, [10, 11, 12, 0, 0]);
      // mask defaults to all-ones over the UNPADDED length, then padded with
      // 0 to staticSeqLen.
      expect(fake.lastMask, [1, 1, 1, 0, 0]);
      // ForwardResult must echo the PADDED mask, not null and not an
      // unpadded [1,1,1].
      expect(result.attentionMask, [1, 1, 1, 0, 0]);
    });

    test(
      'padded and unpadded runs of the SAME real values produce an '
      'IDENTICAL final embedding via meanPoolAndNormalize — the '
      'anti-regression proof that padding never leaks into the mean',
      () async {
        // "Unpadded": a dynamic-shape graph gets exactly 3 real rows back and
        // reports no mask (nothing to exclude).
        final unpaddedFake = _FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'last_hidden_state',
            hasLastHiddenStateOutput: true,
            staticDim: 2, // dynamic seqLen -> staticSeqLen omitted
          ),
          runResult: (ids, mask, typeIds) => OrtRunResult(
            values: Float32List.fromList([1, 0, 0, 1, 2, 2]),
            shape: const [1, 3, 2],
          ),
        );
        final unpaddedPass = OnnxEmbeddingForwardPass(
          '/tmp/model.onnx',
          clientFactory: () => unpaddedFake,
        );
        await unpaddedPass.load();
        final unpaddedResult = await unpaddedPass.run(tokenIds: [10, 11, 12]);

        // "Padded": a static-shape graph (seqLen=5) gets back the SAME 3 real
        // rows PLUS 2 garbage padding rows that would corrupt the mean if
        // counted — the pass must exclude them via the mask it echoes.
        final paddedFake = _FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids', 'attention_mask'],
            outputName: 'last_hidden_state',
            hasLastHiddenStateOutput: true,
            staticSeqLen: 5,
            staticDim: 2,
          ),
          runResult: (ids, mask, typeIds) => OrtRunResult(
            // Same 3 real rows as above, then 2 garbage rows far outside their
            // range — if the mask isn't applied, the mean drifts wildly.
            values: Float32List.fromList([
              1,
              0,
              0,
              1,
              2,
              2,
              999,
              -999,
              999,
              -999,
            ]),
            shape: const [1, 5, 2],
          ),
        );
        final paddedPass = OnnxEmbeddingForwardPass(
          '/tmp/model.onnx',
          clientFactory: () => paddedFake,
        );
        await paddedPass.load();
        final paddedResult = await paddedPass.run(tokenIds: [10, 11, 12]);

        final unpaddedVector = meanPoolAndNormalize(
          ForwardResult(
            values: unpaddedResult.values,
            shape: unpaddedResult.shape,
          ),
          attentionMask: unpaddedResult.attentionMask,
        );
        final paddedVector = meanPoolAndNormalize(
          ForwardResult(values: paddedResult.values, shape: paddedResult.shape),
          attentionMask: paddedResult.attentionMask,
        );

        expect(paddedVector.length, unpaddedVector.length);
        for (var i = 0; i < paddedVector.length; i++) {
          expect(paddedVector[i], closeTo(unpaddedVector[i], 1e-9));
        }
      },
    );
  });

  group('OnnxEmbeddingForwardPass dimension probe', () {
    test('probes a 1-token forward pass when staticDim is null (dynamic '
        'output shape)', () async {
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
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
      );
      await pass.load();
      expect(pass.outputDimension, 384);
    });

    test('the probe is routed through run()\'s own mask-defaulting — a '
        'graph that declares attention_mask (every BERT/MiniLM/'
        'EmbeddingGemma export does) must receive a non-null mask on the '
        'probe call, not the bare `client.run(ids: [0])` that would trip '
        'ORT\'s "Missing Input: attention_mask"', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: null, // triggers the probe
        ),
        runResult: (ids, mask, typeIds) {
          expect(ids, [0]);
          expect(mask, [1]); // defaulted all-ones over the probe's 1 token
          return OrtRunResult(values: Float32List(384), shape: const [1, 384]);
        },
      );
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
      );
      await pass.load();

      expect(pass.outputDimension, 384);
      expect(fake.lastMask, [1]);
    });

    test('the probe also goes through static-seq padding: a static-shape '
        'graph pads the 1-token probe id/mask to staticSeqLen instead of '
        'sending a mismatched seqLen=1 tensor', () async {
      final fake = _FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticSeqLen: 4,
          staticDim: null, // triggers the probe
        ),
        runResult: (ids, mask, typeIds) {
          expect(ids, [0, 0, 0, 0]); // padded to staticSeqLen
          expect(mask, [1, 0, 0, 0]); // 1 real token, rest padding
          return OrtRunResult(
            values: Float32List(384 * 4),
            shape: const [1, 4, 384],
          );
        },
      );
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
      );
      await pass.load();

      expect(pass.outputDimension, 384);
    });
  });

  group('OnnxEmbeddingForwardPass lifecycle', () {
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
        final pass = OnnxEmbeddingForwardPass(
          '/tmp/model.onnx',
          clientFactory: () => fake,
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
      final pass = OnnxEmbeddingForwardPass(
        '/tmp/model.onnx',
        clientFactory: () => fake,
      );
      await expectLater(
        pass.run(tokenIds: const [1]),
        throwsA(isA<StateError>()),
      );
    });
  });
}
