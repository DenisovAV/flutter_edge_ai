// Benchmark comparison: Gemma 3 Nano E2B vs Gemma 4 E2B on Android (LiteRT-LM)
//
// Prerequisites:
//   adb push /path/to/gemma-3n-E2B-it-int4.litertlm /data/local/tmp/flutter_gemma_test/
//   adb push /path/to/gemma-4-E2B-it.litertlm /data/local/tmp/flutter_gemma_test/
//
// Run:
//   cd example
//   flutter test integration_test/benchmark_comparison_test.dart -d <device>

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';

import 'benchmark_peak_sampler.dart';
import 'inference_test_helpers.dart';

// --- Model configs ---

const _deviceDir = '/data/local/tmp/flutter_gemma_test';

/// The backend every phase asks for. Recorded in each result next to the one
/// that actually ran, so the two cannot drift apart.
const _requestedBackend = PreferredBackend.gpu;

/// How often the sampled peak reads memory while a load or a prompt runs, in
/// milliseconds; 0 switches the sampler off (`interval_ms: null` in the JSON).
/// Set with `--dart-define=PEAK_INTERVAL_MS=250`.
///
/// One read of `smaps_rollup` took ~150 ms on the vivo 1933 (Android 11, kernel
/// 4.9), so this cannot be small: sampling every 250 ms delayed the first token
/// by +3.8% overall (+14% to +23% on short prompts), every 1000 ms by +1.5%.
/// The read also costs more on kernels before 5.10, where the `smaps_rollup`
/// walk holds `mmap_lock` and stalls the model's threads. Every record carries
/// `read_ms`, so its own bias is visible; run with 0 for clean timings.
const _peakIntervalMs = int.fromEnvironment(
  'PEAK_INTERVAL_MS',
  defaultValue: 1000,
);

const _models = <_BenchmarkModelConfig>[
  _BenchmarkModelConfig(
    name: 'Gemma 4 E2B',
    filePath: '$_deviceDir/gemma-4-E2B-it.litertlm',
    filename: 'gemma-4-E2B-it.litertlm',
  ),
  _BenchmarkModelConfig(
    name: 'Gemma 3 Nano E2B',
    filePath: '$_deviceDir/gemma-3n-E2B-it-int4.litertlm',
    filename: 'gemma-3n-E2B-it-int4.litertlm',
  ),
];

class _BenchmarkModelConfig {
  final String name;
  final String filePath;
  final String filename;

  const _BenchmarkModelConfig({
    required this.name,
    required this.filePath,
    required this.filename,
  });
}

// --- Benchmark result ---

class BenchmarkResult {
  final String modelName;
  final String testCategory;
  final String testName;
  final String question;
  final String response;
  final int durationMs;
  final int firstTokenMs;
  final DateTime timestamp;
  final BenchmarkMemory memory;

  BenchmarkResult({
    required this.modelName,
    required this.testCategory,
    required this.testName,
    required this.question,
    required this.response,
    required this.durationMs,
    required this.firstTokenMs,
    required this.timestamp,
    required this.memory,
  });

  Map<String, dynamic> toJson() => {
    'model': modelName,
    'category': testCategory,
    'test': testName,
    'question': question,
    'response': response,
    'duration_ms': durationMs,
    'first_token_ms': firstTokenMs,
    'timestamp': timestamp.toIso8601String(),
    // What decides whether two records' numbers can be compared: available
    // memory is device-wide MemAvailable on Android but per-app headroom on
    // iOS, and anonymous memory understates a GPU model.
    'platform': Platform.operatingSystem,
    'backend': {
      'requested': _requestedBackend.name,
      'active': memory.activeBackend?.name,
    },
    'memory': memory.toJson(),
  };
}

// --- Memory ---

/// Anonymous bytes around one model load, the backend that ran, and any read
/// errors (null bytes where unreadable). One per phase, shared by every record
/// of that phase.
typedef LoadMemory = ({
  int? before,
  int? after,
  PeakReading peak,
  PreferredBackend? activeBackend,
  List<String> errors,
});

