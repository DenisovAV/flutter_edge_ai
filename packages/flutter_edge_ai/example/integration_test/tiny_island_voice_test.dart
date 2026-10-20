// Can SPOKEN commands drive Tiny Island? The spoken clip goes straight into
// EmbeddingGemma 2 740m (text + vision + audio; its text tower is the 270m's,
// byte for byte, so its text vectors are the app's) as
// `EmbeddingInput.audio`, and core's Decider picks the island action.
// Measured on a device with no 3D scene and no frame waits — pure decider
// work, like tiny_island_calibration_test.dart. The numbers are the result;
// it asserts only that the clips match the lists they were made from and
// that the deciders answer.
//
// The clips are SYNTHETIC speech (macOS `say` voices), not human recordings:
// every held-out request (English ones by three English voices, German ones
// by a German voice), every out-of-scope request, the screen test's 17
// requests (one voice), and every option example phrasing (a fourth English
// voice that speaks no request). Generate them with
// integration_test/tools/generate_island_voice_clips.dart and copy them into
// the app's container (that file says how). Without them the test is
// skipped, so this file stays out of a default device run.
//
// Measured, for audio-only inputs and again with the decider's prefix
// as a text part in front of the clip (`EmbeddingInput(text: '', audio: ...)`:
// an audio-only input carries no task prefix, while every option text does):
// - the app's recipe (text examples, calibrated on the 144 held-out requests
//   as TEXT), asked with the clip: does the text threshold carry over? With
//   the same requests typed, as the reference; the highest cosine of each.
// - the same options calibrated on AUDIO: `fromLabelled` over the held-out
//   clips, two folds by request (every voice of a request on the same side),
//   tested on the other fold, the out-of-scope clips and the screen clips;
// - options that also hold SPOKEN examples (the action's example phrasings
//   as clips): one or all four per action next to the text, or the four
//   clips alone — text-calibrated and audio-calibrated as above.
// - the time per clip: the audio embedding, and the scoring after it.
//
// Prints `[voice]` lines: every metric and every miss.
//
//   flutter test integration_test/tiny_island_voice_test.dart -d macos
//     --dart-define=TINY_ISLAND_VOICE_DIR=<clip dir; default
//         <documents>/island_voice>
//     --dart-define=TINY_ISLAND_AUDIO_EMBEDDER_FILE=<a local copy of the 740m>
//     --dart-define=TINY_ISLAND_AUDIO_EMBEDDER_MODEL=<catalog name; default
//         embeddingGemma2TextVisionAudio740m, the CPU bundle>
//     --dart-define=TINY_ISLAND_VOICE_THRESHOLD_ONLY=true  (stop after the
//         threshold sweep a new bundle needs before speaking is on there)
//   (all optional; the bundle downloads from Hugging Face otherwise, and on
//   macOS a local copy must sit inside the app's container)
//
// No setUp/setUpAll (Rule 6b).

// The Decider API is @experimental; measuring it is the point of this file.
// ignore_for_file: experimental_member_use

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/tiny_island/island_catalog.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_decider_recipe.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_held_out_requests.dart';
import 'package:flutter_edge_ai_example/utils/audio_converter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'tiny_island_requests.dart';
import 'tiny_island_support.dart';

const _voiceDir = String.fromEnvironment('TINY_ISLAND_VOICE_DIR');
const _audioEmbedderFile = String.fromEnvironment(
  'TINY_ISLAND_AUDIO_EMBEDDER_FILE',
);

/// The catalog entry to run: the 740M CPU bundle, or a per-SoC one such as
/// embeddingGemma2TextVisionAudio740mSm8850 (text on the NPU, audio on the
/// CPU).
const _audioEmbedderModel = String.fromEnvironment(
  'TINY_ISLAND_AUDIO_EMBEDDER_MODEL',
  defaultValue: 'embeddingGemma2TextVisionAudio740m',
);

const _manifestHeader = 'file\tset\tvoice\tlanguage\taction\ttext';

const _maxErrors = [0.05, 0.10, 0.20];

/// Stops after the voice threshold sweep (the app's options against plain
/// audio): what a new bundle or backend needs before speaking is turned on
/// there, without the spoken-example configurations.
const _thresholdOnly = bool.fromEnvironment('TINY_ISLAND_VOICE_THRESHOLD_ONLY');

