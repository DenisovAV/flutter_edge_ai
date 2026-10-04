// End-to-end check of Step 6 on a real device: a spoken question that the
// model answers by calling one of the app's tools.
//
// Two recorded questions stand in for the microphone. For each, the test
// checks the model called the right tool with sensible arguments, that the
// reply mentions what the tool returned, and — by playing the reply to the
// app's own recognizer — that what the assistant says out loud is that reply.
// Downloads Gemma 4 E2B (2.59 GB), moonshine (109 MB) and Inflect (36 MB), all
// ungated.
//
// Not part of CI — it needs a device and those downloads:
//   flutter test integration_test/tools_test.dart -d <device-id>
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:edge_ai_quickstart/model.dart';
import 'package:edge_ai_quickstart/tools.dart';

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

  testWidgets('spoken questions answered through the tools', (tester) async {
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
      tools: toolbox,
      supportsFunctionCalls: true,
    );
    final calls = <FunctionCallResponse>[];
    final tools = AssistantTools(onTimerDone: (_) {});
    final session = VoiceSession.fromChat(
      recognizer: stt,
      chat: chat,
      synthesizer: tts,
      streamAudio: true,
      onToolCall: (call) {
        calls.add(call);
        return tools.run(call);
      },
    );

    Future<(String reply, String heardBack)> ask(String fixture) async {
      final wav = await rootBundle.load('integration_test/fixtures/$fixture');
      final events = await session.runTurn(_pcmOf(wav)).toList();
      expect(events.last, isA<VoiceTurnCompleteEvent>());
      final reply = events
          .whereType<VoiceReplyTextEvent>()
          .map((e) => e.chunk)
          .join();
      final audio = events.whereType<VoiceReplyAudioEvent>().toList();
      final spoken = BytesBuilder()..add([for (final a in audio) ...a.pcm]);
      final heardBack = await stt.transcribe(
        _resample(spoken.takeBytes(), audio.first.sampleRate, 16000),
      );
      return (reply, heardBack);
    }

    // --- The clock. ---
    final (timeReply, timeHeard) = await ask('time_question.wav');
    debugPrint('[tools] calls: ${calls.map((c) => '${c.name}${c.args}')}');
    debugPrint('[tools] time reply: "$timeReply" | heard: "$timeHeard"');
    expect(calls.map((c) => c.name), ['get_current_time']);
    // What the tool returned, as the model read it out: the hour, at least.
    // The spoken-style instruction often — not always — makes the model write
    // numbers as words, so accept the hour either way: "2:27" or "two".
    const hourWords = [
      'twelve',
      'one',
      'two',
      'three',
      'four',
      'five',
      'six',
      'seven',
      'eight',
      'nine',
      'ten',
      'eleven',
    ];
    final now = DateTime.now();
    final hour12 = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final said = timeReply.toLowerCase();
    expect(
      RegExp('\\b(${now.hour}|$hour12)(:|\\s)').hasMatch(said) ||
          RegExp('\\b${hourWords[hour12 % 12]}\\b').hasMatch(said),
      isTrue,
      reason: 'the hour $hour12 is not in "$timeReply"',
    );

    // --- The timer. ---
    calls.clear();
    final (timerReply, timerHeard) = await ask('timer_question.wav');
    debugPrint('[tools] calls: ${calls.map((c) => '${c.name}${c.args}')}');
    debugPrint('[tools] timer reply: "$timerReply" | heard: "$timerHeard"');
    expect(calls, hasLength(1));
    expect(calls.single.name, 'set_timer');
    expect(calls.single.args['minutes'], 1);
    expect(timerReply.toLowerCase(), contains('timer'));
    expect(timerHeard.toLowerCase(), contains('timer'));

    tools.dispose();
    await chat.close();
    await inference.close();
    await stt.close();
    await tts.close();
  });
}
