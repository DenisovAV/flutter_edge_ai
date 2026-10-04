// End-to-end check that the quickstart's own API path works: install a model,
// open a chat, stream a reply. Uses the ungated Gemma 4 E2B build so it needs no
// Hugging Face token.
//
// Not part of CI — it downloads ~2.6 GB and needs a real device:
//   flutter test integration_test/quickstart_test.dart -d <device-id>
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:edge_ai_quickstart/model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('install, then stream a reply', (tester) async {
    await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);

    const model = Models.gemma4;

    // Unconditionally, on every run. `install()` is idempotent: on a device
    // that already has the file it skips the download and re-activates the
    // model. Guarding it with `isModelInstalled` would leave whatever a
    // previous run activated in place, and the test would pass against the
    // wrong model.
    var last = -1;
    await FlutterEdgeAi.installModel(
      modelType: model.modelType,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(model.url).withProgress((p) {
      if (p >= last + 25) {
        last = p;
        debugPrint('[quickstart] download $p%');
      }
    }).install();

    expect(await FlutterEdgeAi.isModelInstalled(model.fileName), isTrue);
    expect(FlutterEdgeAi.hasActiveModel(), isTrue);

    final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    final chat = await inference.createChat(
      modelType: model.modelType,
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

    debugPrint('[quickstart] reply: ${buffer.toString().trim()}');
    expect(buffer.toString().trim(), isNotEmpty);

    await inference.close();
  }, timeout: const Timeout(Duration(minutes: 30)));
}
