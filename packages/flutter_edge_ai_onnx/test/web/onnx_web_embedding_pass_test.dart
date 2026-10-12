// `OnnxWebEmbeddingPass` over a fake `OrtClient` and a fake URL resolver —
// zero `dart:js_interop`, zero real ORT session. The pass is pure Dart (the
// real `OrtWebClient` and `resolveWebModelUrl` arrive in its config from the
// web backend), so it runs on the VM under plain `flutter test`.
//
// What the browser alone can show — that the web backend wires
// `resolveWebModelUrl`, and a streaming-mode `opfs://` file really loads — is
// the GCE VM's web drive suite. Here: that BOTH paths go through the resolver
// before anything fetches them, plus the pass's routing, output contract,
// probe and lifecycle.

import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/ort_client.dart';
import 'package:flutter_edge_ai_onnx/src/web/onnx_web_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_ort_client.dart';

const _wordPieceGraph = OrtIoSpec(
  inputNames: ['input_ids', 'attention_mask', 'token_type_ids'],
  outputName: 'last_hidden_state',
  hasLastHiddenStateOutput: true,
);

/// The resolver the real backend passes is `resolveWebModelUrl`: `opfs://x`
/// becomes a `blob:` URL, anything else is returned unchanged.
Future<String> _fakeResolve(String path) async => path.startsWith('opfs://')
    ? 'blob:resolved/${path.substring('opfs://'.length)}'
    : path;

OnnxWebEmbeddingPass _pass(
  FakeOrtClient client, {
  CharTokenizer? tokenizer,
  List<String>? tokenizerPaths,
  List<String>? revoked,
  Object? tokenizerError,
  String modelPath = 'blob:model',
  String tokenizerPath = 'blob:tokenizer',
}) {
  final t = tokenizer ?? CharTokenizer();
  return OnnxWebEmbeddingPass(
    OnnxWebEmbeddingConfig(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      tokenizerFactory: (path) async {
        tokenizerPaths?.add(path);
        // The tokenizer reads its file during the factory call: its URL must
        // still be live here.
        expect(revoked ?? const <String>[], isNot(contains(path)));
        final error = tokenizerError;
        if (error != null) throw error;
        return t;
      },
      resolveUrl: _fakeResolve,
      revokeUrl: (url) => revoked?.add(url),
      clientFactory: () => client,
    ),
  );
}

