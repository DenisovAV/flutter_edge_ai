/// `activationDataType` regression: Gemma 4 copying figures out of a long
/// prompt on the GPU.
///
/// At the default activation type (FLOAT16 on GPU, and what the published
/// Gemma 4 `.litertlm` files ask for) GPUs scramble digits once the prompt is
/// long, the same way on every run: asked when a delivery arrived
/// (`2026/06/23`), E2B answers `2026/12/7` on an M3 Max and `20206/12/7` on an
/// iPhone 11; E4B answers `20226/12/17` on an M3 Max and a Snapdragon 8 Elite.
/// `ActivationDataType.float32` fixes it (LiteRT-LM#2814 on Metal, #3012 on
/// Adreno).
///
/// The prompt is a made-up delivery log, identical on every run: 64 lines,
/// about 3,100 tokens, each line with two dates and two amounts. Three
/// questions make the model copy some of them back. On an Apple M3 Max, E2B
/// and E4B at the default precision copied every figure right with logs of up
/// to 32 lines (~1,600 tokens) and wrong from 48 lines (~2,300). A Snapdragon 8
/// Elite got this 64-line log wrong with E4B, and other prompts wrong from
/// ~2,100 tokens.
///
/// An answer fails on either count:
/// - SCRAMBLED — it holds a figure that is nowhere in the log. That is the bug.
/// - NO FIGURE — it holds none of the figures the question asked for. A
///   refusal, an "it is not in the log" or a paraphrase copies nothing, and
///   counting only scrambled figures would pass it as clean.
///
/// A real figure from the wrong line is the model misreading (E2B does it now
/// and then at any precision), so it is printed, not counted.
///
/// On native targets both tests check that the GPU started, since the engine
/// falls back to CPU quietly and the CPU does not show the bug.
/// - float32 must scramble nothing and must answer with figures: that test
///   asserts both.
/// - The default's answers are printed, and only checked for being there,
///   since a GPU without the bug copies right either way. Its lines start with
///   `[default]`.
///
/// Every answer is printed with its time to first token, which is prefill and
/// therefore the part float32 slows down; the float32 test prints its mean
/// against the default run's. A ratio near 1.00× means the setting never
/// reached the engine — the run proves nothing then, however clean it looks.
/// It is printed rather than asserted because the size of the difference
/// depends on the GPU: about 3× on a Snapdragon 8 Elite and an iPhone 11, but
/// only 1.2× on an Apple M4 Pro that shows the bug. To make it an assertion,
/// pass `--dart-define=MIN_PREFILL_RATIO=1.1` — enough to show the setting
/// reached the engine on any of them. A requested floor that cannot be checked
/// (web, the iOS Simulator, or the float32 test run without the default one)
/// fails rather than passes.
///
/// A green run proves the fix only when the default run scrambled a figure;
/// otherwise the float32 test prints INCONCLUSIVE.
///
/// On web only the default test runs. The web engine does not read
/// `activationDataType` (`@litert-lm/core` 0.17 has no such setting), runs the
/// `-web.litertlm` files on its own GPU executor, and reports neither a backend
/// nor session metrics, so no time to first token is printed there.
///
/// Gemma 4 E2B by default; pass `--dart-define=GEMMA4=E4B` for E4B (native
/// only: the E4B web file is over 2 GB). **Android wants E4B**: the Snapdragon
/// 8 Elite run that showed the bug was E4B, and E2B has not been seen to
/// scramble anything on that phone, so the default E2B run there says little
/// either way.
///
/// Prerequisites (otherwise the model is downloaded: E2B 2.59 GB, E4B 3.66 GB,
/// E2B web 2.01 GB):
///   macOS:   gemma-4-E2B-it.litertlm in ~/Library/Containers/.../Documents/
///   Android: adb push gemma-4-E4B-it.litertlm /data/local/tmp/flutter_gemma_test/
///   iOS, web: downloaded via FlutterEdgeAi.installModel()
///
/// Run, native:
///   flutter test integration_test/activation_data_type_test.dart -d <device>
///   Android: add --dart-define=GEMMA4=E4B
///   The iOS Simulator skips both tests: it has no GPU backend.
///
/// Run, web — from `example/`, with `chromedriver --port=4444` up:
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/activation_data_type_test.dart \
///     -d web-server
///   `-d chrome` hangs there on Flutter 3.47.2, and `flutter run` reports no
///   pass or fail at all. Note that `integrationDriver` gives up after 20
///   minutes while these tests allow 30, so a first run that downloads the
///   2 GB web model can hit that limit — run it once to fill the cache, then
///   again for a result. On Chrome 153 with WebGPU on an M3 Max, nothing was
///   scrambled.
library;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
// `dart:io` is not imported here: this file is compiled for web too, where it
// does not exist. The io arm reads the pushed model; the web arm returns null.
import 'local_model_file_io.dart'
    if (dart.library.js_interop) 'local_model_file_web.dart';