/// What the OS charged this app around one prompt, from
/// `flutter_edge_ai_diagnostics`.
///
/// The `anonymous_bytes` values are single readings at the boundaries of the
/// load and of the prompt. `sampled_peak_bytes` is the highest anonymous
/// reading among those and the periodic reads taken every `interval_ms` during
/// the load and during the prompt. It is a sampled peak, not a high-water
/// mark: a spike shorter than the interval can be missed, and Android keeps no
/// anonymous-only peak to read instead. `samples` counts the periodic reads
/// that returned a value and `failed` those that failed, per window, so 0
/// samples means only the boundary readings. `read_ms` is `{mean, max}` of the
/// successful reads. The reads run on the main isolate while the stopwatch
/// runs, so they add a cost to `first_token_ms` and `duration_ms` (see
/// `_peakIntervalMs` for what was measured); `interval_ms` is null when the
/// sampler was off.
///
/// The windows do not cover everything. For vision and audio, `createChat`
/// runs between `after_load` and `before_prompt`, and that is where the
/// encoder's kernels compile: a transient there lands in neither window.
///
/// `anonymous_bytes` is memory the OS cannot reclaim by dropping file pages.
/// It excludes weights read from an mmapped file. On Android it largely
/// excludes GPU-only memory (KGSL, Mali and dmabuf sit mostly outside smaps),
/// so with `PreferredBackend.gpu` the load delta understates what the model
/// costs; on Adreno, KGSL buffers mapped into the CPU (`/dev/kgsl-3d0`) can
/// land in `Private_Dirty`, so it is not zero either. Compare numbers only
/// between records with the same `platform` and `backend`.
///
/// `before_load`, `after_load` and the load's sampled peak belong to the phase
/// and repeat in every record of it: summing load deltas across records counts
/// one load once per record. `before_prompt` - `after_load` is everything since the load:
/// creating the chat, plus any earlier prompts in the same phase.
///
/// A null with no entry in `read_errors` means the platform has no such value.
/// A null with an entry means the read failed.
class BenchmarkMemory {
  const BenchmarkMemory({
    this.beforeLoad,
    this.afterLoad,
    this.beforePrompt,
    this.afterPrompt,
    this.availableAfterPrompt,
    this.activeBackend,
    this.loadPeak,
    this.promptPeak,
    this.readErrors = const [],
  });

  final int? beforeLoad;
  final int? afterLoad;
  final int? beforePrompt;
  final int? afterPrompt;

  /// Device-wide `MemAvailable` on Android: an optimistic upper bound, since
  /// lmkd kills well before it reaches zero.
  final int? availableAfterPrompt;

  /// The backend the model actually ran on, when the runtime says.
  final PreferredBackend? activeBackend;

  /// Sampled peaks over the load and over this prompt; see the class docs.
  final PeakReading? loadPeak;
  final PeakReading? promptPeak;

  /// Failed reads, as `"<sample>: <error>"`. The load's own errors repeat in
  /// every record of the phase, like `before_load` and `after_load`.
  final List<String> readErrors;

  Map<String, dynamic> toJson() => {
    'anonymous_bytes': {
      'before_load': beforeLoad,
      'after_load': afterLoad,
      'before_prompt': beforePrompt,
      'after_prompt': afterPrompt,
    },
    'available_bytes_after_prompt': availableAfterPrompt,
    'sampled_peak_bytes': {
      'load': loadPeak?.bytes,
      'prompt': promptPeak?.bytes,
      'interval_ms': promptPeak?.intervalMs ?? loadPeak?.intervalMs,
      'samples': {'load': loadPeak?.samples, 'prompt': promptPeak?.samples},
      'failed': {'load': loadPeak?.failures, 'prompt': promptPeak?.failures},
      'read_ms': {
        'load': _readMsJson(loadPeak),
        'prompt': _readMsJson(promptPeak),
      },
    },
    'read_errors': readErrors,
  };

  /// One line for the live log:
  /// `load +812.3 MiB, prompt +4.1 MiB (anonymous), sampled peak 1043.7 MiB`.
  String describe() =>
      'load ${_signedMiB(beforeLoad, afterLoad)}, '
      'prompt ${_signedMiB(beforePrompt, afterPrompt)} (anonymous), '
      'sampled peak ${_mib(promptPeak?.bytes)}'
      '${readErrors.isEmpty ? '' : ', ${readErrors.length} read error(s)'}';
}

Map<String, dynamic>? _readMsJson(PeakReading? peak) {
  final readMs = peak?.readMs;
  return readMs == null ? null : {'mean': readMs.mean, 'max': readMs.max};
}

String _mib(int? bytes) =>
    bytes == null ? 'n/a' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

String _signedMiB(int? before, int? after) {
  if (before == null || after == null) return 'n/a';
  final mib = (after - before) / (1024 * 1024);
  return '${mib >= 0 ? '+' : ''}${mib.toStringAsFixed(1)} MiB';
}

// --- Test data ---

const _textQuestions = <(String name, String question)>[
  ('simple_fact', 'What is the capital of France?'),
  ('explanation', 'Explain quantum entanglement in simple terms'),
  ('creative', 'Write a short poem about the sea'),
  ('technical', 'What are the main differences between TCP and UDP?'),
  (
    'multilingual',
    "Translate 'Hello, how are you?' to Spanish, French, and German",
  ),
];

