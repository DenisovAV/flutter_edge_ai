// `OnnxEmbeddingPass` (native) over a fake `OrtClient` — zero dlopen, zero
// real ONNX session (design D-T4). Driven through the pass's own lifecycle
// (`load` → `embed` → `close`), the way core's worker drives it: what the
// session is fed, how the output becomes the vector, the static graph's limit
// and its typed overflow, the dimension probe, and freeing the session.

import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/onnx_embedding_pass.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/ort_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_ort_client.dart';

const _sentenceEmbedding = OrtIoSpec(
  inputNames: ['input_ids'],
  outputName: 'sentence_embedding',
  hasLastHiddenStateOutput: false,
  staticDim: 2,
);

OnnxEmbeddingPass _pass(FakeOrtClient client, {CharTokenizer? tokenizer}) {
  final t = tokenizer ?? CharTokenizer();
  return OnnxEmbeddingPass(
    OnnxEmbeddingConfig(
      modelPath: '/tmp/model.onnx',
      tokenizerPath: '/tmp/tokenizer.json',
      tokenizerFactory: (_) async => t,
    ),
    clientFactory: () => client,
  );
}

Future<List<double>> _embed(OnnxEmbeddingPass pass, String text) =>
    pass.embed(EmbeddingInput.text(text), TaskType.none);