void main() {
  group('opfs:// paths (WebStorageMode.streaming)', () {
    test('the tokenizer factory and the session get RESOLVED URLs, never an '
        'opfs:// path', () async {
      final client = FakeOrtClient(
        ioSpec: _wordPieceGraph,
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List(2 * ids.length),
          shape: [1, ids.length, 2],
        ),
      );
      final tokenizerPaths = <String>[];
      final pass = _pass(
        client,
        tokenizerPaths: tokenizerPaths,
        modelPath: 'opfs://minilm.onnx',
        tokenizerPath: 'opfs://tokenizer.json',
      );

      await pass.load();

      expect(tokenizerPaths, ['blob:resolved/tokenizer.json']);
      expect(client.loadedPaths, ['blob:resolved/minilm.onnx']);
    });

    test('a URL that needs no resolving reaches both unchanged', () async {
      final client = FakeOrtClient(
        ioSpec: const OrtIoSpec(
          inputNames: ['input_ids'],
          outputName: 'sentence_embedding',
          hasLastHiddenStateOutput: false,
          staticDim: 2,
        ),
      );
      final tokenizerPaths = <String>[];
      await _pass(client, tokenizerPaths: tokenizerPaths).load();
      expect(tokenizerPaths, ['blob:tokenizer']);
      expect(client.loadedPaths, ['blob:model']);
    });
  });

  group('object URLs the pass created', () {
    const sentenceGraph = OrtIoSpec(
      inputNames: ['input_ids'],
      outputName: 'sentence_embedding',
      hasLastHiddenStateOutput: false,
      staticDim: 2,
    );

    test('the blob: URLs made for opfs:// paths are revoked once read — not '
        'before', () async {
      final revoked = <String>[];
      final client = FakeOrtClient(
        ioSpec: sentenceGraph,
        // The session reads its URL during load: still live here.
        onLoad: (url) => expect(revoked, isNot(contains(url))),
      );
      await _pass(
        client,
        revoked: revoked,
        modelPath: 'opfs://minilm.onnx',
        tokenizerPath: 'opfs://tokenizer.json',
      ).load();

      expect(
        revoked,
        unorderedEquals([
          'blob:resolved/tokenizer.json',
          'blob:resolved/minilm.onnx',
        ]),
      );
    });

    test('a URL core owns (not opfs://) is never revoked', () async {
      final revoked = <String>[];
      await _pass(
        FakeOrtClient(ioSpec: sentenceGraph),
        revoked: revoked,
      ).load();
      expect(revoked, isEmpty);
    });

    test('a session that fails to load still releases its URL', () async {
      final revoked = <String>[];
      final pass = _pass(
        FakeOrtClient(
          ioSpec: sentenceGraph,
          loadError: StateError('CreateSession failed'),
        ),
        revoked: revoked,
        modelPath: 'opfs://minilm.onnx',
        tokenizerPath: 'opfs://tokenizer.json',
      );
      await expectLater(pass.load(), throwsStateError);
      expect(revoked, contains('blob:resolved/minilm.onnx'));
      await pass.close();
    });

    test('a tokenizer that fails to load still releases its URL', () async {
      final revoked = <String>[];
      final pass = _pass(
        FakeOrtClient(ioSpec: sentenceGraph),
        revoked: revoked,
        tokenizerError: StateError('not a tokenizer'),
        modelPath: 'opfs://minilm.onnx',
        tokenizerPath: 'opfs://tokenizer.json',
      );
      await expectLater(pass.load(), throwsStateError);
      expect(revoked, ['blob:resolved/tokenizer.json']);
      await pass.close();
    });
  });

  group('what the session is fed (design D-T3, web)', () {
    test('mask/typeIds are forwarded when the graph declares them', () async {
      final client = FakeOrtClient(
        ioSpec: _wordPieceGraph,
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List(2 * ids.length)..[0] = 1,
          shape: [1, ids.length, 2],
        ),
      );
      final pass = _pass(
        client,
        tokenizer: CharTokenizer(withMask: true, withTypeIds: true),
      );
      await pass.load();

      await pass.embed(EmbeddingInput.text('abc'), TaskType.none);

      expect(client.lastIds, 'abc'.codeUnits);
      expect(client.lastMask, [1, 1, 1]);
      expect(client.lastTypeIds, [0, 0, 0]);
    });

    test(
      'mask/typeIds are withheld when the graph does not declare them',
      () async {
        final client = FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
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

        await pass.embed(EmbeddingInput.text('abc'), TaskType.none);

        expect(client.lastMask, isNull);
        expect(client.lastTypeIds, isNull);
      },
    );
  });

  group('the graph on web', () {
    test('is dynamic: no padding, no limit (onnxruntime-web reports no static '
        'shape)', () async {
      final client = FakeOrtClient(
        ioSpec: _wordPieceGraph,
        runResult: (ids, mask, typeIds) => OrtRunResult(
          values: Float32List(2 * ids.length)..[0] = 1,
          shape: [1, ids.length, 2],
        ),
      );
      final pass = _pass(client);
      final info = await pass.load();

      expect(info.maxInputTokens, isNull);
      expect(info.dimension, 2, reason: 'probed: the graph declares none');
      expect(client.runs.first.ids, [0], reason: 'the one-token probe');

      await pass.embed(EmbeddingInput.text('x' * 600), TaskType.none);
      expect(client.lastIds, hasLength(600));
    });

    test('last_hidden_state is mean-pooled and normalised; sentence_embedding '
        'is copied verbatim', () async {
      final hidden = _pass(
        FakeOrtClient(
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
        ),
      );
      final pooledPass = _pass(
        FakeOrtClient(
          ioSpec: const OrtIoSpec(
            inputNames: ['input_ids'],
            outputName: 'sentence_embedding',
            hasLastHiddenStateOutput: false,
            staticDim: 2,
          ),
          runResult: pooled([3, 4]),
        ),
      );
      await hidden.load();
      await pooledPass.load();

      final a = await hidden.embed(EmbeddingInput.text('a'), TaskType.none);
      expect(a[0], closeTo(0.6, 1e-6));
      expect(a[1], closeTo(0.8, 1e-6));
      expect(await pooledPass.embed(EmbeddingInput.text('a'), TaskType.none), [
        3,
        4,
      ]);
    });
  });

  group('lifecycle', () {
    test('close releases the session exactly once', () async {
      final client = FakeOrtClient(ioSpec: _wordPieceGraph);
      final pass = _pass(client);
      await pass.load();
      await pass.close();
      await pass.close();
      expect(client.closeCallCount, 1);
    });

    test(
      'a load that fails after the session opened is released by close',
      () async {
        final client = FakeOrtClient(
          ioSpec: _wordPieceGraph,
          runResult: (ids, mask, typeIds) => throw StateError('probe failed'),
        );
        final pass = _pass(client);
        await expectLater(pass.load(), throwsStateError);
        await pass.close();
        expect(client.closeCallCount, 1);
      },
    );

    test('embed before load fails', () async {
      final pass = _pass(FakeOrtClient(ioSpec: _wordPieceGraph));
      await expectLater(
        pass.embed(EmbeddingInput.text('a'), TaskType.none),
        throwsStateError,
      );
    });
  });
}