const _chatSteps = <String>[
  "My name is Alex and I'm a software developer",
  "I'm working on a Flutter project for a hospital",
  "What's my name and what am I working on?",
  'Can you suggest a good architecture pattern for my project?',
  'Summarize our entire conversation in 2 sentences',
];

// --- Helpers ---

final _allResults = <BenchmarkResult>[];

/// Reads this process's memory from the OS. Null where the package does not
/// run, or where a read fails. A failure is logged and added to [errors] under
/// [label], so the saved JSON keeps it instead of letting a null look like "no
/// such value on this platform". It is not thrown: it must not abort a
/// 60-minute run. The package itself still throws; that a benchmark outlives a
/// failed read is this consumer's call.
Future<MemorySnapshot?> _sampleMemory(String label, List<String> errors) async {
  if (!FlutterEdgeAiDiagnostics.isSupported) return null;
  try {
    return await FlutterEdgeAiDiagnostics.memorySnapshot();
  } on MemoryReadException catch (e) {
    errors.add('$label: $e');
    print('[Benchmark] memory read failed ($label): $e');
    return null;
  }
}

/// One anonymous-bytes reading for the peak sampler. Null where the package
/// does not run; a failed read throws `MemoryReadException`, which the sampler
/// counts.
Future<int?> _readAnonymous() async => FlutterEdgeAiDiagnostics.isSupported
    ? (await FlutterEdgeAiDiagnostics.memorySnapshot()).anonymousBytes
    : null;

PeakSampler _newPeakSampler() => PeakSampler(
  read: _readAnonymous,
  interval: Duration(milliseconds: _peakIntervalMs),
);

/// A failed periodic read goes into `read_errors` once per window, summarised,
/// so a persistent failure cannot flood the record.
List<String> _peakErrors(String label, PeakReading peak) => peak.failures == 0
    ? const []
    : [
        '$label: ${peak.failures} periodic read(s) failed '
            '(first: ${peak.firstFailure})',
      ];

/// Loads a model and reports the anonymous memory before and after: what
/// holding it costs before any prompt runs. Also returns the backend the
/// runtime says it used, and the errors of the two reads.
Future<(InferenceModel, LoadMemory)> _measuredLoad(
  Future<InferenceModel> Function() load,
) async {
  final errors = <String>[];
  final before = (await _sampleMemory('before_load', errors))?.anonymousBytes;
  final sampler = _newPeakSampler()
    ..observe(before)
    ..start();
  final InferenceModel model;
  try {
    model = await load();
  } catch (_) {
    await sampler.cancel();
    rethrow;
  }
  final int? after;
  final PeakReading peak;
  try {
    after = (await _sampleMemory('after_load', errors))?.anonymousBytes;
    peak = await sampler.stop(last: after);
  } catch (_) {
    // The caller never receives the model, so close it here.
    await sampler.cancel();
    try {
      await model.close();
    } catch (_) {}
    rethrow;
  }
  errors.addAll(_peakErrors('sampled_peak_bytes.load', peak));
  return (
    model,
    (
      before: before,
      after: after,
      peak: peak,
      activeBackend: model.activeBackend,
      errors: errors,
    ),
  );
}

/// Runs [run] between a `before_prompt` and an `after_prompt` reading with a
/// peak sampler over it, and returns its result with the memory record. The
/// sampler is stopped on every path, and a failure while stopping never
/// replaces an error from [run].
Future<(T, BenchmarkMemory)> _measuredPrompt<T>(
  LoadMemory load,
  Future<T> Function() run,
) async {
  final readErrors = <String>[];
  final before = await _sampleMemory('before_prompt', readErrors);
  final sampler = _newPeakSampler()
    ..observe(before?.anonymousBytes)
    ..start();
  final T value;
  final MemorySnapshot? after;
  final PeakReading peak;
  try {
    value = await run();
    after = await _sampleMemory('after_prompt', readErrors);
    peak = await sampler.stop(last: after?.anonymousBytes);
  } catch (_) {
    await sampler.cancel();
    rethrow;
  }
  return (value, _promptMemory(load, before, after, peak, readErrors));
}

/// One streamed answer and its timing.
typedef _Answer = ({String text, int firstTokenMs, int durationMs});

