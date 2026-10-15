// How the Tiny Island Decider should be calibrated, measured on a device:
// core's Decider over the 184 island actions (920 texts), EmbeddingGemma 2,
// scored on held-out requests it never saw — the 144 labelled paraphrases of
// lib/tiny_island/island_held_out_requests.dart — and on out-of-scope
// requests (tiny_island_requests.dart), which should abstain.
//
// Configurations, each printed as `[calib]` lines:
// - centroid + DeciderCalibration.crossFit() (core's default): every
//   held-out row is test data;
// - centroid + DeciderCalibration.fromLabelled(): two folds — calibrated on
//   one paraphrase of each verb, tested on the other, then swapped — and the
//   full set (what the app ships), whose own rows are training data;
// - with --dart-define=TINY_ISLAND_MEASURE_LINEAR=true, the same for
//   DeciderMethod.linear, with its fit time.
//
// Metrics: argmax accuracy (ignoring abstention), answered share of the
// in-scope rows, error on the answered ones, out-of-scope requests refused.
// It asserts only that the deciders answer; the numbers are the result.
//
// The option texts are embedded once and reused by every configuration
// through a caching wrapper (same vectors; `embedderId` names the space).
//
//   flutter test integration_test/tiny_island_calibration_test.dart -d macos \
//     --dart-define=TINY_ISLAND_EMBEDDER_FILE=...
//
// No setUp/setUpAll (Rule 6b).

// The Decider API is @experimental; measuring it is the point of this file.
// ignore_for_file: experimental_member_use

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_catalog.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_decider_recipe.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_held_out_requests.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'tiny_island_requests.dart';
import 'tiny_island_support.dart';

const _measureLinear = bool.fromEnvironment('TINY_ISLAND_MEASURE_LINEAR');

void _log(String line) {
  // ignore: avoid_print
  print('[calib] $line');
}

/// The model's vectors, each text embedded once.
final class _CachingEmbedder extends EmbeddingModel {
  _CachingEmbedder(this._inner);

  final EmbeddingModel _inner;
  final _vectors = <String, Future<List<double>>>{};
  int embedded = 0;

  @override
  int get dimension => _inner.dimension;

  @override
  PreferredBackend? get activeBackend => _inner.activeBackend;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) => _vectors.putIfAbsent('${taskType.name}\u0000${input.text}', () {
    embedded++;
    return _inner.embed(input, taskType: taskType);
  });

  @override
  void addCloseListener(void Function() listener) =>
      _inner.addCloseListener(listener);

  @override
  Future<void> close() => _inner.close();
}

typedef _Metrics = ({
  int inScope,
  double top1,
  double answered,
  double errorOnAnswered,
  double refused,
  double? threshold,
  List<String> mistakes,
});

Future<_Metrics> _evaluate(
  Decider decider,
  List<IslandHeldOutRequest> inScope,
  List<String> outOfScope,
) async {
  var top1 = 0;
  var answered = 0;
  var wrongAnswered = 0;
  double? threshold;
  final mistakes = <String>[];
  for (final row in inScope) {
    final answer = await decider.choose(
      DeciderInput(EmbeddingInput.text(row.text)),
    );
    threshold ??= answer.provenance.threshold;
    final best = answer.ranked.firstOrNull?.id;
    if (best == row.actionId) top1++;
    if (answer.choice != null) {
      answered++;
      if (answer.choice != row.actionId) {
        wrongAnswered++;
        mistakes.add(
          '"${row.text}" -> ${answer.choice} (want ${row.actionId})',
        );
      }
    } else if (best != row.actionId) {
      mistakes.add(
        '"${row.text}" abstained, best $best (want ${row.actionId})',
      );
    }
  }
  var refused = 0;
  for (final text in outOfScope) {
    final answer = await decider.choose(
      DeciderInput(EmbeddingInput.text(text)),
    );
    if (answer.choice == null) {
      refused++;
    } else {
      mistakes.add(
        'out of scope "$text" -> ${answer.choice} '
        '(cos ${answer.provenance.similarity?.toStringAsFixed(3)})',
      );
    }
  }
  return (
    inScope: inScope.length,
    top1: inScope.isEmpty ? 0.0 : top1 / inScope.length,
    answered: inScope.isEmpty ? 0.0 : answered / inScope.length,
    errorOnAnswered: answered == 0 ? 0.0 : wrongAnswered / answered,
    refused: refused / outOfScope.length,
    threshold: threshold,
    mistakes: mistakes,
  );
}