void _log(String line) {
  // ignore: avoid_print
  print('[voice] $line');
}

/// One clip of the manifest: [want] is the action id it means (or belongs to,
/// for an option example), null when it must abstain; [heldIndex] its row in
/// [islandHeldOutRequests].
typedef _Clip = ({
  String file,
  String set,
  String voice,
  String want,
  String? wantOrNull,
  String text,
  int? heldIndex,
  Uint8List wav,
});

/// The manifest's clips, checked against the lists they were generated from;
/// null when there is no manifest.
Future<List<_Clip>?> _loadClips() async {
  final dir = _voiceDir.isNotEmpty
      ? Directory(_voiceDir)
      : Directory(
          '${(await getApplicationDocumentsDirectory()).path}'
          '${Platform.pathSeparator}island_voice',
        );
  final manifest = File('${dir.path}${Platform.pathSeparator}manifest.tsv');
  if (!manifest.existsSync()) {
    _log(
      'no clips: ${manifest.path} does not exist. Generate them with '
      'integration_test/tools/generate_island_voice_clips.dart and copy them '
      'into the app container (or pass TINY_ISLAND_VOICE_DIR).',
    );
    return null;
  }
  final lines = manifest.readAsLinesSync();
  expect(lines.first, _manifestHeader, reason: 'manifest header');
  final heldIndex = {
    for (final (i, row) in islandHeldOutRequests.indexed)
      '${row.text}\t${row.actionId}': i,
  };
  final screen = {for (final c in tinyIslandScreenCases) c.request: c.expect};
  final examples = {
    for (final action in buildIslandCatalog())
      for (final example in action.examples) '$example\t${action.id}',
  };
  final clips = <_Clip>[];
  for (final line in lines.skip(1)) {
    if (line.isEmpty) continue;
    final fields = line.split('\t');
    expect(fields, hasLength(6), reason: 'manifest line "$line"');
    final [file, set, voice, _, action, text] = fields;
    final want = action.isEmpty ? null : action;
    int? index;
    switch (set) {
      case 'held_out':
        index = heldIndex['$text\t$action'];
        expect(index, isNotNull, reason: 'stale clip $file; regenerate');
      case 'out_of_scope':
        expect(tinyIslandOutOfScopeRequests, contains(text), reason: file);
        expect(want, isNull, reason: file);
      case 'screen':
        expect(screen.containsKey(text), isTrue, reason: 'stale clip $file');
        expect(want, screen[text], reason: file);
      case 'example':
        expect(
          examples,
          contains('$text\t$action'),
          reason: 'stale clip $file; regenerate',
        );
      default:
        fail('$file: unknown set "$set"');
    }
    clips.add((
      file: file,
      set: set,
      voice: voice,
      want: action,
      wantOrNull: want,
      text: text,
      heldIndex: index,
      wav: File('${dir.path}${Platform.pathSeparator}$file').readAsBytesSync(),
    ));
  }
  // Every request and every example has its clip.
  expect(
    {for (final c in clips) ?c.heldIndex},
    hasLength(islandHeldOutRequests.length),
    reason: 'a held-out request has no clip; regenerate the clips',
  );
  expect({
    for (final c in clips.where((c) => c.set == 'out_of_scope')) c.text,
  }, hasLength(tinyIslandOutOfScopeRequests.length));
  expect({
    for (final c in clips.where((c) => c.set == 'screen')) c.text,
  }, hasLength(tinyIslandScreenCases.length));
  expect(
    {
      for (final c in clips.where((c) => c.set == 'example'))
        '${c.text}\t${c.want}',
    },
    examples,
    reason: 'an option example has no clip; regenerate the clips',
  );
  for (final set in ['held_out', 'out_of_scope', 'screen', 'example']) {
    final inSet = clips.where((c) => c.set == set).toList();
    final seconds = [for (final c in inSet) _seconds(c.wav)]..sort();
    _log(
      '$set: ${inSet.length} clips, voices '
      '${{for (final c in inSet) c.voice}.join(', ')}, length '
      '${seconds.first.toStringAsFixed(2)}-${seconds.last.toStringAsFixed(2)}'
      ' s, median ${seconds[seconds.length ~/ 2].toStringAsFixed(2)} s',
    );
  }
  _log('clips from ${dir.path}: synthetic speech (macOS say), not human');
  return clips;
}

