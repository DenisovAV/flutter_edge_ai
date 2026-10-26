// B89: uninstallEmbedder, uninstallStt and uninstallTts while the model
// getActiveEmbedder / getActiveStt / getActiveTts built from those files is
// loaded, on the real engines: EmbeddingGemma 2 270m (.litertlm), moonshine
// tiny and Matcha.
//
// uninstallModel closes the inference model built from the file it removes
// (uninstall_loaded_model_test.dart). These three uninstalls do not close
// theirs yet. Each test records what happens to that model — whether it
// still answers from deleted files, whether the shell still caches it, what
// the next getActive* call does, and whether a reinstall gets the old
// instance back — prints it as a `[b89]` line, and then states what the
// uninstall would do if it closed the model, as uninstallModel does. Until
// the fix those last expectations fail; the `[b89]` line is the measurement.
//
// The models are downloaded from Hugging Face (public repos).
// Run: flutter test integration_test/uninstall_loaded_embedder_speech_test.dart -d <id>
//
// No setUp/setUpAll: each test prepares itself (Rule 6b).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtEmbeddingBackend;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    show LiteRtSttBackend, LiteRtTtsBackend;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _sttModelUrl =
    'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_f32.tflite';
const _sttTokenizerUrl =
    'https://huggingface.co/moonshine-ai/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json';
const _ttsUrl =
    'https://huggingface.co/litert-community/Matcha-TTS/resolve/main/';

/// WAV data starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

bool _initialized = false;

Future<void> _ensureInitialized() async {
  if (_initialized) return;
  await FlutterEdgeAi.initialize(
    embeddingBackends: const [LiteRtEmbeddingBackend()],
    sttBackends: const [LiteRtSttBackend()],
    ttsBackends: const [LiteRtTtsBackend()],
  );
  _initialized = true;
}

Future<void> _installEmbedder() => FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(_eg2.url, filename: _eg2.filename)
    .install();

Future<void> _installStt() => FlutterEdgeAi.installStt()
    .modelFromNetwork(_sttModelUrl)
    .tokenizerFromNetwork(_sttTokenizerUrl)
    .ofType(SttModelType.moonshine)
    .install();

Future<void> _installTts() => FlutterEdgeAi.installTts()
    .fromNetwork(_ttsUrl)
    .ofType(TtsModelType.matcha)
    .install();

/// The on-device paths of [spec]'s files.
Future<List<String>> _paths(ModelSpec spec) async => [
  for (final file in spec.files)
    await FlutterEdgeAi.getModelPath(file.filename),
];

/// What [run] ended with: `ok` or its error, a hang included.
Future<String> _outcome(Future<Object?> Function() run) async {
  try {
    await run().timeout(const Duration(seconds: 90));
    return 'ok';
  } catch (e) {
    return '${e.runtimeType}: ${e.toString().split('\n').first}';
  }
}

/// The process's anonymous footprint in MiB (macOS/iOS: phys_footprint).
Future<String> _footprint() async {
  if (!FlutterEdgeAiDiagnostics.isSupported) return 'n/a';
  final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
  final bytes = snapshot.anonymousBytes;
  return bytes == null ? 'n/a' : '${bytes ~/ (1024 * 1024)} MiB';
}

