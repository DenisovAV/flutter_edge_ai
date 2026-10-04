import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _url =
    'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS: Gemma3-1B GPU text', (t) async {
    await registerTestEngines();

    await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
        )
        .fromNetwork(
          _url,
          token: const String.fromEnvironment('HUGGINGFACE_TOKEN'),
        )
        .install();

    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
    );

    final session = await model.createSession(temperature: 0.8, topK: 1);
    await session.addQueryChunk(
      const Message(text: 'What is 2+2?', isUser: true),
    );
    final r = await session.getResponse();
    print('[Gemma3-1B GPU] $r');
    expect(r, isNotEmpty);

    await session.close();
    await model.close();
    print('PASSED');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
