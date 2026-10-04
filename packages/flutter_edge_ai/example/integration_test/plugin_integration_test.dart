// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://docs.flutter.dev/cookbook/testing/integration/introduction

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('getPlatformVersion test', (tester) async {
    final FlutterEdgeAiPlugin gemma = FlutterEdgeAiPlugin.instance;
    final InferenceModel model = await gemma.createModel(
      modelType: ModelType.general,
    );
    final InferenceModelSession session = await model.createSession();
    final String response = await session.getResponse();
    // The version string depends on the host platform running the test, so
    // just assert that some non-empty string is returned.
    expect(response.isNotEmpty, true);
  });
}
