// Streaming speech-to-text through the public API: Parakeet CTC int8's
// recognizer (getActiveStt(), streaming not null), fed the bundled
// clip three times over (8.8 s, so full windows and the shift back run) in
// 100 ms chunks as a microphone would, then the clip twice with a flush
// between them, and a batch transcription while a stream runs.
//
// Run: flutter test integration_test/stt_streaming_test.dart -d <device>
//        [--dart-define=STT_MODEL_FILE=<path>/parakeet_ctc_0.6b_5s_i8.tflite
//         --dart-define=STT_TOKENIZER_FILE=<path>/tokenizer.json]
//        [--dart-define=STT_BACKEND=cpu|gpu]
// Without the two files it installs the registry's Parakeet int8 build
// (596 MB).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _modelFile = String.fromEnvironment('STT_MODEL_FILE');
const _tokenizerFile = String.fromEnvironment('STT_TOKENIZER_FILE');

/// `cpu` or `gpu`; empty leaves the backend to the SDK.
const _backend = String.fromEnvironment('STT_BACKEND');

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

Stream<Uint8List> _chunks(Uint8List pcm, {int bytes = 3200}) async* {
  for (var i = 0; i < pcm.length; i += bytes) {
    yield Uint8List.sublistView(
      pcm,
      i,
      i + bytes > pcm.length ? pcm.length : i + bytes,
    );
  }
}

String _transcript(Iterable<TranscriptUpdate> updates) =>
    updates.map((u) => u.confirmedDelta).join().trim();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Parakeet CTC streams the bundled clip', (_) async {
    await FlutterEdgeAi.initialize(sttBackends: const [LiteRtSttBackend()]);
    if (_modelFile.isNotEmpty) {
      await FlutterEdgeAi.installStt()
          .modelFromFile(_modelFile)
          .tokenizerFromFile(_tokenizerFile)
          .ofType(SttModelType.parakeet)
          .install();
    } else {
      final variant = LiteRtSpeechModels.parakeetCtc0_6b.i8;
      expect(variant.supportsStreaming, isTrue);
      await FlutterEdgeAi.installStt().fromCatalog(variant).install();
    }
    final recognizer = await FlutterEdgeAi.getActiveStt(
      preferredBackend: switch (_backend) {
        'cpu' => PreferredBackend.cpu,
        'gpu' => PreferredBackend.gpu,
        _ => null,
      },
    );
    expect(recognizer.streaming, isNotNull, reason: 'Parakeet CTC streams');
    expect(recognizer.streaming!.window, const Duration(seconds: 5));
    final streaming = recognizer;

    final wav = await rootBundle.load('assets/test/test_audio.wav');
    final pcm = Uint8List.sublistView(
      wav.buffer.asUint8List(),
      _wavHeaderBytes,
    );

    // 1. The clip three times, 100 ms at a time.
    final long = Uint8List(pcm.length * 3)
      ..setAll(0, pcm)
      ..setAll(pcm.length, pcm)
      ..setAll(pcm.length * 2, pcm);
    final watch = Stopwatch()..start();
    final updates = await streaming.transcribeStream(_chunks(long)).toList();
    watch.stop();
    final text = _transcript(updates);
    debugPrint(
      'STT-STREAM-TRANSCRIPT<<<$text>>> ${updates.length} updates, '
      '${watch.elapsedMilliseconds} ms for 8.8 s of audio'
      '${_backend.isEmpty ? '' : ' on $_backend'}',
    );
    final low = text.toLowerCase();
    // Each repetition whole, once: the batch model reads the clip as "she had
    // your duck suit in/and greasy wash water all year" (11 words).
    final sentence = RegExp(
      r'she had your duck suit (?:in|and) greasy wash water all year',
    );
    expect(
      sentence.allMatches(low),
      hasLength(3),
      reason: 'each repetition once, none dropped or doubled: "$text"',
    );
    expect(
      low.split(RegExp(r'\s+')),
      hasLength(33),
      reason: 'no word outside the three sentences: "$text"',
    );
    for (var k = 1; k < updates.length; k++) {
      expect(
        updates[k].confirmedUntil >= updates[k - 1].confirmedUntil,
        isTrue,
      );
    }
    expect(updates.last.endpoint, isTrue);
    expect(updates.where((u) => u.endpoint), hasLength(1));
    expect(
      updates.any((u) => !u.endpoint && u.unconfirmed.isNotEmpty),
      isTrue,
      reason: 'partial text before the end of the input',
    );

    // 2. The clip twice in one stream, with a flush after the first: two
    // utterances, each with the sentence.
    final input = StreamController<Uint8List>();
    final all = <TranscriptUpdate>[];
    final done = streaming
        .transcribeStream(input.stream)
        .listen(all.add)
        .asFuture<void>();
    await input.addStream(_chunks(pcm));
    await streaming.flush();
    final first = _transcript(all);
    final split = all.length;
    // A batch transcription waits its turn between two windows.
    final batch = recognizer.transcribe(pcm);
    await input.addStream(_chunks(pcm));
    await input.close();
    await done;
    final second = _transcript(all.sublist(split));
    debugPrint('STT-STREAM-UTTERANCES<<<$first>>><<<$second>>>');
    expect(first.toLowerCase(), contains('greasy wash water'));
    expect(second.toLowerCase(), contains('greasy wash water'));
    expect(all.where((u) => u.endpoint), hasLength(2));
    expect((await batch).toLowerCase(), contains('greasy wash water'));

    await recognizer.close();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
