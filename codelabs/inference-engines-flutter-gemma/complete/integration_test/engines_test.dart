// End-to-end check of the engine switch on a real device or emulator.
//
// Exercises both arms of the startup policy: the built-in model is probed and
// either used — chatted through, to prove the gate's readiness rule holds — or,
// on a device without one (an emulator, say), reported as a typed
// BuiltInAiUnavailableException; the downloaded model then answers on
// LiteRT-LM. Uses the ungated Gemma 4 E2B build so it needs no Hugging Face token.
//
// Not part of CI (needs a device, may download ~2.6 GB):
//   flutter test integration_test/engines_test.dart -d <device-id>
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:edge_ai_quickstart/download_page.dart';
import 'package:edge_ai_quickstart/model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('probe the OS model, fall back to LiteRT-LM, stream a reply', (
    tester,
  ) async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: [LiteRtLmEngine(), const BuiltInAiEngine()],
    );

    final status = await BuiltInAi.availability();
    debugPrint('[engines] built-in availability: $status');

    final builtInUsable = switch (status) {
      BuiltInAiAvailability.available ||
      BuiltInAiAvailability.downloadable ||
      BuiltInAiAvailability.downloading => true,
      _ => false,
    };

    if (!builtInUsable) {
      // The failure must be typed, not a generic platform error — that is
      // what lets the app pick a fallback instead of crashing.
      await expectLater(
        activate(Models.builtIn),
        throwsA(isA<BuiltInAiUnavailableException>()),
      );
      debugPrint(
        '[engines] built-in refused with a typed exception, as designed',
      );
    } else {
      await activate(Models.builtIn);
      // The gate's readiness rule for a built-in model: NOT `isModelInstalled`
      // (there is no file and no install record, so that is always false) but
      // "the OS says available, and this is the active model". Assert both,
      // then actually chat through it — a built-in model that activates but
      // cannot answer is exactly the bug this arm exists to catch.
      expect(await FlutterEdgeAi.isModelInstalled(Models.builtIn.id), isFalse);
      expect(FlutterEdgeAi.hasActiveModel(), isTrue);
      expect(await BuiltInAi.availability(), BuiltInAiAvailability.available);

      final builtIn = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      final builtInChat = await builtIn.createChat(
        modelType: Models.builtIn.modelType,
        maxOutputTokens: 64,
      );
      await builtInChat.addQueryChunk(
        Message.text(
          text: 'Name one planet. Answer in three words.',
          isUser: true,
        ),
      );
      final builtInReply = StringBuffer();
      await for (final chunk in builtInChat.generateChatResponseAsync()) {
        if (chunk is TextResponse) builtInReply.write(chunk.token);
      }
      debugPrint('[engines] reply via built-in: ${builtInReply.toString()}');
      expect(builtInReply.toString().trim(), isNotEmpty);
      await builtIn.close();
    }

    // Whatever the OS said, the downloaded model must work on this device.
    const fallback = Models.gemma4;
    var last = -1;
    await activate(
      fallback,
      onProgress: (p) {
        if (p >= last + 25) {
          last = p;
          debugPrint('[engines] download $p%');
        }
      },
    );
    expect(await FlutterEdgeAi.isModelInstalled(fallback.id), isTrue);

    final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    final chat = await inference.createChat(
      modelType: fallback.modelType,
      maxOutputTokens: 64,
    );
    await chat.addQueryChunk(
      Message.text(
        text: 'Name one planet. Answer in three words.',
        isUser: true,
      ),
    );
    final buffer = StringBuffer();
    await for (final chunk in chat.generateChatResponseAsync()) {
      if (chunk is TextResponse) buffer.write(chunk.token);
    }
    debugPrint('[engines] reply via LiteRT-LM: ${buffer.toString().trim()}');
    expect(buffer.toString().trim(), isNotEmpty);

    await inference.close();
  }, timeout: const Timeout(Duration(minutes: 30)));
}