/// The clip's length in seconds.
double _seconds(Uint8List wav) {
  final parsed = AudioConverter.parseWav(wav);
  return parsed.pcmData.length / (parsed.sampleRate * parsed.channels * 2);
}

/// The model's vectors, each input embedded once (texts by their text, media
/// by a hash of their bytes).
final class _CachingEmbedder extends EmbeddingModel {
  _CachingEmbedder(this._inner);

  final EmbeddingModel _inner;
  final _vectors = <String, Future<List<double>>>{};

  /// Inputs the model embedded (cache misses).
  int misses = 0;

  static String _key(EmbeddingInput input, TaskType taskType) => [
    taskType.name,
    if (input.text case final text?) 't:$text',
    for (final image in input.images) 'i:${sha1.convert(image)}',
    if (input.audio case final audio?) 'a:${sha1.convert(audio)}',
  ].join('\u0000');

  @override
  int get dimension => _inner.dimension;

  @override
  Set<EmbeddingModality> get modalities => _inner.modalities;

  @override
  int? get maxInputTokens => _inner.maxInputTokens;

  @override
  PreferredBackend? get activeBackend => _inner.activeBackend;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) => _vectors.putIfAbsent(_key(input, taskType), () {
    misses++;
    return _inner.embed(input, taskType: taskType);
  });

  @override
  void addCloseListener(void Function() listener) =>
      _inner.addCloseListener(listener);

  @override
  Future<void> close() => _inner.close();
}

/// One decision.
typedef _Row = ({
  _Clip clip,
  String? choice,
  String? best,
  double? similarity,
  double? threshold,
  Duration scoreTime,
});

Future<List<_Row>> _decide(
  Decider decider,
  List<_Clip> clips,
  EmbeddingInput Function(_Clip) inputOf,
) async {
  final rows = <_Row>[];
  for (final clip in clips) {
    final answer = await decider.choose(DeciderInput(inputOf(clip)));
    rows.add((
      clip: clip,
      choice: answer.choice,
      best: answer.ranked.firstOrNull?.id,
      similarity: answer.provenance.abstainSignal,
      threshold: answer.provenance.threshold,
      scoreTime: answer.provenance.scoreTime,
    ));
  }
  return rows;
}

String _pct(int n, int of) =>
    of == 0 ? '-' : '${(n * 100 / of).toStringAsFixed(1)}% ($n/$of)';

String _cos(double? x) => x?.toStringAsFixed(3) ?? '-';

/// Median, 10th percentile, min and max of [values].
String _spread(Iterable<double?> values) {
  final s = values.whereType<double>().toList()..sort();
  if (s.isEmpty) return '-';
  return 'median ${_cos(s[s.length ~/ 2])}, p10 ${_cos(s[s.length ~/ 10])}, '
      'min ${_cos(s.first)}, max ${_cos(s.last)} (n ${s.length})';
}

String _ms(Iterable<Duration> times) {
  final s = [for (final t in times) t.inMicroseconds]..sort();
  if (s.isEmpty) return '-';
  String f(int us) => (us / 1000).toStringAsFixed(1);
  return 'median ${f(s[s.length ~/ 2])} ms, p90 '
      '${f(s[(s.length * 9) ~/ 10])} ms, max ${f(s.last)} ms (n ${s.length})';
}