String _pct(double x) => '${(x * 100).toStringAsFixed(1)}%';

void _report(
  String name,
  _Metrics m, {
  Duration? fit,
  bool showMistakes = true,
}) {
  _log(
    '$name: in-scope ${m.inScope}, top-1 ${_pct(m.top1)}, answered '
    '${_pct(m.answered)}, error on answered ${_pct(m.errorOnAnswered)}, '
    'out-of-scope refused ${_pct(m.refused)}, threshold '
    '${m.threshold?.toStringAsFixed(4)}'
    '${fit == null ? '' : ', create ${fit.inMilliseconds} ms'}',
  );
  if (showMistakes) {
    for (final mistake in m.mistakes) {
      _log('  $name | $mistake');
    }
  }
}

DeciderCalibration _labelled(
  List<IslandHeldOutRequest> rows,
  double maxError,
) => DeciderCalibration.fromLabelled([
  for (final row in rows)
    (input: EmbeddingInput.text(row.text), optionId: row.actionId),
], maxError: maxError);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Tiny Island: calibration measured on held-out requests', () async {
    final model = await ensureTinyIslandEmbedder();
    final real = await FlutterEdgeAi.getActiveEmbedder(
      preferredBackend: model.embedderBackend,
    );
    _log(
      'model ${model.name} on ${real.activeBackend?.name}, dimension '
      '${real.dimension}',
    );
    final embedder = _CachingEmbedder(real);
    final options = islandDeciderOptions(buildIslandCatalog());
    final texts = options.fold(
      0,
      (n, o) => n + o.examples.length + (o.description == null ? 0 : 1),
    );
    _log('${options.length} options, $texts texts');
    const id = 'tiny-island-calibration-measure';
    const held = islandHeldOutRequests;
    final fold1 = [for (var i = 0; i < held.length; i += 2) held[i]];
    final fold2 = [for (var i = 1; i < held.length; i += 2) held[i]];

    Future<(Decider, Duration)> create(
      DeciderMethod method,
      DeciderCalibration calibration,
    ) async {
      final watch = Stopwatch()..start();
      final decider = await embedder.createDecider(
        options: options,
        method: method,
        calibration: calibration,
        embedderId: id,
      );
      return (decider, watch.elapsed);
    }

    for (final method in [
      DeciderMethod.centroid,
      if (_measureLinear) DeciderMethod.linear,
    ]) {
      final m = method.name;
      // The first create embeds every option text (the only uncached one).
      final (crossFit, crossFitTime) = await create(
        method,
        const DeciderCalibration.crossFit(),
      );
      _log('$m: ${embedder.embedded} texts embedded so far');
      final firstChoose = Stopwatch()..start();
      await crossFit.choose(
        DeciderInput(EmbeddingInput.text('stroll to the bench')),
      );
      _log(
        '$m: one choose (uncached query) ${firstChoose.elapsedMilliseconds} ms',
      );
      _report(
        '$m crossFit(0.95), all held-out as test',
        await _evaluate(crossFit, held, tinyIslandOutOfScopeRequests),
        fit: crossFitTime,
      );

      for (final maxError in const [0.05, 0.10]) {
        final name = '$m fromLabelled(maxError $maxError)';
        for (final (label, train, test) in [
          ('fold A', fold1, fold2),
          ('fold B', fold2, fold1),
        ]) {
          try {
            final (decider, time) = await create(
              method,
              _labelled(train, maxError),
            );
            _report(
              '$name $label: calibrated on ${train.length}, tested on '
              '${test.length}',
              await _evaluate(decider, test, tinyIslandOutOfScopeRequests),
              fit: time,
            );
          } on ArgumentError catch (e) {
            _log('$name $label: refused by core: ${e.message}');
          }
        }
        try {
          final (full, time) = await create(method, _labelled(held, maxError));
          _report(
            '$name full set (its own rows are training data)',
            await _evaluate(full, held, tinyIslandOutOfScopeRequests),
            fit: time,
            showMistakes: false,
          );
        } on ArgumentError catch (e) {
          _log('$name full set: refused by core: ${e.message}');
        }
      }
    }
    expect(embedder.embedded, greaterThanOrEqualTo(texts));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
