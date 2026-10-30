// Opt-in STT memory measurement (#747): N transcriptions in a row on one
// recognizer, with the process's memory read before the load, after it, after
// every transcription and after the close. Android only (it reads smaps).
//
// Stage the model and its tokenizer first, under the names below, in
// /data/local/tmp/flutter_gemma_test/:
//   moonshine: moonshine_tiny_5s_f32.tflite + moonshine_tokenizer.json
//   parakeet:  parakeet_ctc_0.6b_5s_f32.tflite + parakeet_tokenizer.json
//   whisper:   whisper_tiny_30s_f32.tflite + whisper_tokenizer.json
// (STT_FILE=<name> runs another file of the same family, e.g.
// parakeet_ctc_0.6b_5s_i8.tflite), then run one model and one backend per
// process, so a kill ends one run only:
//   flutter test integration_test/stt_gpu_memory_test.dart -d <device-id> \
//     --dart-define=STT_MODEL=moonshine --dart-define=STT_BACKEND=gpu \
//     --dart-define=STT_ITERS=20
// On a DDP phone, the same KEY=VALUE pairs go to run_instrumented.sh.
//
// The load itself is where a too-large model dies (#747: Parakeet f32 on the
// GPU is killed inside getActiveStt), and this test never reaches after_load
// then: poll /proc/<pid>/smaps_rollup from adb meanwhile to see that phase.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _model = String.fromEnvironment('STT_MODEL', defaultValue: 'moonshine');
const _backend = String.fromEnvironment('STT_BACKEND', defaultValue: 'gpu');
const _iters = int.fromEnvironment('STT_ITERS', defaultValue: 20);
const _dir = '/data/local/tmp/flutter_gemma_test';

/// Overrides the model file name, e.g. a quantized export of the same family.
const _file = String.fromEnvironment('STT_FILE');

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

int _mb(int? bytes) => bytes == null ? -1 : bytes ~/ (1024 * 1024);

Future<void> _record(String phase, {int? iter, int? ms, String? text}) async {
  final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
  // ignore: experimental_member_use
  final gpu = await FlutterEdgeAiDiagnostics.gpuMemory();
  final status = await File('/proc/self/status').readAsString();
  final rssKb = RegExp(r'VmRSS:\s+(\d+) kB').firstMatch(status)?.group(1);
  // ignore: avoid_print
  print(
    'STT_MEM model=$_model${_file.isEmpty ? '' : '/$_file'} backend=$_backend phase=$phase'
    '${iter == null ? '' : ' iter=$iter'}'
    ' anonMB=${_mb(snapshot.anonymousBytes)}'
    ' fileMB=${_mb(snapshot.fileBackedBytes)}'
    ' availMB=${_mb(snapshot.availableBytes)}'
    ' kgslAnonMB=${_mb(gpu?.inAnonymousBytes)}'
    ' kgslFileMB=${_mb(gpu?.inFileBackedBytes)}'
    ' rssMB=${rssKb == null ? -1 : int.parse(rssKb) ~/ 1024}'
    '${ms == null ? '' : ' ms=$ms'}'
    '${text == null ? '' : ' text="$text"'}',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'STT $_model on $_backend: memory over $_iters transcriptions',
    (_) async {
      final (defaultFile, tokenizerFile, type) = switch (_model) {
        'moonshine' => (
          'moonshine_tiny_5s_f32.tflite',
          'moonshine_tokenizer.json',
          SttModelType.moonshine,
        ),
        'parakeet' => (
          'parakeet_ctc_0.6b_5s_f32.tflite',
          'parakeet_tokenizer.json',
          SttModelType.parakeet,
        ),
        'whisper' => (
          'whisper_tiny_30s_f32.tflite',
          'whisper_tokenizer.json',
          SttModelType.whisper,
        ),
        _ => throw ArgumentError.value(_model, 'STT_MODEL'),
      };
      final modelFile = _file.isEmpty ? defaultFile : _file;
      final backend = PreferredBackend.values.byName(_backend);
      for (final f in [modelFile, tokenizerFile]) {
        expect(
          File('$_dir/$f').existsSync(),
          isTrue,
          reason: 'stage $f in $_dir',
        );
      }

      await _record('before_init');
      await FlutterEdgeAi.initialize(sttBackends: const [LiteRtSttBackend()]);
      await FlutterEdgeAi.installStt()
          .modelFromFile('$_dir/$modelFile')
          .tokenizerFromFile('$_dir/$tokenizerFile')
          .ofType(type)
          .install();

      final wav = await rootBundle.load('assets/test/test_audio.wav');
      final pcm = Uint8List.sublistView(
        wav.buffer.asUint8List(),
        _wavHeaderBytes,
      );

      await _record('before_load');
      final watch = Stopwatch()..start();
      final recognizer = await FlutterEdgeAi.getActiveStt(
        preferredBackend: backend,
      );
      await _record('after_load', ms: watch.elapsedMilliseconds);
      try {
        for (var i = 1; i <= _iters; i++) {
          watch.reset();
          final text = await recognizer.transcribe(pcm);
          final ms = watch.elapsedMilliseconds;
          await _record('after_transcribe', iter: i, ms: ms, text: text);
          expect(text.trim(), isNotEmpty);
        }
      } finally {
        await recognizer.close();
      }
      await _record('after_close');
      // The worker's native teardown and the allocator's return of pages to
      // the OS can trail the close: read again once things have settled.
      await Future<void>.delayed(const Duration(seconds: 10));
      await _record('after_close_10s');
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