/// Prints [name]'s metrics over [rows]: the held-out clips (top-1, answered,
/// error on answered), the out-of-scope clips (refused) and the screen clips
/// (decided as the screen test expects); then each miss.
void _report(String name, List<_Row> rows, {bool misses = true}) {
  final held = rows.where((r) => r.clip.set == 'held_out').toList();
  final outOfScope = rows.where((r) => r.clip.set == 'out_of_scope').toList();
  final screen = rows.where((r) => r.clip.set == 'screen').toList();
  final threshold = rows.map((r) => r.threshold).nonNulls.firstOrNull;
  if (held.isNotEmpty) {
    final answered = held.where((r) => r.choice != null).toList();
    final wrong = answered.where((r) => r.choice != r.clip.want).length;
    final top1 = held.where((r) => r.best == r.clip.want).length;
    _log(
      '$name | held-out ${held.length}: top-1 ${_pct(top1, held.length)}, '
      'answered ${_pct(answered.length, held.length)}, error on answered '
      '${_pct(wrong, answered.length)}, threshold ${_cos(threshold)}',
    );
  }
  if (outOfScope.isNotEmpty) {
    final refused = outOfScope.where((r) => r.choice == null).length;
    _log('$name | out-of-scope refused ${_pct(refused, outOfScope.length)}');
  }
  if (screen.isNotEmpty) {
    final inScope = screen.where((r) => r.clip.wantOrNull != null).toList();
    final expected = screen.where((r) => r.choice == r.clip.wantOrNull);
    final top1 = inScope.where((r) => r.best == r.clip.want).length;
    final answered = inScope.where((r) => r.choice != null).length;
    _log(
      '$name | screen cases as expected '
      '${_pct(expected.length, screen.length)}; in-scope ${inScope.length}: '
      'top-1 ${_pct(top1, inScope.length)}, answered '
      '${_pct(answered, inScope.length)}',
    );
  }
  if (!misses) return;
  for (final r in rows) {
    final c = r.clip;
    final String what;
    if (c.wantOrNull == null) {
      if (r.choice == null) continue;
      what = 'answered ${r.choice}, want abstain';
    } else if (r.choice == c.want) {
      continue;
    } else if (r.choice != null) {
      what = 'answered ${r.choice}, want ${c.want}';
    } else if (r.best != c.want) {
      what = 'abstained, best ${r.best}, want ${c.want}';
    } else {
      continue; // abstained with the right best: a refusal, not a miss
    }
    _log(
      '$name | miss | ${c.file} "${c.text}" -> $what '
      '(cos ${_cos(r.similarity)})',
    );
  }
}

/// Top-1 and answered share of the held-out clips, per voice.
void _reportVoices(String name, List<_Row> rows) {
  for (final voice in {for (final r in rows) r.clip.voice}) {
    final held = rows
        .where((r) => r.clip.set == 'held_out' && r.clip.voice == voice)
        .toList();
    if (held.isEmpty) continue;
    final answered = held.where((r) => r.choice != null).toList();
    final wrong = answered.where((r) => r.choice != r.clip.want).length;
    _log(
      '$name | voice $voice: held-out ${held.length}, top-1 '
      '${_pct(held.where((r) => r.best == r.clip.want).length, held.length)}'
      ', answered ${_pct(answered.length, held.length)}, error on answered '
      '${_pct(wrong, answered.length)}',
    );
  }
}

/// The highest cosine of the held-out and out-of-scope clips.
/// The fixed threshold spoken requests need: answered share, error on the
/// answered and out-of-scope clips refused for a sweep of thresholds, and
/// the lowest one whose answered held-out clips keep their error within each
/// of [_maxErrors] (fromLabelled's rule), over the best cosine of each clip.
void _reportVoiceThreshold(String name, List<_Row> rows) {
  final held = [
    for (final r in rows)
      if (r.clip.set == 'held_out') r,
  ];
  final out = [
    for (final r in rows)
      if (r.clip.set == 'out_of_scope') r,
  ];
  bool right(_Row r) => r.best == r.clip.want;
  String at(double t) {
    final answered = [
      for (final r in held)
        if (r.similarity! >= t) r,
    ];
    final wrong = answered.where((r) => !right(r)).length;
    final refused = out.where((r) => r.similarity! < t).length;
    return 'answered ${_pct(answered.length, held.length)}, error '
        '${_pct(wrong, answered.length)}, out-of-scope refused '
        '${_pct(refused, out.length)}';
  }

  final top = held.where(right).length;
  _log(
    '$name | threshold sweep over ${held.length} held-out and '
    '${out.length} out-of-scope clips, top-1 ${_pct(top, held.length)}',
  );
  for (var t = 0.60; t < 0.905; t += 0.01) {
    _log('$name | t ${t.toStringAsFixed(2)}: ${at(t)}');
  }
  final sorted = [for (final r in held) r.similarity!]..sort();
  for (final budget in _maxErrors) {
    final pick = sorted.firstWhere((t) {
      final answered = [
        for (final r in held)
          if (r.similarity! >= t) r,
      ];
      return answered.where((r) => !right(r)).length <=
          budget * answered.length;
    }, orElse: () => double.infinity);
    _log(
      '$name | budget $budget: threshold ${pick.toStringAsFixed(4)}, '
      '${pick.isFinite ? at(pick) : 'nothing answered'}',
    );
  }
}

