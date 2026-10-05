// ignore_for_file: avoid_print

// Integration test: direct plugin/action level access (bypassing Genkit.generate).
// Run: flutter test integration_test/direct_action_test.dart -d <device>

import 'package:flutter_gemma/flutter_gemma.dart' hide Message, ModelResponse;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

import 'test_helpers.dart';

void main() {
  initIntegrationTest();

  late GenkitFlutterGemmaPlugin plugin;

  testWidgets('DirectAction: setUpAll — install model', (tester) async {
    await initializeGemmaForTest();
    await ensureModelInstalled();

    plugin = GenkitFlutterGemmaPlugin(
      models: [
        FlutterGemmaModelConfig(
          name: kTestModelName,
          modelType: ModelType.functionGemma,
          fileType: TestModelConfig.forCurrentPlatform().fileType,
        ),
      ],
    );
  }, timeout: const Timeout(kInstallTimeout));

  testWidgets('DirectAction: plugin resolve returns Model', (tester) async {
    final action = plugin.resolve(ActionType.model, kTestModelName);
    expect(action, isNotNull, reason: 'resolve() should return a Model action');
    print('[DirectAction] Resolved action: ${action.runtimeType}');
  });

  testWidgets('DirectAction: direct model call', (tester) async {
    final action = plugin.resolve(ActionType.model, kTestModelName);
    expect(action, isNotNull);

    final request = ModelRequest(
      messages: [
        Message(
          role: Role.user,
          content: [TextPart(text: 'Say hi.')],
        ),
      ],
      config: FlutterGemmaModelOptions(maxTokens: 64).toJson(),
    );

    final response = await action!(request) as ModelResponse;
    final text = response.text;
    print('[DirectAction] Direct call response: "$text"');
    expect(text, isNotEmpty, reason: 'Direct model call should return text');
  }, timeout: const Timeout(kInferenceTimeout));

  testWidgets('DirectAction: plugin list returns metadata', (tester) async {
    final metadata = await plugin.list();
    expect(metadata, isNotEmpty, reason: 'list() should return metadata');

    for (final m in metadata) {
      print('[DirectAction] Action: ${m.actionType}/${m.name}');
    }

    final modelMeta = metadata.where((m) => m.actionType == 'model');
    expect(
      modelMeta,
      isNotEmpty,
      reason: 'Should have at least one model action',
    );
    expect(modelMeta.first.name, contains(kTestModelName));
  });
}