Future<_Answer> _streamAnswer(InferenceChat chat, Message message) async {
  final sw = Stopwatch()..start();
  var firstTokenMs = -1;
  await chat.addQueryChunk(message);
  final buffer = StringBuffer();
  await for (final response in chat.generateChatResponseAsync()) {
    if (response is TextResponse) {
      if (firstTokenMs < 0) firstTokenMs = sw.elapsedMilliseconds;
      buffer.write(response.token);
    }
  }
  sw.stop();
  return (
    text: buffer.toString(),
    firstTokenMs: firstTokenMs,
    durationMs: sw.elapsedMilliseconds,
  );
}

BenchmarkMemory _promptMemory(
  LoadMemory load,
  MemorySnapshot? before,
  MemorySnapshot? after,
  PeakReading promptPeak,
  List<String> promptErrors,
) => BenchmarkMemory(
  beforeLoad: load.before,
  afterLoad: load.after,
  beforePrompt: before?.anonymousBytes,
  afterPrompt: after?.anonymousBytes,
  availableAfterPrompt: after?.availableBytes,
  activeBackend: load.activeBackend,
  loadPeak: load.peak,
  promptPeak: promptPeak,
  readErrors: [
    ...load.errors,
    ...promptErrors,
    ..._peakErrors('sampled_peak_bytes.prompt', promptPeak),
  ],
);

Future<Uint8List> _loadTestImage() async {
  final data = await rootBundle.load('assets/test/test_image.jpg');
  return data.buffer.asUint8List();
}

Future<Uint8List> _loadTestAudio() async {
  final data = await rootBundle.load('assets/test/test_audio.wav');
  return data.buffer.asUint8List();
}

Future<void> _installBenchmarkModel(_BenchmarkModelConfig config) async {
  print('[Benchmark] Installing ${config.name} from ${config.filePath}');
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
  ).fromFile(config.filePath).install();
  print('[Benchmark] ${config.name} installed');
}

/// Run a single text query via streaming and measure timing.
Future<BenchmarkResult> _runTextBenchmark({
  required String modelName,
  required InferenceChat chat,
  required String category,
  required String testName,
  required String question,
  required LoadMemory load,
}) => _runQuery(
  modelName: modelName,
  chat: chat,
  category: category,
  testName: testName,
  question: question,
  message: Message.text(text: question, isUser: true),
  load: load,
);

/// Run a vision query via streaming and measure timing.
Future<BenchmarkResult> _runVisionBenchmark({
  required String modelName,
  required InferenceModel model,
  required String testName,
  required String question,
  required Uint8List imageBytes,
  required LoadMemory load,
}) async {
  final chat = await model.createChat(
    modelType: ModelType.gemmaIt,
    supportImage: true,
  );
  try {
    return await _runQuery(
      modelName: modelName,
      chat: chat,
      category: 'vision',
      testName: testName,
      question: question,
      message: Message.withImage(
        text: question,
        imageBytes: imageBytes,
        isUser: true,
      ),
      load: load,
    );
  } finally {
    await chat.close();
  }
}

/// Run an audio query via streaming and measure timing.
Future<BenchmarkResult> _runAudioBenchmark({
  required String modelName,
  required InferenceModel model,
  required String testName,
  required String question,
  required Uint8List audioBytes,
  required LoadMemory load,
}) async {
  final chat = await model.createChat(
    modelType: ModelType.gemmaIt,
    supportAudio: true,
  );
  try {
    return await _runQuery(
      modelName: modelName,
      chat: chat,
      category: 'audio',
      testName: testName,
      question: question,
      message: Message.withAudio(
        text: question,
        audioBytes: audioBytes,
        isUser: true,
      ),
      load: load,
    );
  } finally {
    await chat.close();
  }
}

Future<BenchmarkResult> _runQuery({
  required String modelName,
  required InferenceChat chat,
  required String category,
  required String testName,
  required String question,
  required Message message,
  required LoadMemory load,
}) async {
  final (answer, memory) = await _measuredPrompt(
    load,
    () => _streamAnswer(chat, message),
  );
  final result = BenchmarkResult(
    modelName: modelName,
    testCategory: category,
    testName: testName,
    question: question,
    response: answer.text,
    durationMs: answer.durationMs,
    firstTokenMs: answer.firstTokenMs,
    timestamp: DateTime.now(),
    memory: memory,
  );

  print('[Benchmark] $modelName / $category / $testName');
  print(
    '  First token: ${result.firstTokenMs}ms, Total: ${result.durationMs}ms',
  );
  print('  Memory: ${result.memory.describe()}');
  print(
    '  Response: "${result.response.length > 100 ? result.response.substring(0, 100) : result.response}..."',
  );
  return result;
}

