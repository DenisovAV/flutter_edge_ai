// The decider fit on the web page, model-free: seeded unit rows
// (test/decision/fit_fingerprint.dart), d 768, 10 rows per option.
//
// Checks: the web fit runner — compiled into its real call site,
// EmbeddingModel.createDecider, and called directly — fits exactly what the
// VM fits (the fingerprints are the VM's, held by
// test/decision/fit_fingerprint_test.dart); and while it fits, the page's
// event loop keeps turning. Prints, per case, the fit time and the largest
// gap between ticks of a 16 ms periodic timer; one case also runs the fit
// without yielding, as the page ran it before (the gap is the whole fit).
//
// The times are this test compiler's, NOT a release build's: `flutter test
// --platform chrome` compiles with DDC (debug JavaScript) and `--wasm` with
// dart2wasm -O0, asserts on, no inlining — numeric code runs tens of times
// slower than in `flutter build web`. Under DDC the 150-option linear case
// alone takes over ten minutes. The release numbers on the Decisions page
// come from release builds.
//
// tool/test_all.sh (and so CI) runs it with `--exclude-tags slow`, which
// leaves out the linear fits at 50 and 150 options (~3 and ~15 minutes
// under DDC). Model-free, so a local headless Chrome is fine. Run all of it:
//   flutter test --platform chrome test/web/decider_web_test.dart
//   flutter test --platform chrome --wasm test/web/decider_web_test.dart
@TestOn('browser')
@Timeout(Duration(minutes: 40))
library;

import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/decision/decider_fit.dart';
import 'package:flutter_edge_ai/src/decision/fit_runner_web.dart' as web;
import 'package:flutter_test/flutter_test.dart';

import '../decision/fake_embedder.dart';
import '../decision/fit_fingerprint.dart';

/// The VM's fingerprints (fit_fingerprint_test.dart).
const _vm = <(int, bool), FitFingerprint>{
  (10, false): vmFingerprint10,
  (10, true): vmFingerprint10Linear,
  (50, false): vmFingerprint50,
  (50, true): vmFingerprint50Linear,
  (150, false): vmFingerprint150,
  (150, true): vmFingerprint150Linear,
};

/// Runs [body] under a 16 ms periodic timer: its wall time and the largest
/// gap between two ticks (or from the start to the first, or from the last
/// to the end). An event loop that keeps turning shows ~16 ms.
Future<(Duration, Duration)> _measure(Future<void> Function() body) async {
  var maxGap = Duration.zero;
  final since = Stopwatch()..start();
  final timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
    if (since.elapsed > maxGap) maxGap = since.elapsed;
    since.reset();
  });
  final total = Stopwatch()..start();
  await body();
  total.stop();
  timer.cancel();
  if (since.elapsed > maxGap) maxGap = since.elapsed;
  return (total.elapsed, maxGap);
}

String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);

void main() {
  test('createDecider on the page uses the web runner and fits what the VM '
      'fits', () async {
    final request = fingerprintRequest(10, linear: false);
    const d = fingerprintDimension;
    final table = <String, List<double>>{
      for (var i = 0; i < request.labels.length; i++)
        'row$i': request.inputs.sublist(i * d, (i + 1) * d),
    };
    final decider = await FakeEmbedder(dimension: d, table: table)
        .createDecider(
          options: [
            for (var o = 0; o < 10; o++)
              DeciderOption(
                'o$o',
                examples: [
                  for (var i = 0; i < request.labels.length; i++)
                    if (request.labels[i] == o) EmbeddingInput.text('row$i'),
                ],
              ),
          ],
          embedderId: 'fixture',
        );
    final calibration = decider.toArtifact()['calibration']! as Map;
    // The decider renormalises rows already unit length: the same
    // threshold as the VM's to within the renormalisation's rounding.
    expect(
      calibration['threshold']! as double,
      closeTo(_vm[(10, false)]!.threshold, 1e-12),
    );
  });

  for (final c in [10, 50, 150]) {
    for (final linear in [false, true]) {
      final name =
          '$c options × 10, ${linear ? 'linear' : 'centroid'} + '
          'cross-fit';
      final tag = linear && c >= 50 ? 'slow' : null;
      test(name, () async {
        final request = fingerprintRequest(c, linear: linear);
        late DeciderFit fit;
        final (time, gap) = await _measure(() async {
          fit = await web.runDeciderFit(request);
        });
        // ignore: avoid_print
        print(
          'WEBFIT c=$c ${linear ? 'linear' : 'centroid'} '
          'fit=${_ms(time)} ms maxGap=${_ms(gap)} ms',
        );
        if (c == 50 && !linear) {
          final (blockingTime, blockingGap) = await _measure(() async {
            await Future<void>.delayed(Duration.zero);
            await fitDecider(request);
          });
          // ignore: avoid_print
          print(
            'WEBFIT c=$c centroid, without yielding: '
            'fit=${_ms(blockingTime)} ms maxGap=${_ms(blockingGap)} ms',
          );
        }
        final expected = _vm[(c, linear)]!;
        final actual = fingerprintOf(fit);
        // ignore: avoid_print
        print('WEBFP c=$c linear=$linear $actual');
        expectFingerprint(actual, expected);
        // The loop kept turning: a fit that does not yield shows a gap as
        // long as the whole fit. The bound is relative because this test's
        // compilers are debug ones: under DDC the 150-option linear fit takes
        // ~15 minutes and its longest gap was 120–280 ms over three runs
        // (more pause points did not shorten it — most likely garbage
        // collection of DDC's boxed doubles). Release builds measured
        // 20–24 ms (Decisions page); dart2wasm -O0 here, ~22 ms.
        final bound = time ~/ 20 > const Duration(milliseconds: 500)
            ? time ~/ 20
            : const Duration(milliseconds: 500);
        expect(gap, lessThan(bound));
      }, tags: tag);
    }
  }
}