void _reportSpread(String name, List<_Row> rows) {
  for (final set in ['held_out', 'out_of_scope']) {
    _log(
      '$name | top cosine, $set: '
      '${_spread(rows.map((r) => r.clip.set == set ? r.similarity : null))}',
    );
  }
}

/// The held-out clips whose request is in fold [parity] (0: even rows of
/// [islandHeldOutRequests], 1: odd rows — as the calibration test folds).
List<_Clip> _fold(List<_Clip> clips, int parity) => [
  for (final c in clips)
    if (c.heldIndex case final i? when i % 2 == parity) c,
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Tiny Island by voice: the clip straight into EmbeddingGemma 2 740m',
    () async {
      final all = await _loadClips();
      if (all == null) {
        return markTestSkipped('no voice clips; see the file header');
      }
      final queries = all.where((c) => c.set != 'example').toList();
      final spokenExamples = <String, List<_Clip>>{};
      for (final c in all.where((c) => c.set == 'example')) {
        (spokenExamples[c.want] ??= []).add(c);
      }
      for (final action in buildIslandCatalog()) {
        // In the order of the action's text examples.
        spokenExamples[action.id]!.sort(
          (a, b) => action.examples
              .indexOf(a.text)
              .compareTo(action.examples.indexOf(b.text)),
        );
      }

      final model = catalog.EmbeddingModel.values.firstWhere(
        (m) => m.name == _audioEmbedderModel && m.embedsAudio,
        orElse: () => fail(
          'TINY_ISLAND_AUDIO_EMBEDDER_MODEL=$_audioEmbedderModel is not an '
          'EmbeddingGemma 2 bundle with an audio encoder',
        ),
      );
      await installTinyIslandEmbedder(model, localFile: _audioEmbedderFile);
      final real = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: model.embedderBackend,
        supportAudio: true,
      );
      _log(
        'model ${model.name} on ${real.activeBackend?.name}, dimension '
        '${real.dimension}, modalities '
        '${[for (final m in real.modalities) m.name].join('+')}',
      );
      final embedder = _CachingEmbedder(real);

      // The two forms a clip is asked in.
      EmbeddingInput audio(Uint8List wav) => EmbeddingInput.audio(wav);
      EmbeddingInput prefixed(Uint8List wav) =>
          EmbeddingInput(text: '', audio: wav);

      // Every clip once per form, timed: what a spoken request costs the
      // embedder (the decider then reuses these vectors).
      Future<List<Duration>> embedEvery(
        List<_Clip> clips,
        EmbeddingInput Function(Uint8List) form,
      ) async {
        final times = <Duration>[];
        for (final clip in clips) {
          final watch = Stopwatch()..start();
          await embedder.embed(
            form(clip.wav),
            // The decider's prompt, so the cache hands it these vectors.
            taskType: TaskType.sentenceSimilarity,
          );
          times.add(watch.elapsed);
        }
        return times;
      }

      final examples = all.where((c) => c.set == 'example').toList();
      final audioTimes = await embedEvery(queries, audio);
      _log(
        'audio embedding per query clip: first '
        '${audioTimes.first.inMilliseconds} ms, then '
        '${_ms(audioTimes.skip(1))}',
      );
      var forms = [('audio', audio)];
      if (!_thresholdOnly) {
        try {
          final times = await embedEvery(queries, prefixed);
          _log('prefix+audio embedding per query clip: ${_ms(times)}');
          forms = [...forms, ('prefix+audio', prefixed)];
        } on Object catch (e) {
          _log('prefix+audio refused by the embedder: $e');
        }
        for (final (name, form) in forms) {
          _log(
            '$name embedding per option-example clip: '
            '${_ms(await embedEvery(examples, form))}',
          );
        }
      }

      final recipe = islandDeciderRecipe(buildIslandCatalog());
      Future<Decider> create(
        List<DeciderOption> options,
        EmbeddingDeciderCalibration calibration,
      ) => embedder.createDecider(
        options: options,
        method: recipe.method,
        calibration: calibration,
        embedderId: 'tiny-island-voice-${model.name}',
      );

      // The app's recipe as it ships, asked typed and spoken.
      final watch = Stopwatch()..start();
      final app = await create(recipe.options, recipe.calibration);
      _log(
        'the app recipe (${recipe.calibrationLabel}) fitted in '
        '${watch.elapsedMilliseconds} ms',
      );
      final typed = await _decide(
        app,
        queries,
        (c) => EmbeddingInput.text(c.text),
      );
      _report(
        'typed text, app recipe (held-out rows are its calibration rows)',
        typed,
        misses: false,
      );
      _reportSpread('typed text, app recipe', typed);
      final spoken = await _decide(app, queries, (c) => audio(c.wav));
      _log(
        'scoring per spoken query after its embedding (184 centroids): '
        '${_ms(spoken.map((r) => r.scoreTime))}',
      );
      await app.close();
      _reportVoiceThreshold('plain audio against the app options', spoken);
      if (_thresholdOnly) {
        expect(spoken, hasLength(queries.length));
        return;
      }

      // Option sets, each in the form the clips are asked in.
      List<DeciderOption> options(
        EmbeddingInput Function(Uint8List) form, {
        required bool text,
        required int spoken,
      }) => [
        for (final o in recipe.options)
          DeciderOption(
            o.id,
            description: text ? o.description : null,
            examples: [
              if (text) ...o.examples,
              for (final c in spokenExamples[o.id]!.take(spoken)) form(c.wav),
            ],
            metadata: o.metadata,
          ),
      ];

      final notHeld = queries.where((c) => c.set != 'held_out').toList();
      final held = queries.where((c) => c.set == 'held_out').toList();
      for (final (formName, form) in forms) {
        for (final (setName, text, count) in [
          ('text options', true, 0),
          ('text + 1 spoken example', true, 1),
          ('text + 4 spoken examples', true, 4),
          ('4 spoken examples only', false, 4),
        ]) {
          final opts = options(form, text: text, spoken: count);
          EmbeddingInput inputOf(_Clip c) => form(c.wav);
          final base = '$formName, $setName';
          if (text) {
            // Calibrated on the 144 held-out requests as TEXT, as the app is.
            final decider = await create(opts, recipe.calibration);
            final rows = await _decide(decider, queries, inputOf);
            _report('$base, text-calibrated', rows);
            _reportVoices('$base, text-calibrated', rows);
            _reportSpread('$base, text-calibrated', rows);
            await decider.close();
          }
          // Calibrated on AUDIO: one fold of the held-out clips, tested on the
          // other fold, the out-of-scope clips and the screen clips.
          for (final maxError in _maxErrors) {
            final name = '$base, audio-calibrated (maxError $maxError)';
            final pooled = <_Row>[];
            for (final (label, train, test) in [
              ('fold A', _fold(held, 0), _fold(held, 1)),
              ('fold B', _fold(held, 1), _fold(held, 0)),
            ]) {
              try {
                final decider = await create(
                  opts,
                  EmbeddingDeciderCalibration.fromLabelled([
                    for (final c in train)
                      (input: inputOf(c), optionId: c.want),
                  ], maxError: maxError),
                );
                final rows = await _decide(decider, [
                  ...test,
                  ...notHeld,
                ], inputOf);
                _report(
                  '$name $label: calibrated on ${train.length} clips',
                  rows,
                  misses: maxError == _maxErrors.first,
                );
                if (!text &&
                    maxError == _maxErrors.first &&
                    label == 'fold A') {
                  _reportSpread('$base, fold A', rows);
                }
                pooled.addAll(rows);
                await decider.close();
              } on ArgumentError catch (e) {
                _log('$name $label: refused by core: ${e.message}');
              }
            }
            if (pooled.isNotEmpty) {
              _report('$name, both folds pooled', pooled, misses: false);
              _reportVoices('$name, both folds pooled', pooled);
            }
          }
        }
      }
      expect(spoken, hasLength(queries.length));
    },
    timeout: const Timeout(Duration(minutes: 120)),
  );
}