void main() {
  group('what the session is fed (design D-T3)', () {
    test('mask/typeIds are forwarded only when the graph declares those '
        'inputs', () async {
      final client = FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask', 'token_type_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: 2,
        ),
      );
      final pass = _pass(
        client,
        tokenizer: CharTokenizer(withMask: true, withTypeIds: true),
      );
      await pass.load();

      await _embed(pass, 'abc');

      expect(client.lastIds, 'abc'.codeUnits);
      expect(client.lastMask, [1, 1, 1]);
      expect(client.lastTypeIds, [0, 0, 0]);
    });

    test('mask/typeIds are withheld when the graph does not declare those '
        'inputs (a Gemma SentencePiece ONNX export has neither), even though '
        'the tokenizer produced them', () async {
      final client = FakeOrtClient(ioSpec: _sentenceEmbedding);
      final pass = _pass(
        client,
        tokenizer: CharTokenizer(withMask: true, withTypeIds: true),
      );
      await pass.load();

      await _embed(pass, 'abc');

      expect(client.lastMask, isNull);
      expect(client.lastTypeIds, isNull);
    });

    test('a declared attention_mask/token_type_ids input the tokenizer never '
        'produces defaults to all-ones/all-zeros over the ids — a real '
        'EmbeddingGemma-300M-ONNX session fails with "Missing Input: '
        'attention_mask" without it', () async {
      final client = FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask', 'token_type_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: 768,
        ),
      );
      final pass = _pass(client);
      await pass.load();

      await _embed(pass, 'abcd');

      expect(client.lastMask, [1, 1, 1, 1]);
      expect(client.lastTypeIds, [0, 0, 0, 0]);
    });

    test('the task prefix reaches the tokenizer', () async {
      final tokenizer = CharTokenizer();
      final pass = _pass(
        FakeOrtClient(ioSpec: _sentenceEmbedding),
        tokenizer: tokenizer,
      );
      await pass.load();

      await pass.embed(EmbeddingInput.text('x'), TaskType.retrievalDocument);

      expect(tokenizer.encoded, ['title: none | text: x']);
    });
  });

  group('how the output becomes the vector (design D-T2)', () {
    test(
      'a last_hidden_state graph is mean-pooled and L2-normalised',
      () async {
        final client = FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'last_hidden_state',
            hasLastHiddenStateOutput: true,
            staticDim: 2,
          ),
          runResult: (ids, mask, typeIds) => OrtRunResult(
            values: Float32List.fromList([3, 4]),
            shape: const [1, 1, 2],
          ),
        );
        final pass = _pass(client);
        await pass.load();

        final vector = await _embed(pass, 'a');

        expect(vector[0], closeTo(0.6, 1e-6));
        expect(vector[1], closeTo(0.8, 1e-6));
      },
    );

    test('a sentence_embedding (or unrecognised first output) graph is '
        'copied verbatim', () async {
      final client = FakeOrtClient(
        ioSpec: _sentenceEmbedding,
        runResult: pooled([3, 4]),
      );
      final pass = _pass(client);
      await pass.load();

      expect(await _embed(pass, 'a'), [3, 4]);
    });
  });

  group('a static-shape graph (design D-T3, the anti-regression test for '
      'pooling over padding)', () {
    const staticSpec = OrtIoSpec(
      inputNames: ['input_ids', 'attention_mask'],
      outputName: 'last_hidden_state',
      hasLastHiddenStateOutput: true,
      staticSeqLen: 5,
      staticDim: 2,
    );

    test('reports its sequence length as maxInputTokens', () async {
      final info = await _pass(FakeOrtClient(ioSpec: staticSpec)).load();
      expect(info.maxInputTokens, 5);
      expect(info.dimension, 2);
    });

    test('pads ids and mask together to the sequence length', () async {
      final client = FakeOrtClient(
        ioSpec: staticSpec,
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List.fromList([
            for (final _ in ids) ...[1.0, 0.0],
          ]),
          shape: [1, ids.length, 2],
        ),
      );
      final pass = _pass(client);
      await pass.load();

      await _embed(pass, 'abc'); // no mask from the tokenizer

      expect(client.lastIds, [...'abc'.codeUnits, 0, 0]);
      expect(client.lastMask, [1, 1, 1, 0, 0]);
    });

    test('an input over the limit is refused with both counts and never '
        'reaches the session; at the limit it runs', () async {
      final client = FakeOrtClient(
        ioSpec: staticSpec,
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List(ids.length * 2)..[0] = 1,
          shape: [1, ids.length, 2],
        ),
      );
      final pass = _pass(client);
      await pass.load();

      await expectLater(
        _embed(pass, 'abcdef'),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 5)
              .having((e) => e.actualTokens, 'actualTokens', 6),
        ),
      );
      expect(client.runs, isEmpty, reason: 'nothing was cut to fit');

      await _embed(pass, 'abcde');
      expect(client.lastIds, 'abcde'.codeUnits);
    });

    test('padded and unpadded runs of the SAME real values embed to the SAME '
        'vector — padding never leaks into the mean', () async {
      // Dynamic graph: exactly the 3 real rows.
      final unpadded = _pass(
        FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'last_hidden_state',
            hasLastHiddenStateOutput: true,
            staticDim: 2,
          ),
          runResult: (ids, mask, typeIds) => OrtRunResult(
            values: Float32List.fromList([1, 0, 0, 1, 2, 2]),
            shape: const [1, 3, 2],
          ),
        ),
      );
      // Static graph (5): the same 3 rows plus 2 garbage padding rows far
      // outside their range — counted, they would drag the mean away.
      final padded = _pass(
        FakeOrtClient(
          ioSpec: staticSpec,
          runResult: (ids, mask, typeIds) => OrtRunResult(
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
        ),
      );
      await unpadded.load();
      await padded.load();

      final a = await _embed(unpadded, 'abc');
      final b = await _embed(padded, 'abc');

      expect(b, hasLength(a.length));
      for (var i = 0; i < a.length; i++) {
        expect(b[i], closeTo(a[i], 1e-6));
      }
    });
  });

  group('a dynamic-shape graph', () {
    test('declares no limit: maxInputTokens is null and a long input runs '
        'unpadded', () async {
      final client = FakeOrtClient(ioSpec: _sentenceEmbedding);
      final pass = _pass(client);
      final info = await pass.load();
      expect(info.maxInputTokens, isNull);

      await _embed(pass, 'x' * 2000);
      expect(client.lastIds, hasLength(2000));
    });
  });

  group('the dimension probe', () {
    test(
      'a one-token run when the graph declares no output dimension',
      () async {
        final client = FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'sentence_embedding',
            hasLastHiddenStateOutput: false,
          ),
          runResult: (ids, mask, typeIds) =>
              OrtRunResult(values: Float32List(384), shape: const [1, 384]),
        );
        final info = await _pass(client).load();

        expect(info.dimension, 384);
        expect(client.runs.single.ids, [0]);
      },
    );

    test('gets the mask defaulting every run gets — a graph that declares '
        'attention_mask must not see a bare ids-only probe', () async {
      final client = FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
        ),
        runResult: (ids, mask, typeIds) =>
            OrtRunResult(values: Float32List(384), shape: const [1, 384]),
      );
      await _pass(client).load();

      expect(client.runs.single.mask, [1]);
    });

    test('gets static padding too: a static graph sees a full-width probe, '
        'not a length-1 tensor', () async {
      final client = FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids', 'attention_mask'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticSeqLen: 4,
        ),
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List(384 * 4),
          shape: const [1, 4, 384],
        ),
      );
      final info = await _pass(client).load();

      expect(info.dimension, 384);
      expect(client.runs.single.ids, [0, 0, 0, 0]);
      expect(client.runs.single.mask, [1, 0, 0, 0]);
    });
  });

  group('lifecycle', () {
    test('close releases the session exactly once', () async {
      final client = FakeOrtClient(ioSpec: _sentenceEmbedding);
      final pass = _pass(client);
      await pass.load();
      await pass.close();
      await pass.close();
      expect(client.closeCallCount, 1);
    });

    test('embed before load fails', () async {
      final pass = _pass(FakeOrtClient(ioSpec: _sentenceEmbedding));
      await expectLater(_embed(pass, 'a'), throwsStateError);
    });

    test('a probe that throws fails the load, and close then releases the '
        'session the load had opened', () async {
      final client = FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
        ),
        runResult: (ids, mask, typeIds) =>
            throw StateError('probe forward pass failed'),
      );
      final pass = _pass(client);

      await expectLater(
        pass.load(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('probe forward pass failed'),
          ),
        ),
      );
      expect(client.closeCallCount, 0, reason: 'core closes, not the load');
      await pass.close();
      expect(client.closeCallCount, 1);
    });

    test(
      'a probe that rejects the output shape is a load failure too',
      () async {
        final client = FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'sentence_embedding',
            hasLastHiddenStateOutput: false,
          ),
          // Rank 0: the probe cannot read a dimension.
          runResult: (ids, mask, typeIds) =>
              OrtRunResult(values: Float32List(1), shape: const []),
        );
        final pass = _pass(client);

        await expectLater(pass.load(), throwsStateError);
        await pass.close();
        expect(client.closeCallCount, 1);
      },
    );

    test('a session whose own load throws is released by close', () async {
      final client = FakeOrtClient(
        ioSpec: _sentenceEmbedding,
        loadError: StateError('CreateSession failed'),
      );
      final pass = _pass(client);

      await expectLater(pass.load(), throwsStateError);
      await pass.close();
      expect(client.closeCallCount, 1);
    });
  });
}
