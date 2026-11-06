// End-to-end check of Step 4 on a real device: one VoiceSession turn.
//
// A recorded question goes in where the microphone would, and the test reads
// the events the page reads: the transcript, the reply text, the reply audio,
// the end of the turn. The audio is then played to the app's own recognizer —
// if moonshine hears "Paris" in it, it is speech and not noise. Downloads
// Gemma 4 E2B (2.59 GB), moonshine (109 MB) and Inflect (36 MB), all ungated.
//
// Not part of CI — it needs a device and those downloads:
//   flutter test integration_test/loop_test.dart -d <device-id>
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

  testWidgets('one spoken question, one spoken answer', (tester) async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: [LiteRtLmEngine()],
      sttBackends: [const LiteRtSttBackend()],
      ttsBackends: [const LiteRtTtsBackend()],
    );

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

    final stt = await FlutterEdgeAi.getActiveStt();
    final tts = await FlutterEdgeAi.getActiveTts();
    final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    final chat = await inference.createChat(
      modelType: model.modelType,
      systemInstruction:
          'You are a voice assistant. Your reply is read aloud by a speech '
          'synthesizer, so answer in one or two short sentences of plain '
          'spoken English. No markdown, lists, emoji or code.',
      maxOutputTokens: 128,
    );
    final session = VoiceSession.fromChat(
      recognizer: stt,
      chat: chat,
      synthesizer: tts,
    );

    final wav = await rootBundle.load('integration_test/fixtures/question.wav');
    final events = await session.runTurn(_pcmOf(wav)).toList();
    debugPrint('[loop] events: ${events.map((e) => e.runtimeType).toSet()}');

    final transcript = events.whereType<VoiceTranscriptEvent>().single.text;
    final reply = events.whereType<VoiceReplyTextEvent>().map((e) => e.chunk);
    final audio = events.whereType<VoiceReplyAudioEvent>().single;
    final done = events.last;
    debugPrint('[loop] transcript: "$transcript"');
    debugPrint('[loop] reply: "${reply.join()}"');
    expect(transcript.toLowerCase(), contains('france'));
    expect(reply.join().toLowerCase(), contains('paris'));
    // The system instruction asked for plain speech; markdown would be read
    // out as symbols or silently skipped.
    expect(reply.join(), isNot(contains('**')));
    expect(audio.isFinal, isTrue);
    expect(done, isA<VoiceTurnCompleteEvent>());

    final heardBack = await stt.transcribe(
      _resample(audio.pcm, audio.sampleRate, 16000),
    );
    debugPrint('[loop] heard back: "$heardBack"');
    expect(heardBack.toLowerCase(), contains('paris'));

    await chat.close();
    await inference.close();
    await stt.close();
    await tts.close();
  });
}