import 'platform_helper.dart' show isIosSimulator;

/// E2B or E4B.
const _variant = String.fromEnvironment('GEMMA4', defaultValue: 'E2B');
const _file = 'gemma-4-$_variant-it.litertlm';

/// Floor for the float32/default time-to-first-token ratio, from
/// `--dart-define=MIN_PREFILL_RATIO=1.1`. Empty (the default) only prints it.
const _minPrefillRatio = String.fromEnvironment('MIN_PREFILL_RATIO');

/// The web engine takes only the `-web.litertlm` build of each model.
String get _url =>
    'https://huggingface.co/litert-community/gemma-4-$_variant-it-litert-lm/'
    'resolve/main/${kIsWeb ? 'gemma-4-$_variant-it-web.litertlm' : _file}';

Future<void>? _installed;

/// Installs the model once per run. Called from each test body rather than a
/// setUp, so a failure to install fails the test that needed it.
Future<void> _install() => _installed ??= () async {
  await registerTestEngines();
  final local = localModelFile(_file);
  final builder = FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  );
  // Say which file ran: a model pushed for another variant (Android wants
  // E4B) is not found under this name, and the run downloads this one instead.
  debugPrint('[setup] Gemma 4 $_variant from ${local ?? _url}');
  if (local != null) {
    await builder.fromFile(local).install();
  } else {
    await builder.fromNetwork(_url).install();
  }
}();

/// One line of the made-up log.
typedef _Delivery = ({
  String id,
  String shipped,
  String arrived,
  int kilograms,
  int total,
});

/// [count] deliveries from a fixed seed, so every run and every device reads
/// the same log.
List<_Delivery> _deliveries(int count) {
  var seed = 7;
  int next(int bound) {
    // seed * 1103515245 + 12345, mod 2^31, with the multiplier (0x41C64E6D)
    // split so no product passes 2^53: on web a plain product loses bits and
    // the log would differ from native.
    seed =
        (seed * 0x4E6D + ((seed * 0x41C6) & 0x7FFF) * 0x10000 + 12345) &
        0x7fffffff;
    return seed % bound;
  }

  String two(int n) => n.toString().padLeft(2, '0');
  return [
    for (var i = 0; i < count; i++)
      () {
        final year = 2026 + next(2);
        final month = 1 + next(12);
        final day = 1 + next(19);
        return (
          id: 'D-${4100 + i * 7}',
          shipped: '$year/${two(month)}/${two(day)}',
          arrived: '$year/${two(month)}/${two(day + 2 + next(8))}',
          kilograms: 100 + next(9900),
          total: 1000 + next(99000),
        );
      }(),
  ];
}

String _logText(List<_Delivery> log) => [
  'Delivery log. One line per delivery: id, date shipped, date arrived, '
      'weight, invoice total.',
  for (final d in log)
    '${d.id} | shipped ${d.shipped} | arrived ${d.arrived} | '
        '${d.kilograms} kg | ${d.total} EUR',
].join('\n');

/// Three questions about [log], each with the figures a right answer holds.
List<({String text, List<String> figures})> _questions(List<_Delivery> log) {
  final a = log[log.length * 3 ~/ 4];
  final b = log[log.length ~/ 2];
  final lines = log.sublist(log.length - 6, log.length - 2);
  return [
    (
      text:
          'When did delivery ${a.id} arrive? Answer with the date only, '
          'exactly as it is written in the log.',
      figures: [a.arrived],
    ),
    (
      text:
          'What are the weight and the invoice total of delivery ${b.id}? '
          'Answer with the two numbers only.',
      figures: ['${b.kilograms}', '${b.total}'],
    ),
    (
      text:
          'Copy the lines for deliveries ${lines.first.id} to '
          '${lines.last.id} exactly as they are written in the log.',
      figures: [
        for (final d in lines) ...[
          d.shipped,
          d.arrived,
          '${d.kilograms}',
          '${d.total}',
        ],
      ],
    ),
  ];
}

