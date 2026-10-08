// Regression tests for macOS desktop SIGSEGV crashes (issue #219).
//
// Bug A — Missing Metal accelerator (deterministic first-message crash):
//   setup_desktop.sh does not download libLiteRtLmMetalAccelerator.dylib.
//   LiteRT-LM falls through Metal → WebGPU → CPU sampler fallback.
//   GPU execution + CPU sampler mismatch → null tensor buffer → SIGSEGV.
//
// Bug B — gRPC callbackFlow race (non-deterministic crash after disconnect):
//   awaitClose { } is empty in chat()/chatWithImage()/chatWithAudio().
//   When the Dart gRPC client disconnects, the coroutine exits immediately,
//   but native sendMessageAsync still holds MessageCallback → SIGSEGV in
//   jni_CallVoidMethodV.
//
// TDD order: run these tests BEFORE applying fixes to confirm they fail,
// then apply fixes and confirm they pass.
//
// Prerequisites:
//   Copy a .litertlm model to the app sandbox container:
//   cp ~/Downloads/gemma-3n-E2B-it-int4.litertlm \
//      ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/
//
// Run:
//   cd example
//   flutter test integration_test/desktop_crash_regression_test.dart -d macos \
//     2>&1 | tee /tmp/desktop_crash_regression.log

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

// Default model for groups A/B. Must be pre-installed in the sandbox.
const _modelFileName = 'gemma-3n-E2B-it-int4.litertlm';

// Qwen model that triggered the original issue #219 crash.
// Use for group C (issue reproduction) tests.
const _qwenModelFileName =
    'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm';

