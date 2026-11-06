// End-to-end check of Step 2 on a real device: speech in, text reply out.
//
// The microphone is the one part a test cannot drive, so a recorded question
// stands in for it and goes through the same `transcribe` call the mic button
// uses. Downloads Gemma 4 E2B (2.59 GB) and moonshine (109 MB), both ungated.
//
// Not part of CI — it needs a device and those downloads:
//   flutter test integration_test/hear_test.dart -d <device-id>
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:edge_ai_quickstart/model.dart';

/// The PCM samples of a WAV file: everything after its `data` chunk header.
/// The fixture is already 16 kHz mono 16-bit, which is what `transcribe` takes.
Uint8List _pcmOf(ByteData wav) {
  final bytes = wav.buffer.asUint8List(wav.offsetInBytes, wav.lengthInBytes);
  for (var i = 12; i + 8 <= bytes.length;) {
    final id = String.fromCharCodes(bytes.sublist(i, i + 4));
    final size = wav.getUint32(i + 4, Endian.little);
    if (id == 'data') return bytes.sublist(i + 8, i + 8 + size);
    i += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw StateError('no data chunk');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a spoken question gets a text answer', (tester) async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: [LiteRtLmEngine()],
      sttBackends: [const LiteRtSttBackend()],
    );

    // Unconditionally: `install()` skips files it already has and re-activates
    // them, so the test always runs against these two models.
    const model = Models.gemma4;
    await FlutterEdgeAi.installModel(
      modelType: model.modelType,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(model.url).install();
    await FlutterEdgeAi.installStt()
        .modelFromNetwork(Moonshine.modelUrl)
        .tokenizerFromNetwork(Moonshine.tokenizerUrl)
        .ofType(SttModelType.moonshine)
        .install();
    expect(await FlutterEdgeAi.isModelInstalled(model.fileName), isTrue);
    expect(await FlutterEdgeAi.isModelInstalled(Moonshine.fileName), isTrue);

    final stt = await FlutterEdgeAi.getActiveStt();
    final wav = await rootBundle.load('integration_test/fixtures/question.wav');
    final heard = await stt.transcribe(_pcmOf(wav));
    debugPrint('[hear] transcript: "$heard"');
    expect(heard.toLowerCase(), contains('france'));

    final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    final chat = await inference.createChat(
      modelType: model.modelType,
      maxOutputTokens: 256,
    );
    await chat.addQueryChunk(Message.text(text: heard, isUser: true));
    final reply = StringBuffer();
    await for (final chunk in chat.generateChatResponseAsync()) {
      if (chunk is TextResponse) reply.write(chunk.token);
    }
    debugPrint('[hear] reply: "$reply"');
    expect(reply.toString().toLowerCase(), contains('paris'));

    await chat.close();
    await inference.close();
    await stt.close();
  });
}