/// Every figure in [text]: each run of digits joined by `/`, kept when it is a
/// date or has three digits or more. Whole runs, so `2026/06/233` is not read
/// as a right `2026/06/23`.
Iterable<String> _figures(String text) =>
    RegExp(r'\d+(?:/\d+)*')
        .allMatches(text)
        .map((m) => m[0]!)
        .where((f) => f.contains('/') || f.length >= 3);

/// What one run of the three questions produced: a line for each answer that
/// failed, the ones among them that invented a figure (the bug itself, as
/// opposed to a refusal), and the time to first token of every answer that
/// reported one.
typedef _Run = ({
  List<String> bad,
  List<String> scrambled,
  List<double> ttftMs,
});

/// Asks every question in a fresh greedy session, and returns the answers that
/// failed — one holding a figure that is nowhere in the log, or one holding no
/// figure the question asked for — alongside each answer's prefill time.
Future<_Run> _askAll(ActivationDataType? type) async {
  final label = type?.name ?? 'default';
  final log = _deliveries(64);
  final text = _logText(log);
  final inLog = _figures(text).toSet();
  final model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    activationDataType: type,
  );
  final wrong = <String>[];
  final scrambled = <String>[];
  final ttftMs = <double>[];
  try {
    // The web engine reports no backend; it runs only on WebGPU.
    if (!kIsWeb) {
      expect(
        model.activeBackend,
        PreferredBackend.gpu,
        reason: 'the GPU did not start, so this device cannot show the bug',
      );
    }
    for (final q in _questions(log)) {
      final session = await model.createSession(topK: 1, maxOutputTokens: 512);
      try {
        final prompt = '$text\n\n${q.text}';
        final tokens = await session.sizeInTokens(prompt);
        await session.addQueryChunk(Message(text: prompt, isUser: true));
        final answer = (await session.getResponse()).trim();
        // Prefill time, and the only thing in the run that shows float32 was
        // applied at all: fp32 prefill is the slow one. The web engine reports
        // no metrics, and a native build without benchmarking enabled would
        // report null here rather than fail.
        final ttft = kIsWeb
            ? null
            : session.getSessionMetrics().timeToFirstTokenMs;
        if (ttft != null) ttftMs.add(ttft);
        expect(answer, isNotEmpty, reason: 'no answer to: ${q.text}');
        final got = _figures(answer).toSet();
        final copied = [
          for (final f in q.figures)
            if (got.contains(f)) f,
        ];
        final missing = [
          for (final f in q.figures)
            if (!got.contains(f)) f,
        ];
        final invented = [
          for (final f in got)
            if (!inLog.contains(f)) f,
        ];
        final verdict = invented.isNotEmpty
            ? 'SCRAMBLED'
            : copied.isEmpty
            ? 'NO FIGURE (nothing from the log was copied back)'
            : missing.isNotEmpty
            ? 'misread (a real figure from another line)'
            : 'right';
        debugPrint(
          // On web sizeInTokens is an estimate from the length.
          '[$label] ${kIsWeb ? '~' : ''}$tokens tokens'
          '${ttft == null ? '' : ', ${ttft.round()} ms to first token'}'
          ': ${q.text}\n'
          '[$label]   $verdict: $answer'
          '${missing.isEmpty ? '' : '\n[$label]   missing: $missing'}'
          '${invented.isEmpty ? '' : '\n[$label]   not in the log: $invented'}',
        );
        if (invented.isNotEmpty) {
          wrong.add('${q.text} -> not in the log $invented');
          scrambled.add(q.text);
        } else if (copied.isEmpty) {
          wrong.add('${q.text} -> no figure from the log: "$answer"');
        }
      } finally {
        await session.close();
      }
    }
  } finally {
    await model.close();
  }
  return (bad: wrong, scrambled: scrambled, ttftMs: ttftMs);
}

double _mean(List<double> values) =>
    values.reduce((a, b) => a + b) / values.length;

/// The default run's prefill times, for the float32 test to compare against.
/// Null when that test was skipped or never reported any.
List<double>? _defaultTtftMs;

