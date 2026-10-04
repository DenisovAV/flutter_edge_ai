import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS device: FFI engine + chat', (t) async {
    // Step 1: Initialize plugin and install model
    print('Step 1: Initialize...');
    await registerTestEngines();

    print('Step 2: Install model...');
    await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
        )
        .fromNetwork(
          'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
          token: const String.fromEnvironment('HUGGINGFACE_TOKEN'),
        )
        .install();
    print('Model installed');

    // Step 3: Create model via plugin (FFI path for .litertlm on iOS)
    print('Step 3: Create model...');
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.cpu,
    );
    print('Model created');

    // Step 4: Create session and chat
    print('Step 4: Create session...');
    final session = await model.createSession(temperature: 0.8, topK: 1);
    print('Session created');

    await session.addQueryChunk(const Message(text: 'Say hi', isUser: true));
    print('Waiting for response...');
    final response = await session.getResponse();
    print('Response: $response');
    expect(response, isNotEmpty);

    await session.close();
    await model.close();
    print('iOS DEVICE FFI TEST PASSED');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
