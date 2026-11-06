// End-to-end check of Step 5 on a real device: streamed audio and barge-in.
//
// Recorded questions go in where the microphone would. The first turn is
// interrupted as soon as its first clause of audio arrives; the second, on the
// same session, must then run to completion as if nothing had happened.
// Downloads Gemma 4 E2B (2.59 GB), moonshine (109 MB) and Inflect (36 MB), all
// ungated.
//
// Not part of CI — it needs a device and those downloads:
//   flutter test integration_test/barge_in_test.dart -d <device-id>
import 'dart:async';
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

  testWidgets('interrupt one answer, then get the next one whole', (
    tester,
  ) async {
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
      streamAudio: true,
    );

    // --- Turn 1: interrupted at its first clause of audio. ---
    final long = await rootBundle.load(
      'integration_test/fixtures/long_question.wav',
    );
    final sw = Stopwatch()..start();
    final first = <VoiceEvent>[];
    var interrupted = false;
    await for (final event in session.runTurn(_pcmOf(long))) {
      first.add(event);
      if (event is VoiceReplyAudioEvent && !interrupted) {
        debugPrint('[barge] first audio after ${sw.elapsedMilliseconds} ms');
        interrupted = true;
        // Not awaited inside the loop: interrupt() waits for the turn to end,
        // and the turn cannot end while this loop is not reading its events.
        unawaited(session.interrupt());
      }
    }
    debugPrint('[barge] turn 1: ${first.map((e) => e.runtimeType).toList()}');
    expect(interrupted, isTrue, reason: 'no audio arrived to interrupt');
    expect(first.last, isA<VoiceTurnInterruptedEvent>());
    // An interrupted turn never delivers the end-of-reply marker.
    expect(
      first.whereType<VoiceReplyAudioEvent>().where((e) => e.isFinal),
      isEmpty,
    );
    final cut = first.last as VoiceTurnInterruptedEvent;
    debugPrint('[barge] partial reply: "${cut.partialReplyText}"');
    debugPrint(
      '[barge] history after interrupt: '
      '${chat.fullHistory.map((m) => '${m.isUser ? 'user' : 'model'}: ${m.text}').toList()}',
    );

    // --- Turn 2: the same session answers the next question in full. ---
    final short = await rootBundle.load(
      'integration_test/fixtures/question.wav',
    );
    final second = await session.runTurn(_pcmOf(short)).toList();
    debugPrint('[barge] turn 2: ${second.map((e) => e.runtimeType).toList()}');
    final reply = second
        .whereType<VoiceReplyTextEvent>()
        .map((e) => e.chunk)
        .join();
    debugPrint('[barge] turn 2 reply: "$reply"');
    expect(second.last, isA<VoiceTurnCompleteEvent>());
    expect(reply.toLowerCase(), contains('paris'));
    final audio = second.whereType<VoiceReplyAudioEvent>().toList();
    expect(audio.last.isFinal, isTrue);
    expect(audio.last.pcm, isEmpty, reason: 'streamed turns end with a marker');
    final spoken = BytesBuilder()..add([for (final a in audio) ...a.pcm]);
    final heardBack = await stt.transcribe(
      _resample(spoken.takeBytes(), audio.first.sampleRate, 16000),
    );
    debugPrint('[barge] heard back: "$heardBack"');
    expect(heardBack.toLowerCase(), contains('paris'));

    await chat.close();
    await inference.close();
    await stt.close();
    await tts.close();
  });
}
