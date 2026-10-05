// Host smoke test — REAL ORT-GenAI generation through the real `dart:ffi`
// GenAiFfiClient worker isolate (hardened plan Phase 3, Task 6). Not a fake:
// this is the one file in the inference arm that actually dlopens
// libonnxruntime/libonnxruntime-genai and runs a real decode loop. This is
// also the AOT-adjacent `Isolate.spawn` boundary proof for D4 (paired with
// `onnx_gen_ai_client_isolate_test.dart`'s failure-path spawn/handshake
// proof).
//
// Guarded to skip cleanly when the dylibs/model aren't available locally
// (multi-GB, not checked in) — set:
//   FLUTTER_GEMMA_ORT_GENAI_LIBS=/path/to/dir/containing/both/dylibs
//   ONNX_SMOKE_GENAI_MODEL_DIR=/path/to/dir/containing/genai_config.json+...
// then `flutter test test/onnx_generation_host_smoke_test.dart`.
import 'dart:async';
import 'dart:io';

import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_gemma_onnx/src/onnx_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final libsDir = Platform.environment[genAiLibsDirEnvVar];
  final modelDir = Platform.environment['ONNX_SMOKE_GENAI_MODEL_DIR'];
  final available =
      libsDir != null &&
      libsDir.isNotEmpty &&
      modelDir != null &&
      Directory(modelDir).existsSync() &&
      File('$modelDir/genai_config.json').existsSync();

  test(
    'real ORT-GenAI generation: non-empty text, multiple chunks, stop '
    'truncates, second turn on the same session works, close is clean',
    () async {
      final client = GenAiFfiClient();
      await client.load(modelDir!, contextWindow: 1024);

      final session = OnnxSession(
        client: client,
        modelType: ModelType.phi,
        fileType: ModelFileType.onnx,
        maxOutputTokens: 64,
        onClose: () {},
      );

      // --- Turn 1: full generation, unassisted --------------------------
      await session.addQueryChunk(
        const Message(
          text:
              'Write a detailed, at least 150-word paragraph describing the '
              'water cycle, covering evaporation, condensation, and '
              'precipitation.',
          isUser: true,
        ),
      );

      final chunks = <String>[];
      await for (final chunk in session.getResponseAsync()) {
        chunks.add(chunk);
      }
      final fullText = chunks.join();

      // (a) non-empty streamed text
      expect(fullText.trim(), isNotEmpty);
      // (b) more than one chunk
      expect(chunks.length, greaterThan(1));
      // ignore: avoid_print
      print('[onnx smoke] turn 1 generated text: $fullText');
      final metrics = session.getSessionMetrics();
      // ignore: avoid_print
      print(
        '[onnx smoke] turn 1 metrics: prompt=${metrics.inputTokens} '
        'generated=${metrics.outputTokens} tok/s=${metrics.tokensPerSecond}',
      );

      // --- Turn 2: stopGeneration after a few chunks terminates early ----
      await session.addQueryChunk(
        const Message(
          text:
              'Now write another, completely different long paragraph, '
              'this time about the rock cycle.',
          isUser: true,
        ),
      );
      final turn2Chunks = <String>[];
      final sub = session.getResponseAsync().listen((chunk) {
        turn2Chunks.add(chunk);
      }, onDone: () {});
      // Let a few chunks land, then cut it short.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await session.stopGeneration();
      await sub.asFuture<void>();
      await sub.cancel();

      // (c) stopGeneration after N chunks terminates the stream with fewer
      // than max tokens.
      final turn2Metrics = session.getSessionMetrics();
      // ignore: avoid_print
      print(
        '[onnx smoke] turn 2 (stopped) text: ${turn2Chunks.join()} '
        '(generated=${turn2Metrics.outputTokens})',
      );
      expect(turn2Metrics.outputTokens, lessThan(64));

      // --- Turn 3: the same session still works after a stop -------------
      await session.addQueryChunk(
        const Message(text: 'Say hello in one short sentence.', isUser: true),
      );
      final turn3 = await session.getResponse();
      // (d) second (well, third) turn on the same session succeeds.
      expect(turn3.trim(), isNotEmpty);
      // ignore: avoid_print
      print('[onnx smoke] turn 3 text: $turn3');

      // --- Close: no hang -------------------------------------------------
      // (e) close frees cleanly.
      await session.close().timeout(const Duration(seconds: 10));
      await client.shutdown().timeout(const Duration(seconds: 10));
    },
    skip: available
        ? false
        : 'FLUTTER_GEMMA_ORT_GENAI_LIBS / ONNX_SMOKE_GENAI_MODEL_DIR not '
              'set or the files are absent locally — see this file\'s header.',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'real-worker close-during-generation: stopGeneration() + resetSession() '
    'while a REAL generation is still in flight does not hang or throw, and '
    'the client is reusable afterward — regression guard for the '
    '_defaultWorkerEntry free-after-drain ordering in '
    "ResetSessionRequest/Close (`stopRequested = true; await activeGeneration;` "
    "before OgaDestroyGenerator/Tokenizer/Model in gen_ai_client.dart). "
    'gen_ai_client_lifecycle_test.dart\'s fake-worker test (b) exercises the '
    'same shape against a zero-FFI fake and cannot detect a deleted await '
    'here — only real native handles can actually use-after-free.',
    () async {
      final client = GenAiFfiClient();
      await client.load(modelDir!, contextWindow: 1024);

      final received = <String>[];
      Object? error;
      var done = false;
      final doneCompleter = Completer<void>();
      client
          .generate(
            const GenAiTurn(
              userContent:
                  'Write a detailed, at least 150-word paragraph describing '
                  'the water cycle, covering evaporation, condensation, and '
                  'precipitation.',
              isFirstTurn: true,
            ),
          )
          .listen(
            received.add,
            onError: (Object e) => error = e,
            onDone: () {
              done = true;
              doneCompleter.complete();
            },
          );

      // Give the worker a moment to start prefill/decode before tearing
      // down mid-flight — the goal is to land ResetSessionRequest while the
      // decode loop is genuinely suspended on its per-token yield, not
      // after it has already finished.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await client.stopGeneration();
      await client.resetSession();

      await doneCompleter.future.timeout(const Duration(seconds: 15));

      expect(done, isTrue);
      expect(
        error,
        isNull,
        reason:
            'a mid-stream stop completes the stream normally, never as a '
            'stream error — and never crashes the process via a freed '
            'generator/tokenizer/model handle',
      );

      // The client is still usable: resetSession() destroyed the real
      // generator, so the next turn starts fresh.
      final nextChunks = <String>[];
      await client
          .generate(
            const GenAiTurn(
              userContent: 'Say hello in one short sentence.',
              isFirstTurn: true,
            ),
          )
          .forEach(nextChunks.add);
      expect(nextChunks.join().trim(), isNotEmpty);

      await client.shutdown().timeout(const Duration(seconds: 10));
    },
    skip: available
        ? false
        : 'FLUTTER_GEMMA_ORT_GENAI_LIBS / ONNX_SMOKE_GENAI_MODEL_DIR not '
              'set or the files are absent locally — see this file\'s header.',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
