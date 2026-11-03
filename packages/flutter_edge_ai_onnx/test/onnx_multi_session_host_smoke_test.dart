// Host smoke test for independent sessions (#703) — REAL ORT-GenAI through
// the real `dart:ffi` worker: two `openSession` sessions on one loaded model
// must keep separate context, and closing one must not touch the other.
//
// Skips cleanly unless the libraries and a model are available locally:
//   FLUTTER_GEMMA_ORT_GENAI_LIBS=/dir/with/libonnxruntime+libonnxruntime-genai
//   ONNX_SMOKE_GENAI_MODEL_DIR=/dir/with/genai_config.json
//   ONNX_SESSIONS_CONTEXT=512   (optional: max_length, i.e. the KV-cache size)
// (Phi-3.5-mini cpu-int4 is what it was written against.)
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_edge_ai_onnx/src/onnx_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _ask(InferenceModelSession session, String text) async {
  await session.addQueryChunk(Message(text: text, isUser: true));
  return (await session.getResponse()).toLowerCase();
}

String _rssMiB() =>
    '${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(0)} MiB';

void main() {
  final context =
      int.tryParse(Platform.environment['ONNX_SESSIONS_CONTEXT'] ?? '') ?? 512;
  final libsDir = Platform.environment[genAiLibsDirEnvVar];
  final modelDir = Platform.environment['ONNX_SMOKE_GENAI_MODEL_DIR'];
  final available =
      libsDir != null &&
      libsDir.isNotEmpty &&
      modelDir != null &&
      File('$modelDir/genai_config.json').existsSync();

  test(
    'two openSession sessions keep separate context; closing one leaves '
    'the other intact',
    () async {
      final client = GenAiFfiClient();
      // 512 tokens keeps each generator's KV cache at ~384 MiB.
      await client.load(modelDir!, contextWindow: context);
      // ignore: avoid_print
      print('[multi-session] context $context, RSS after load ${_rssMiB()}');
      final model = OnnxInferenceModel(
        client: client,
        maxTokens: context,
        modelType: ModelType.phi,
        activeBackend: null,
        maxConcurrentSessions: 2,
        onClose: () {},
      );
      addTearDown(model.close);

      final a = await model.openSession(topK: 1, maxOutputTokens: 12);
      final b = await model.openSession(topK: 1, maxOutputTokens: 12);
      await expectLater(model.openSession(), throwsStateError);

      await _ask(a, 'My secret word is PINEAPPLE. Reply with OK only.');
      // ignore: avoid_print
      print('[multi-session] RSS after A\'s first turn ${_rssMiB()}');
      await _ask(b, 'My secret word is CACTUS. Reply with OK only.');
      // ignore: avoid_print
      print('[multi-session] RSS after B\'s first turn ${_rssMiB()}');
      const question =
          'What is my secret word? Answer with that one word only.';

      // Interleaved: A, B, A, B — each must answer from its own context.
      final a1 = await _ask(a, question);
      final b1 = await _ask(b, question);
      // ignore: avoid_print
      print('[multi-session] A: "$a1"  B: "$b1"');
      expect(a1, contains('pineapple'));
      expect(a1, isNot(contains('cactus')));
      expect(b1, contains('cactus'));
      expect(b1, isNot(contains('pineapple')));

      // Metrics are each session's own.
      expect(a.getSessionMetrics().inputTokens, isNotNull);
      expect(b.getSessionMetrics().inputTokens, isNotNull);

      // Closing A gives its slot back and leaves B's context alone.
      await a.close();
      // ignore: avoid_print
      print('[multi-session] RSS after A closed ${_rssMiB()}');
      final b2 = await _ask(b, question);
      expect(b2, contains('cactus'));
      final c = await model.openSession(topK: 1, maxOutputTokens: 12);
      final c1 = await _ask(c, question);
      expect(
        c1,
        isNot(contains('pineapple')),
        reason: 'a new session must not inherit the closed one\'s context',
      );
      expect(c1, isNot(contains('cactus')));

      await model.close();
    },
    skip: available
        ? false
        : 'set FLUTTER_GEMMA_ORT_GENAI_LIBS and ONNX_SMOKE_GENAI_MODEL_DIR',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