/// Whether the default run scrambled a figure — the bug, not a refusal. Null
/// when that test did not run in this invocation.
bool? _defaultShowedBug;

/// The requested prefill floor, checked before any model runs: a floor that
/// cannot be checked must fail rather than pass without being looked at.
double? _checkedFloor() {
  if (_minPrefillRatio.isEmpty) return null;
  final floor = double.tryParse(_minPrefillRatio);
  expect(
    floor,
    isNotNull,
    reason: 'MIN_PREFILL_RATIO="$_minPrefillRatio" is not a number',
  );
  expect(
    floor,
    greaterThan(1.0),
    reason: 'a floor at or below 1.0 checks nothing',
  );
  expect(
    kIsWeb,
    isFalse,
    reason:
        'MIN_PREFILL_RATIO cannot be checked on web: the web engine does '
        'not read activationDataType, so the float32 test does not run there',
  );
  expect(
    isIosSimulator,
    isFalse,
    reason:
        'MIN_PREFILL_RATIO cannot be checked on the iOS Simulator: it has '
        'no GPU backend',
  );
  return floor;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (isIosSimulator) {
    debugPrint(
      '[setup] iOS Simulator: GPU runs are skipped — the simulator has no GPU '
      'backend, so it cannot show the bug or the fix',
    );
  }

  testWidgets(
    'default activations on GPU: answers printed, not asserted',
    (tester) async {
      _checkedFloor();
      await _install();
      final run = await _askAll(null);
      if (run.ttftMs.isNotEmpty) _defaultTtftMs = run.ttftMs;
      _defaultShowedBug = run.scrambled.isNotEmpty;
      debugPrint(
        run.bad.isEmpty
            ? '[default] every answer copied figures, none of them invented: '
                  'this GPU does not show the bug'
            : '[default] ${run.bad.length} of 3 answers bad: this GPU shows '
                  'the bug${kIsWeb ? '' : ' that float32 fixes'}\n'
                  '[default]   ${run.bad.join('\n[default]   ')}',
      );
    },
    // The simulator has no GPU backend, so the GPU assertion would always fail.
    // A requested floor still runs it, to fail on that floor with a reason.
    skip: isIosSimulator && _minPrefillRatio.isEmpty,
    timeout: const Timeout(Duration(minutes: 30)),
  );

  testWidgets(
    'float32 activations copy figures back, and scramble none',
    (tester) async {
      final floor = _checkedFloor();
      if (floor != null) {
        expect(
          _defaultTtftMs,
          isNotNull,
          reason:
              'MIN_PREFILL_RATIO compares against the default test, which '
              'has to run first in the same invocation and report its times '
              'to first token',
        );
      }
      await _install();
      final run = await _askAll(ActivationDataType.float32);

      // Prefill is where float32 costs time, so this is the run's own evidence
      // that the setting reached the engine. Without it, a GPU that never had
      // the bug — or a build where the setter call was dropped — passes just as
      // green as a real fix.
      final before = _defaultTtftMs;
      if (floor != null) {
        expect(
          run.ttftMs,
          isNotEmpty,
          reason: 'the float32 run reported no time to first token',
        );
      }
      if (before != null && run.ttftMs.isNotEmpty) {
        final ratio = _mean(run.ttftMs) / _mean(before);
        debugPrint(
          '[float32] time to first token ${_mean(run.ttftMs).round()} ms '
          'against ${_mean(before).round()} ms at the default precision, '
          '${ratio.toStringAsFixed(2)}x. Near 1.00x means float32 never took '
          'effect, whatever the answers look like.',
        );
        if (floor != null) expect(ratio, greaterThanOrEqualTo(floor));
      }

      expect(run.bad, isEmpty);
      if (_defaultShowedBug != true) {
        debugPrint(
          '[float32] INCONCLUSIVE: '
          '${_defaultShowedBug == null ? 'the default test did not run in this invocation' : 'the default precision scrambled nothing on this GPU either'}'
          ', so this pass does not show that float32 fixed anything'
          '${floor == null ? ' — nor, without MIN_PREFILL_RATIO, that it reached the engine' : ''}.',
        );
      }
    },
    // The web engine does not read activationDataType, so this would run the
    // default again; the simulator has no GPU backend.
    skip: kIsWeb || isIosSimulator,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
