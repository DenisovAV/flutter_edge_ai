// Real-device smoke test:
//   flutter test integration_test/builtin_ai_test.dart -d <device-id>
//
// For web, use Flutter's supported integration runner:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/builtin_ai_test.dart -d chrome
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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
    if (!status.isTransient && status != BuiltInAiAvailability.available) {
      await expectLater(
        BuiltInAi.ensureReady(),
        throwsA(isA<BuiltInAiUnavailableException>()),
      );
      return;
    }

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
      debugPrint('[built-in] answer: ${answer.toString()}');
      expect(answer.toString().trim(), isNotEmpty);
    } finally {
      await session?.close();
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