Future<void> _saveResults() async {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final path = '/sdcard/Download/benchmark_results_$timestamp.json';
  final json = const JsonEncoder.withIndent(
    '  ',
  ).convert(_allResults.map((r) => r.toJson()).toList());
  final file = File(path);
  await file.writeAsString(json);
  print('[Benchmark] Results saved to $path');
  print('[Benchmark] Total results: ${_allResults.length}');
}

// --- Main test ---

void main() {
  initIntegrationTest();

  testWidgets('Benchmark: Gemma 3 Nano E2B vs Gemma 4 E2B', (tester) async {
    if (!Platform.isAndroid) {
      markTestSkipped(
        'Benchmark only runs on Android (requires /data/local/tmp models)',
      );
      return;
    }

    await registerTestEngines();

    // Pre-load test assets
    final imageBytes = await _loadTestImage();
    final audioBytes = await _loadTestAudio();
    print('[Benchmark] Test image: ${imageBytes.length} bytes');
    print('[Benchmark] Test audio: ${audioBytes.length} bytes');

    for (final modelConfig in _models) {
      print('\n${'=' * 60}');
      print('BENCHMARKING: ${modelConfig.name}');
      print('${'=' * 60}\n');

      // --- Install model ---
      await _installBenchmarkModel(modelConfig);

      // --- Text benchmarks (single-turn, new chat per question) ---
      {
        final (model, load) = await _measuredLoad(
          () => FlutterEdgeAi.getActiveModel(
            maxTokens: 4096,
            preferredBackend: _requestedBackend,
          ),
        );
        try {
          for (final (name, question) in _textQuestions) {
            final chat = await model.createChat(modelType: ModelType.gemmaIt);
            final result = await _runTextBenchmark(
              modelName: modelConfig.name,
              load: load,
              chat: chat,
              category: 'text',
              testName: name,
              question: question,
            );
            _allResults.add(result);
          }
        } finally {
          await model.close();
        }
      }

      // --- Multi-turn chat benchmark (single chat, 5 steps) ---
      {
        final (model, load) = await _measuredLoad(
          () => FlutterEdgeAi.getActiveModel(
            maxTokens: 4096,
            preferredBackend: _requestedBackend,
          ),
        );
        try {
          final chat = await model.createChat(modelType: ModelType.gemmaIt);

          for (var i = 0; i < _chatSteps.length; i++) {
            final result = await _runTextBenchmark(
              modelName: modelConfig.name,
              load: load,
              chat: chat,
              category: 'multi_turn',
              testName: 'step_${i + 1}',
              question: _chatSteps[i],
            );
            _allResults.add(result);
          }
        } finally {
          await model.close();
        }
      }

      // --- Vision benchmarks ---
      {
        final (model, load) = await _measuredLoad(
          () => FlutterEdgeAi.getActiveModel(
            maxTokens: 4096,
            preferredBackend: _requestedBackend,
            supportImage: true,
            maxNumImages: 1,
          ),
        );
        try {
          final r1 = await _runVisionBenchmark(
            modelName: modelConfig.name,
            load: load,
            model: model,
            testName: 'describe_object',
            question: 'What do you see in this image? Describe it briefly.',
            imageBytes: imageBytes,
          );
          _allResults.add(r1);

          final r2 = await _runVisionBenchmark(
            modelName: modelConfig.name,
            load: load,
            model: model,
            testName: 'describe_detail',
            question: 'Describe everything you see in this image in detail.',
            imageBytes: imageBytes,
          );
          _allResults.add(r2);
        } finally {
          await model.close();
        }
      }

      // --- Audio benchmarks ---
      {
        final (model, load) = await _measuredLoad(
          () => FlutterEdgeAi.getActiveModel(
            maxTokens: 4096,
            preferredBackend: _requestedBackend,
            supportAudio: true,
          ),
        );
        try {
          final r1 = await _runAudioBenchmark(
            modelName: modelConfig.name,
            load: load,
            model: model,
            testName: 'transcribe_short',
            question: 'What was said in this audio?',
            audioBytes: audioBytes,
          );
          _allResults.add(r1);

          final r2 = await _runAudioBenchmark(
            modelName: modelConfig.name,
            load: load,
            model: model,
            testName: 'transcribe_summarize',
            question: 'Transcribe this audio and summarize what was said.',
            audioBytes: audioBytes,
          );
          _allResults.add(r2);
        } finally {
          await model.close();
        }
      }

      print(
        '\n[Benchmark] ${modelConfig.name} complete. '
        'Results so far: ${_allResults.length}',
      );
    }

    // --- Save all results ---
    await _saveResults();
  }, timeout: const Timeout(Duration(minutes: 60)));
}
