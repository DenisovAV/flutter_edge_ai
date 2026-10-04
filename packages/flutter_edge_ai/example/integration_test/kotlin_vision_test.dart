/// Test: does Kotlin JNI AAR work with vision on Android?
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _g3n = '/data/local/tmp/flutter_gemma_test/gemma-3n-E2B-it-int4.litertlm';
const _img = '/data/local/tmp/flutter_gemma_test/test_image.jpg';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Kotlin: Gemma3n GPU vision', (t) async {
    await registerTestEngines();

    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
    ).fromFile(_g3n).install();
    print('Gemma3n installed');

    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      maxNumImages: 1,
    );
    print('Gemma3n model created');

    final session = await model.createSession(
      temperature: 0.8,
      topK: 1,
      enableVisionModality: true,
    );
    print('Session created');

    final imgBytes = File(_img).readAsBytesSync();
    print('Image: ${imgBytes.length} bytes');

    await session.addQueryChunk(
      Message(text: 'Describe this image', isUser: true, imageBytes: imgBytes),
    );

    final r = await session.getResponse();
    print('[Kotlin Gemma3n vision] $r');
    expect(r, isNotEmpty);

    await session.close();
    await model.close();
    print('PASSED');
  });
}
