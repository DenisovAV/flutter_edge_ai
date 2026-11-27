// Streaming speech-to-text at the pace of a microphone: Parakeet CTC fed the
// bundled clip, repeated to 45 s, 100 ms at a time in real time, once per
// latency preset. Measures whether the device keeps up: the time one 5 s
// window takes (a batch transcription of 5 s), and per preset whether the
// stream ends normally or with SpeechStreamOverrunException, and when.
//
// Run: flutter test integration_test/stt_streaming_realtime_test.dart -d <device>
//        --dart-define=STT_MODEL_FILE=<path>/parakeet_ctc_0.6b_5s_i8.tflite
//        --dart-define=STT_TOKENIZER_FILE=<path>/tokenizer.json
//        [--dart-define=STT_BACKEND=cpu|gpu] [--dart-define=STT_SECONDS=45]
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _modelFile = String.fromEnvironment('STT_MODEL_FILE');
const _tokenizerFile = String.fromEnvironment('STT_TOKENIZER_FILE');
const _backend = String.fromEnvironment('STT_BACKEND');
const _seconds = int.fromEnvironment('STT_SECONDS', defaultValue: 45);

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

/// 100 ms of 16 kHz 16-bit mono.
const _chunkBytes = 3200;

/// [pcm] repeated to [seconds], as 100 ms chunks paced in real time: chunk k
/// goes out at k * 100 ms after the start, however long the consumer took.
Stream<Uint8List> _realtime(Uint8List pcm, int seconds) async* {
  final total = seconds * 16000 * 2;
  final watch = Stopwatch()..start();
  var k = 0;
  for (var sent = 0; sent < total; sent += _chunkBytes, k++) {
    final due = Duration(milliseconds: k * 100);
    final wait = due - watch.elapsed;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    final chunk = Uint8List(_chunkBytes);
    for (var i = 0; i < _chunkBytes; i++) {
      chunk[i] = pcm[(sent + i) % pcm.length];
    }
    yield chunk;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Parakeet CTC keeps up with a live microphone, or says not', (
    _,
  ) async {
    expect(_modelFile, isNotEmpty, reason: 'pass STT_MODEL_FILE');
    await FlutterEdgeAi.initialize(sttBackends: const [LiteRtSttBackend()]);
    await FlutterEdgeAi.installStt()
        .modelFromFile(_modelFile)
        .tokenizerFromFile(_tokenizerFile)
        .ofType(SttModelType.parakeet)
        .install();
    final recognizer = await FlutterEdgeAi.getActiveStt(
      preferredBackend: switch (_backend) {
        'cpu' => PreferredBackend.cpu,
        'gpu' => PreferredBackend.gpu,
        _ => null,
      },
    );
    expect(recognizer.streaming, isNotNull);
    final wav = await rootBundle.load('assets/test/test_audio.wav');
    final pcm = Uint8List.sublistView(
      wav.buffer.asUint8List(wav.offsetInBytes, wav.lengthInBytes),
      _wavHeaderBytes,
    );

    // One window's work: a batch transcription of 5 s (warm, then three).
    final fiveSeconds = Uint8List(5 * 16000 * 2);
    for (var i = 0; i < fiveSeconds.length; i++) {
      fiveSeconds[i] = pcm[i % pcm.length];
    }
    await recognizer.transcribe(fiveSeconds);
    final times = <int>[];
    for (var i = 0; i < 3; i++) {
      final w = Stopwatch()..start();
      await recognizer.transcribe(fiveSeconds);
      times.add(w.elapsedMilliseconds);
    }
    times.sort();
    debugPrint(
      'STT-REALTIME window_ms=${times[1]} (of $times) '
      'backend=${_backend.isEmpty ? 'default' : _backend}',
    );

    for (final latency in StreamingLatency.values) {
      final updates = <TranscriptUpdate>[];
      Object? error;
      final watch = Stopwatch()..start();
      final done = Completer<void>();
      recognizer
          .transcribeStream(
            _realtime(pcm, _seconds),
            options: TranscribeStreamOptions(latency: latency),
          )
          .listen(
            updates.add,
            onError: (Object e) => error = e,
            onDone: done.complete,
          );
      await done.future;
      final text = updates.map((u) => u.confirmedDelta).join();
      final sentences = RegExp(
        'greasy wash water',
      ).allMatches(text.toLowerCase()).length;
      debugPrint(
        'STT-REALTIME latency=${latency.name} '
        'outcome=${error == null ? 'completed' : error.runtimeType} '
        'after_ms=${watch.elapsedMilliseconds} '
        'audio_s=$_seconds updates=${updates.length} sentences=$sentences'
        '${error == null ? '' : ' error="$error"'}',
      );
      // Either it kept up and transcribed, or it said it could not.
      if (error == null) {
        expect(sentences, greaterThan(0), reason: text);
      } else {
        expect(error, isA<SpeechStreamOverrunException>());
      }
    }
    await recognizer.close();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