Future<Uint8List> _pcm() async {
  final wav = await rootBundle.load('assets/test/test_audio.wav');
  return Uint8List.sublistView(wav.buffer.asUint8List(), _wavHeaderBytes);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uninstallEmbedder with the embedder loaded', (_) async {
    await _ensureInitialized();
    await _installEmbedder();
    final paths = await _paths(FlutterEdgeAi.activeEmbedderSpec!);
    final before = await _footprint();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    EmbeddingModel? again;
    try {
      final vector = await model.embed(
        EmbeddingInput.text('hello'),
        taskType: TaskType.retrievalQuery,
      );
      expect(vector, hasLength(768));
      final loaded = await _footprint();

      final uninstall = await _outcome(FlutterEdgeAi.uninstallEmbedder);
      final filesLeft = paths.where((p) => File(p).existsSync()).length;
      final closedByUninstall = model.isClosed;
      final cachedAfter = identical(
        FlutterEdgeAiPlugin.instance.initializedEmbeddingModel,
        model,
      );
      final afterUninstall = await _footprint();
      final embedAfter = await _outcome(
        () => model.embed(
          EmbeddingInput.text('hello'),
          taskType: TaskType.retrievalQuery,
        ),
      );
      final getAfter = await _outcome(FlutterEdgeAi.getActiveEmbedder);
      final closedByGet = model.isClosed;

      await _installEmbedder();
      again = await FlutterEdgeAi.getActiveEmbedder();
      final reused = identical(again, model);
      final reusedEmbed = await _outcome(
        () => again!.embed(
          EmbeddingInput.text('hello'),
          taskType: TaskType.retrievalQuery,
        ),
      );
      debugPrint(
        '[b89] embedder: footprint before=$before loaded=$loaded '
        'afterUninstall=$afterUninstall; uninstall=$uninstall '
        'filesLeft=$filesLeft/${paths.length} isClosed=$closedByUninstall '
        'stillCached=$cachedAfter embedAfter=$embedAfter '
        'getActiveEmbedder=$getAfter isClosedAfterGet=$closedByGet '
        'reinstall: sameInstance=$reused embed=$reusedEmbed',
      );

      expect(uninstall, 'ok');
      expect(filesLeft, 0);
      expect(getAfter, startsWith('NoActiveModelError'));
      // What the uninstall would do if it closed the model (B89).
      expect(closedByUninstall, isTrue, reason: 'B89');
      expect(cachedAfter, isFalse, reason: 'B89');
      expect(reused, isFalse, reason: 'B89');
    } finally {
      await again?.close();
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('uninstallStt with the recognizer loaded', (_) async {
    await _ensureInitialized();
    await _installStt();
    final paths = await _paths(FlutterEdgeAi.activeSttSpec!);
    final pcm = await _pcm();
    final recognizer = await FlutterEdgeAi.getActiveStt();
    SpeechRecognizer? again;
    try {
      final transcript = await recognizer.transcribe(pcm);
      expect(transcript.trim(), isNotEmpty);

      final uninstall = await _outcome(FlutterEdgeAi.uninstallStt);
      final filesLeft = paths.where((p) => File(p).existsSync()).length;
      final transcribeAfter = await _outcome(() => recognizer.transcribe(pcm));
      final getAfter = await _outcome(FlutterEdgeAi.getActiveStt);
      final transcribeAfterGet = await _outcome(
        () => recognizer.transcribe(pcm),
      );

      await _installStt();
      again = await FlutterEdgeAi.getActiveStt();
      final reused = identical(again, recognizer);
      debugPrint(
        '[b89] stt: uninstall=$uninstall filesLeft=$filesLeft/${paths.length} '
        'transcribeAfter=$transcribeAfter getActiveStt=$getAfter '
        'transcribeAfterGet=$transcribeAfterGet '
        'reinstall: sameInstance=$reused',
      );

      expect(uninstall, 'ok');
      expect(filesLeft, 0);
      expect(getAfter, startsWith('StateError'));
      // What the uninstall would do if it closed the recognizer (B89).
      expect(transcribeAfter, isNot('ok'), reason: 'B89');
      expect(reused, isFalse, reason: 'B89');
    } finally {
      await again?.close();
      if (!identical(again, recognizer)) await recognizer.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('uninstallTts with the synthesizer loaded', (_) async {
    await _ensureInitialized();
    await _installTts();
    final paths = await _paths(FlutterEdgeAi.activeTtsSpec!);
    final synthesizer = await FlutterEdgeAi.getActiveTts();
    SpeechSynthesizer? again;
    try {
      expect(await synthesizer.synthesize('Hello world.'), isNotEmpty);

      final uninstall = await _outcome(FlutterEdgeAi.uninstallTts);
      final filesLeft = paths.where((p) => File(p).existsSync()).length;
      final synthesizeAfter = await _outcome(
        () => synthesizer.synthesize('Hello world.'),
      );
      final getAfter = await _outcome(FlutterEdgeAi.getActiveTts);

      await _installTts();
      again = await FlutterEdgeAi.getActiveTts();
      final reused = identical(again, synthesizer);
      debugPrint(
        '[b89] tts: uninstall=$uninstall filesLeft=$filesLeft/${paths.length} '
        'synthesizeAfter=$synthesizeAfter getActiveTts=$getAfter '
        'reinstall: sameInstance=$reused',
      );

      expect(uninstall, 'ok');
      expect(filesLeft, 0);
      expect(getAfter, startsWith('StateError'));
      // What the uninstall would do if it closed the synthesizer (B89).
      expect(synthesizeAfter, isNot('ok'), reason: 'B89');
      expect(reused, isFalse, reason: 'B89');
    } finally {
      await again?.close();
      if (!identical(again, synthesizer)) await synthesizer.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
