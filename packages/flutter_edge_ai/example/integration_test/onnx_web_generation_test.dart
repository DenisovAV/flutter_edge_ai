/// Web integration test for ONNX text generation (`OnnxEngine` over
/// Transformers.js).
///
/// Run with:
///   chromedriver --port=4444 &
///   cd example
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/onnx_web_generation_test.dart \
///     -d web-server
///
/// Add `--release` for dart2js and `--release --wasm` for dart2wasm; the
/// interop this suite guards differs per compiler.
///
/// Why it exists: from #449 (1.6.2) until flutter_gemma_onnx 0.5.1 every web
/// generation threw `NoSuchMethodError: tried to call a non-function`. The
/// pipeline was invoked with `callAsFunction`, which compiles to
/// `pipeline.call(...)`, and a Transformers.js pipeline is a closure whose
/// prototype is swapped to `Pipeline.prototype`, so it has no `.call`. Nothing
/// ran generation in a browser, so it shipped. Verified by mutation: putting
/// the `.call` path back turns this suite red.
///
/// The cancel test covers a path that could not run before the fix: interrupt,
/// await the pipeline Promise to settle, release the generation mutex.
///
/// Nothing in CI runs this file — re-run it by hand whenever the
/// `@huggingface/transformers` pin in `example/web/index.html` moves.
///
/// Prerequisites: Chrome with WebGPU, ~500 MB of network for
/// `onnx-community/Qwen2.5-0.5B-Instruct` (Transformers.js caches it).
@TestOn('chrome')
library;

import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_onnx/flutter_edge_ai_onnx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _repoUrl = 'https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct';

InferenceModel? _model;
bool _initialized = false;

Future<InferenceModel> _ensureModel() async {
  // Setup lives in the test body, not a setUpAll: under `flutter drive` a
  // throwing setUp is reported as "All tests passed" (AGENTS.md Rule 6b).
  if (!_initialized) {
    await FlutterEdgeAi.initialize(inferenceEngines: const [OnnxEngine()]);
    _initialized = true;
  }
  if (_model != null) return _model!;
  await FlutterEdgeAi.installModel(
    modelType: ModelType.general,
    fileType: ModelFileType.onnx,
  ).fromNetwork(_repoUrl).install();
  return _model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('ONNX web generation (Transformers.js)', () {
    tearDownAll(() async {
      await _model?.close();
      _model = null;
    });

    testWidgets('streams a non-empty answer', (tester) async {
      final model = await _ensureModel();
      final session = await model.createSession();
      try {
        await session.addQueryChunk(
          const Message(
            text: 'What is the capital of France? One word.',
            isUser: true,
          ),
        );
        final chunks = await session.getResponseAsync().toList();
        final reply = chunks.join();
        expect(chunks, isNotEmpty);
        expect(reply.toLowerCase(), contains('paris'));
      } finally {
        await session.close();
      }
    });

    testWidgets('stopGeneration and a cancelled subscription leave the '
        'session usable', (tester) async {
      final model = await _ensureModel();
      // Greedy: the `paris` check below stands for "the generation lock is
      // free again", so the answer must not depend on sampling.
      final session = await model.createSession(topK: 1);
      try {
        await session.addQueryChunk(
          const Message(
            text: 'Count from 1 to 200, separated by commas.',
            isUser: true,
          ),
        );
        final stopped = <String>[];
        await for (final chunk in session.getResponseAsync()) {
          stopped.add(chunk);
          if (stopped.length == 5) unawaited(session.stopGeneration());
        }
        // 200 numbers take far more than 150 chunks; stopping at 5 must end
        // the stream within a few more.
        expect(stopped.length, lessThan(150));

        await session.addQueryChunk(
          const Message(
            text: 'Write the alphabet with a word for each letter.',
            isUser: true,
          ),
        );
        final cancelled = Completer<void>();
        var received = 0;
        late final StreamSubscription<String> sub;
        sub = session.getResponseAsync().listen(
          (_) {
            if (++received == 3) {
              sub.cancel().then((_) => cancelled.complete());
            }
          },
          onError: (Object e, StackTrace st) {
            if (!cancelled.isCompleted) cancelled.completeError(e, st);
          },
          onDone: () {
            if (!cancelled.isCompleted) cancelled.complete();
          },
        );
        await cancelled.future.timeout(const Duration(minutes: 2));

        // A wedged generation mutex would hang here.
        await session.addQueryChunk(
          const Message(
            text: 'What is the capital of France? One word.',
            isUser: true,
          ),
        );
        final reply = await session.getResponse().timeout(
          const Duration(minutes: 2),
        );
        expect(reply.toLowerCase(), contains('paris'));
      } finally {
        await session.close();
      }
    });
  });
}
