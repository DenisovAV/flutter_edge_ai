// Real-device run, on a device whose built-in AI is available or can be
// downloaded (Apple Intelligence on, a phone on Google's Prompt API list):
//   flutter test integration_test/builtin_ai_test.dart -d <device-id>
//
// The run fails on any other status, so "All tests passed" means an answer
// really came back. To check instead that a device without built-in AI is
// refused with the typed exception:
//   flutter test integration_test/builtin_ai_test.dart -d <device-id> \
//     --dart-define=EXPECT_UNAVAILABLE=true
//
// There is no web command: `flutter drive -d chrome` starts a temporary
// profile, where Chrome has no model and starts no download without a tap.
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _expectUnavailable = bool.fromEnvironment('EXPECT_UNAVAILABLE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('probe, prepare, stream a non-empty answer, and close', (
    tester,
  ) async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [BuiltInAiEngine()],
      webStorageMode: WebStorageMode.streaming,
    );

    final status = await BuiltInAi.availability();
    debugPrint('[built-in] availability: $status');
    final usable =
        status == BuiltInAiAvailability.available || status.isTransient;

    if (_expectUnavailable) {
      expect(usable, isFalse, reason: 'EXPECT_UNAVAILABLE, but $status');
      await expectLater(
        BuiltInAi.ensureReady(),
        throwsA(isA<BuiltInAiUnavailableException>()),
      );
      return;
    }
    expect(
      usable,
      isTrue,
      reason:
          'Built-in AI is $status on this device. Run on a device that '
          'reaches available, or pass --dart-define=EXPECT_UNAVAILABLE=true.',
    );

    await BuiltInAi.ensureReady();
    final spec = BuiltInAiModels.forCurrentPlatform;
    expect(spec, isNotNull);
    await FlutterEdgeAi.installModel(
      modelType: spec!.modelType,
      fileType: ModelFileType.builtIn,
    ).fromBundled(spec.name).install();

    final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
    InferenceModelSession? session;
    try {
      session = await model.createSession();
      await session.addQueryChunk(
        Message.text(
          text: 'Name one planet. Answer in three words.',
          isUser: true,
        ),
      );
      final answer = StringBuffer();
      await for (final chunk in session.getResponseAsync()) {
        answer.write(chunk);
      }
      debugPrint('[built-in] answer: $answer');
      expect(answer.toString().trim(), isNotEmpty);
    } finally {
      await session?.close();
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
