// End-to-end check of Step 3 on a real device: speech in, speech out.
//
// The microphone and the speaker are the two parts a test cannot use, so a
// recorded question stands in for the first, and for the second the test
// listens to the synthesized answer with the app's own recognizer: if
// moonshine hears "Paris" in it, it is speech and not noise. Downloads
// Gemma 4 E2B (2.59 GB), moonshine (109 MB) and Inflect (36 MB), all ungated.
//
// Not part of CI — it needs a device and those downloads:
//   flutter test integration_test/speak_test.dart -d <device-id>
import 'dart:typed_data';

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

/// Linear resampling of 16-bit mono PCM. Inflect speaks at 24 kHz and
/// moonshine listens at 16 kHz; a test only needs it intelligible, not pretty.
Uint8List _resample(Uint8List pcm, int from, int to) {
  final src = pcm.buffer.asInt16List(pcm.offsetInBytes, pcm.lengthInBytes ~/ 2);
  final out = Int16List((src.length * to / from).floor());
  for (var i = 0; i < out.length; i++) {
    final pos = i * from / to;
    final j = pos.floor();
    final next = j + 1 < src.length ? src[j + 1] : src[j];
    out[i] = (src[j] + (next - src[j]) * (pos - j)).round();
  }
  return out.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a spoken question gets a text answer', (tester) async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: [LiteRtLmEngine()],
      sttBackends: [const LiteRtSttBackend()],
      ttsBackends: [const LiteRtTtsBackend()],
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
    await FlutterEdgeAi.installTts()
        .fromNetwork(Inflect.baseUrl)
        .ofType(TtsModelType.inflect)
        .install();
    expect(await FlutterEdgeAi.isModelInstalled(model.fileName), isTrue);
    expect(await FlutterEdgeAi.isModelInstalled(Moonshine.fileName), isTrue);

    final stt = await FlutterEdgeAi.getActiveStt();
    final wav = await rootBundle.load('integration_test/fixtures/question.wav');
    final heard = await stt.transcribe(_pcmOf(wav));
    debugPrint('[speak] transcript: "$heard"');
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
    debugPrint('[speak] reply: "$reply"');
    expect(reply.toString().toLowerCase(), contains('paris'));

    final tts = await FlutterEdgeAi.getActiveTts();
    final spoken = await tts.synthesize(reply.toString());
    final seconds = spoken.length / 2 / tts.sampleRate;
    debugPrint('[speak] ${tts.sampleRate} Hz, ${seconds.toStringAsFixed(2)} s');
    expect(seconds, greaterThan(0.5));

    // Listen to it. Only the first five seconds fit moonshine's window, and
    // "Paris" is in the first few words.
    final heardBack = await stt.transcribe(
      _resample(spoken, tts.sampleRate, 16000),
    );
    debugPrint('[speak] heard back: "$heardBack"');
    expect(heardBack.toLowerCase(), contains('paris'));
    await tts.close();

    await chat.close();
    await inference.close();
    await stt.close();
  });
}