String _resolveModelPath([String? fileName]) {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/Documents/${fileName ?? _modelFileName}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String modelPath;

  setUpAll(() {
    if (!Platform.isMacOS) {
      fail(
        'These tests target macOS desktop only. Skipping on ${Platform.operatingSystem}.',
      );
    }
    modelPath = _resolveModelPath();
    if (!File(modelPath).existsSync()) {
      fail(
        'Model not found: $modelPath\n'
        'Copy a .litertlm model to the sandbox:\n'
        '  cp ~/Downloads/$_modelFileName \\\n'
        '     ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/',
      );
    }
  });

  // ──────────────────────────────────────────────────
  // Group A: Metal accelerator (Bug A)
  // ──────────────────────────────────────────────────
  group('Metal accelerator (Bug A)', () {
    // A1: No "WebGPU sampler not available" warning in server logs.
    //     If libLiteRtLmMetalAccelerator.dylib is missing, LiteRT-LM falls to
    //     WebGPU → CPU, and logs this warning. Fix: dylib must be present.
    //     NOTE: We cannot intercept server stderr from Dart; this test instead
    //     verifies that initialization + first message succeeds without crash,
    //     which is the observable symptom of the missing dylib.
    testWidgets(
      'A1: first message completes without crash (Metal accelerator present)',
      (tester) async {
        await registerTestEngines();

        await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
        ).fromFile(modelPath).install();

        expect(FlutterEdgeAi.hasActiveModel(), isTrue);

        final model = await FlutterEdgeAi.getActiveModel(
          maxTokens: 256,
          preferredBackend: PreferredBackend.gpu,
        );

        try {
          final chat = await model.createChat();
          await chat.addQueryChunk(
            const Message(text: 'Say "hello"', isUser: true),
          );

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final response in chat.generateChatResponseAsync()) {
              if (response is TextResponse) {
                chunks.add(response.token);
              }
            }
          });

          final text = chunks.join();
          debugPrint(
            '[A1] Response: "${text.length > 80 ? text.substring(0, 80) : text}"',
          );
          expect(
            text,
            isNotEmpty,
            reason:
                'First message must produce a response. '
                'SIGSEGV here = Metal accelerator missing (Bug A).',
          );
        } finally {
          await model.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    // A2: Three consecutive messages in the same chat session do not crash.
    //     Without Metal accelerator, the first decode already crashes.
    //     This test ensures all three complete, giving extra signal that GPU
    //     execution is fully stable.
    testWidgets('A2: three consecutive messages complete without crash', (
      tester,
    ) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 256,
        preferredBackend: PreferredBackend.gpu,
      );

      try {
        final chat = await model.createChat();

        for (var i = 1; i <= 3; i++) {
          await chat.addQueryChunk(
            Message(
              text: 'Message $i: reply with just the number $i',
              isUser: true,
            ),
          );

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final response in chat.generateChatResponseAsync()) {
              if (response is TextResponse) {
                chunks.add(response.token);
              }
            }
          });

          final text = chunks.join();
          debugPrint(
            '[A2] Message $i response: "${text.length > 60 ? text.substring(0, 60) : text}"',
          );
          expect(
            text,
            isNotEmpty,
            reason:
                'Message $i must produce a response. '
                'SIGSEGV here = Metal accelerator missing (Bug A).',
          );
        }
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  // ──────────────────────────────────────────────────
  // Group B: callbackFlow race condition (Bug B)
  // ──────────────────────────────────────────────────
  group('callbackFlow race condition (Bug B)', () {
    // B1: Sequential chat sessions — open model, chat, close, repeat 3x.
    //     The non-deterministic crash (Bug B) most often manifests when
    //     model.close() races with an ongoing sendMessageAsync. Repeating
    //     close/reopen increases the chance of triggering the race.
    testWidgets('B1: sequential open/chat/close cycles do not crash the server', (
      tester,
    ) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();

      for (var cycle = 1; cycle <= 3; cycle++) {
        debugPrint('[B1] Cycle $cycle/3 — opening model...');
        final model = await FlutterEdgeAi.getActiveModel(
          maxTokens: 128,
          preferredBackend: PreferredBackend.gpu,
        );

        try {
          final chat = await model.createChat();
          await chat.addQueryChunk(
            Message(text: 'Cycle $cycle: say "ok"', isUser: true),
          );

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final response in chat.generateChatResponseAsync()) {
              if (response is TextResponse) {
                chunks.add(response.token);
              }
            }
          });

          final text = chunks.join();
          debugPrint(
            '[B1] Cycle $cycle response: "${text.length > 60 ? text.substring(0, 60) : text}"',
          );
          expect(
            text,
            isNotEmpty,
            reason: 'Cycle $cycle must produce a response.',
          );
        } finally {
          await model.close();
          debugPrint('[B1] Cycle $cycle/3 — model closed');
        }

        // Brief pause between cycles to allow gRPC teardown.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }, timeout: const Timeout(Duration(minutes: 15)));

    // B2: Client disconnects while streaming — close model mid-response.
    //     model.close() triggers gRPC channel teardown which cancels the
    //     callbackFlow coroutine. Without the fix, the empty awaitClose { }
    //     lets the coroutine exit while native sendMessageAsync is still
    //     running → SIGSEGV in jni_CallVoidMethodV.
    //     After the fix, awaitClose calls cancelProcess() and waits up to 5s.
    //
    //     Success criterion: after the mid-stream close, a NEW model instance
    //     can be created and a full response received (server is still alive).
    testWidgets('B2: mid-stream disconnect does not crash server', (
      tester,
    ) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();

      // First request: close the model after receiving just the first chunk.
      debugPrint('[B2] Starting first request (will disconnect mid-stream)...');
      final model1 = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );

      await model1.createChat().then((chat) async {
        await chat.addQueryChunk(
          const Message(
            text: 'Write a very long story about a dragon. At least 500 words.',
            isUser: true,
          ),
        );

        var chunksReceived = 0;
        try {
          await tester.runAsync(() async {
            await for (final response in chat.generateChatResponseAsync()) {
              if (response is TextResponse && response.token.isNotEmpty) {
                chunksReceived++;
                if (chunksReceived >= 3) {
                  // Disconnect mid-stream by closing the model.
                  debugPrint(
                    '[B2] Disconnecting mid-stream after $chunksReceived chunks...',
                  );
                  break;
                }
              }
            }
          });
        } catch (_) {
          // Expected: stream may throw when we break out.
        }
      });

      await model1.close();
      debugPrint('[B2] model1 closed (mid-stream disconnect done)');

      // Give native code time to race (makes Bug B more likely to manifest).
      await Future<void>.delayed(const Duration(seconds: 2));

      // Second request: server must still be alive.
      debugPrint(
        '[B2] Starting second request (verifying server is still alive)...',
      );
      final model2 = await FlutterEdgeAi.getActiveModel(
        maxTokens: 128,
        preferredBackend: PreferredBackend.gpu,
      );

      try {
        final chat2 = await model2.createChat();
        await chat2.addQueryChunk(
          const Message(text: 'Say "alive"', isUser: true),
        );

        final chunks = <String>[];
        await tester.runAsync(() async {
          await for (final response in chat2.generateChatResponseAsync()) {
            if (response is TextResponse) {
              chunks.add(response.token);
            }
          }
        });

        final text = chunks.join();
        debugPrint(
          '[B2] Second response: "${text.length > 80 ? text.substring(0, 80) : text}"',
        );
        expect(
          text,
          isNotEmpty,
          reason:
              'Server must still respond after mid-stream disconnect. '
              'If SIGSEGV occurred in the first request, this will time out or throw. '
              'See issue #219 (Bug B: empty awaitClose race condition).',
        );
      } finally {
        await model2.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  // ──────────────────────────────────────────────────
  // Group C: Issue #219 reproduction with Qwen 2.5
  // Uses the exact model that triggered the original crash.
  // ──────────────────────────────────────────────────
  group('Issue #219 reproduction (Qwen 2.5)', () {
    late String qwenModelPath;

    setUpAll(() {
      qwenModelPath = _resolveModelPath(_qwenModelFileName);
      if (!File(qwenModelPath).existsSync()) {
        fail(
          'Qwen model not found: $qwenModelPath\n'
          'Download from HuggingFace:\n'
          '  curl -L "https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/$_qwenModelFileName" \\\n'
          '    -o ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/$_qwenModelFileName',
        );
      }
    });

    // C1: First message on Qwen 2.5 does not crash (original issue #219 repro).
    //     Before fixes: SIGSEGV in nativeSendMessageAsync on first decode.
    //     Stack: jni_CallVoidMethodV → nativeSendMessageAsync → Tasks::Decode
    //     After Fix B: awaitClose waits for native code → no dangling callback.
    testWidgets('C1: first message on Qwen 2.5 does not crash', (tester) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: ModelType.qwen,
        fileType: ModelFileType.litertlm,
      ).fromFile(qwenModelPath).install();

      expect(FlutterEdgeAi.hasActiveModel(), isTrue);

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.gpu,
      );

      try {
        final chat = await model.createChat();
        await chat.addQueryChunk(
          const Message(text: 'Say "hello"', isUser: true),
        );

        final chunks = <String>[];
        await tester.runAsync(() async {
          await for (final response in chat.generateChatResponseAsync()) {
            if (response is TextResponse) {
              chunks.add(response.token);
            }
          }
        });

        final text = chunks.join();
        debugPrint(
          '[C1] Qwen response: "${text.length > 80 ? text.substring(0, 80) : text}"',
        );
        expect(
          text,
          isNotEmpty,
          reason:
              'First message on Qwen 2.5 must complete without SIGSEGV. '
              'Original crash: jni_CallVoidMethodV → nativeSendMessageAsync '
              '→ Tasks::Decode. See issue #219.',
        );
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    // C2: Several messages on Qwen 2.5 do not crash.
    //     The original reporter said crash happens "after some messages".
    //     This test sends 5 messages to increase crash probability.
    testWidgets('C2: five consecutive messages on Qwen 2.5 do not crash', (
      tester,
    ) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: ModelType.qwen,
        fileType: ModelFileType.litertlm,
      ).fromFile(qwenModelPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.gpu,
      );

      try {
        final chat = await model.createChat();

        for (var i = 1; i <= 5; i++) {
          await chat.addQueryChunk(
            Message(
              text: 'Message $i: reply with just the number $i',
              isUser: true,
            ),
          );

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final response in chat.generateChatResponseAsync()) {
              if (response is TextResponse) {
                chunks.add(response.token);
              }
            }
          });

          final text = chunks.join();
          debugPrint(
            '[C2] Msg $i: "${text.length > 60 ? text.substring(0, 60) : text}"',
          );
          expect(
            text,
            isNotEmpty,
            reason:
                'Message $i on Qwen 2.5 must complete. SIGSEGV here = issue #219 not fixed.',
          );
        }
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    // C3: Disconnect during prefill — the most reliable way to trigger Bug B.
    //     Prefill takes ~1-2s on Qwen 2.5. We start generation and close the
    //     model after a short delay, before the first token arrives.
    //     At that moment native sendMessageAsync is guaranteed to be running.
    //     Without Fix B: awaitClose { } exits immediately → SIGSEGV.
    //     After Fix B: cancelProcess() + done.await() → clean shutdown.
    //
    //     Success: a subsequent request on a NEW model instance works,
    //     proving the server did not crash.
    testWidgets('C3: disconnect during prefill does not crash server', (
      tester,
    ) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: ModelType.qwen,
        fileType: ModelFileType.litertlm,
      ).fromFile(qwenModelPath).install();

      // Long prompt forces a slow prefill (~1-2s), giving us a reliable window
      // to disconnect before the first decode token arrives.
      const longPrompt =
          'Please write a very detailed essay about the history of computing, '
          'starting from Charles Babbage and Ada Lovelace, through ENIAC, '
          'transistors, integrated circuits, personal computers, the internet, '
          'smartphones, and modern AI. Include technical details about each era. '
          'This should be at least 2000 words.';

      for (var attempt = 1; attempt <= 3; attempt++) {
        debugPrint(
          '[C3] Attempt $attempt/3 — starting generation then disconnecting during prefill...',
        );

        final model1 = await FlutterEdgeAi.getActiveModel(
          maxTokens: 2048,
          preferredBackend: PreferredBackend.gpu,
        );

        // Start generation and close immediately — race is guaranteed if
        // prefill hasn't finished yet (typically ~1s for this prompt).
        bool streamStarted = false;
        final streamFuture = tester.runAsync(() async {
          try {
            final chat = await model1.createChat();
            await chat.addQueryChunk(
              const Message(text: longPrompt, isUser: true),
            );
            await for (final response in chat.generateChatResponseAsync()) {
              if (response is TextResponse && response.token.isNotEmpty) {
                streamStarted = true;
                // First token received — stop consuming, trigger disconnect.
                break;
              }
            }
          } catch (_) {
            // Expected: stream throws when model is closed mid-generation.
          }
        });

        // Close the model 2s after starting — prefill takes ~4s on this prompt,
        // so this hits squarely in the middle of prefill execution.
        await Future<void>.delayed(const Duration(seconds: 2));
        await model1.close();
        debugPrint(
          '[C3] Attempt $attempt: model1 closed (streamStarted=$streamStarted)',
        );

        // Wait for the stream future to settle.
        await streamFuture;

        // Give native code time to invoke the callback on a dead coroutine.
        await Future<void>.delayed(const Duration(seconds: 1));

        // If server crashed (SIGSEGV), the next model creation or request
        // will fail / hang. This is the observable test signal.
        debugPrint(
          '[C3] Attempt $attempt — verifying server is still alive...',
        );
        final model2 = await FlutterEdgeAi.getActiveModel(
          maxTokens: 64,
          preferredBackend: PreferredBackend.gpu,
        );

        try {
          final chat2 = await model2.createChat();
          await chat2.addQueryChunk(
            const Message(text: 'Say "ok"', isUser: true),
          );

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final response in chat2.generateChatResponseAsync()) {
              if (response is TextResponse) chunks.add(response.token);
            }
          });

          final text = chunks.join();
          debugPrint(
            '[C3] Attempt $attempt alive-check: "${text.length > 50 ? text.substring(0, 50) : text}"',
          );
          expect(
            text,
            isNotEmpty,
            reason:
                'Server crashed after attempt $attempt disconnect during prefill. '
                'Bug B: empty awaitClose let coroutine exit while native code ran. '
                'See issue #219.',
          );
        } finally {
          await model2.close();
        }

        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  });
}
