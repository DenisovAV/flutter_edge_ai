// The two fit runners. Native: the fit runs on an isolate a cancel kills, and
// its failure arrives as itself. Web (run here on the VM, where its yield is
// a zero timer): the fit yields to the event loop as it goes, gives the same
// numbers as an unpaced fit, and stops at the next yield on a cancel.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/decision/decider_fit.dart';
import 'package:flutter_edge_ai/src/decision/fit_runner_io.dart' as io;
import 'package:flutter_edge_ai/src/decision/fit_runner_web.dart' as web;
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

/// Unit rows around [c] directions, [k] per option, dimension [d].
DeciderFitRequest _request(
  int c,
  int k,
  int d, {
  bool linear = false,
  String calibration = 'crossFit',
}) {
  final random = math.Random(5);
  final n = c * k;
  final x = Float64List(n * d);
  final labels = Int32List(n);
  final ranks = Int32List(n);
  for (var i = 0; i < n; i++) {
    labels[i] = i ~/ k;
    ranks[i] = i % k;
    var norm = 0.0;
    for (var j = 0; j < d; j++) {
      final v = (j % c == labels[i] ? 1.0 : 0.0) + random.nextDouble() - 0.5;
      x[i * d + j] = v;
      norm += v * v;
    }
    norm = math.sqrt(norm);
    for (var j = 0; j < d; j++) {
      x[i * d + j] /= norm;
    }
  }
  return DeciderFitRequest(
    dimension: d,
    optionCount: c,
    optionIds: [for (var o = 0; o < c; o++) 'o$o'],
    inputs: x,
    labels: labels,
    ranks: ranks,
    linear: linear,
    calibration: calibration,
    keep: 0.95,
  );
}

void _expectSameFit(DeciderFit a, DeciderFit b) {
  expect(a.centroids, b.centroids);
  expect(a.threshold, b.threshold);
  expect(a.weights, b.weights);
  expect(a.bias, b.bias);
  expect(a.linearLoss, b.linearLoss);
  expect(a.linearIterations, b.linearIterations);
}

Future<void> _until(bool Function() done, Duration within) async {
  final deadline = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('not within $within');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('native runner', () {
    test('returns the fit', () async {
      final request = _request(6, 5, 32, linear: true);
      _expectSameFit(
        await io.runDeciderFit(request),
        await fitDecider(request),
      );
    });

    test('a cancel kills the fit isolate at once', () async {
      // ~9 s of L-BFGS at 150 options × 10 inputs, d 768, on a desktop.
      final token = CancelToken();
      final watch = Stopwatch()..start();
      final fit = io.runDeciderFit(
        _request(150, 10, 768, linear: true),
        cancelToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(io.debugLiveDeciderFits(), 1);
      token.cancel();
      await expectLater(
        fit.timeout(const Duration(seconds: 2)),
        throwsA(isA<DeciderCancelledException>()),
      );
      await _until(
        () => io.debugLiveDeciderFits() == 0,
        const Duration(seconds: 2),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a token cancelled before the fit fails it without a fit, on both '
        'runners', () async {
      for (final run in [io.runDeciderFit, web.runDeciderFit]) {
        await expectLater(
          run(_request(4, 3, 8), cancelToken: CancelToken()..cancel()),
          throwsA(isA<DeciderCancelledException>()),
        );
      }
    });

    test('the fit\'s own failure arrives as itself, with its stack', () async {
      // Rows the decider gets wrong at every threshold: ArgumentError.
      final base = _request(3, 3, 6);
      final request = DeciderFitRequest(
        dimension: base.dimension,
        optionCount: base.optionCount,
        optionIds: base.optionIds,
        inputs: base.inputs,
        labels: base.labels,
        ranks: base.ranks,
        linear: false,
        calibration: 'labelled',
        maxError: 0,
        labelledInputs: Float64List.sublistView(base.inputs, 0, 6),
        labelledLabels: Int32List.fromList([2]),
      );
      Object? error;
      StackTrace? stack;
      try {
        await io.runDeciderFit(request);
      } catch (e, st) {
        error = e;
        stack = st;
      }
      expect(error, isA<ArgumentError>());
      expect('$stack', contains('decider_fit.dart'));
    });
  });

  group('web runner (on the VM)', () {
    for (final linear in [false, true]) {
      test('${linear ? 'linear' : 'centroid + cross-fit'}: yields as it '
          'goes and fits exactly what an unpaced fit does', () async {
        final request = _request(10, 10, 96, linear: linear);
        final pacer = web.CooperativeFitPacer(
          null,
          slice: const Duration(microseconds: 200),
        );
        final paced = await fitDecider(request, pacer: pacer);
        expect(pacer.turns, greaterThan(0));
        _expectSameFit(paced, await fitDecider(request));
        _expectSameFit(await web.runDeciderFit(request), paced);
      });
    }

    test('while it fits, timers run', () async {
      var ticks = 0;
      final timer = Timer.periodic(Duration.zero, (_) => ticks++);
      await web.runDeciderFit(_request(40, 10, 256, linear: true));
      timer.cancel();
      expect(ticks, greaterThan(0));
    });

    test('a cancel stops it at the next yield', () async {
      final token = CancelToken();
      final fit = web.runDeciderFit(
        _request(60, 10, 256, linear: true),
        cancelToken: token,
      );
      Timer(const Duration(milliseconds: 50), token.cancel);
      await expectLater(
        fit.timeout(const Duration(seconds: 2)),
        throwsA(isA<DeciderCancelledException>()),
      );
    });
  });

  group('createDecider', () {
    test('a cancel during the fit fails it with DeciderCancelledException, '
        'never a decider', () async {
      final table = <String, List<double>>{};
      final random = math.Random(9);
      final options = <DeciderOption>[];
      for (var o = 0; o < 150; o++) {
        final examples = <EmbeddingInput>[];
        for (var k = 0; k < 10; k++) {
          final key = 'o$o-$k';
          table[key] = [
            for (var j = 0; j < 768; j++)
              (j % 150 == o ? 1.0 : 0.0) + random.nextDouble() - 0.5,
          ];
          examples.add(EmbeddingInput.text(key));
        }
        options.add(DeciderOption('o$o', examples: examples));
      }
      final embedder = FakeEmbedder(dimension: 768, table: table);
      final token = CancelToken();
      final created = embedder.createDecider(
        options: options,
        method: DeciderMethod.linear,
        embedderId: 'fake',
        cancelToken: token,
      );
      await _until(
        () => io.debugLiveDeciderFits() == 1,
        const Duration(seconds: 30),
      );
      token.cancel();
      await expectLater(
        created.timeout(const Duration(seconds: 2)),
        throwsA(isA<DeciderCancelledException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a cancel seen only after the fit still fails the call', () async {
      final embedder = FakeEmbedder(
        dimension: 2,
        table: {
          'a1': [1, 0],
          'a2': [0.9, 0.1],
          'b1': [0, 1],
          'b2': [0.1, 0.9],
        },
      );
      final options = [
        DeciderOption(
          'a',
          examples: [EmbeddingInput.text('a1'), EmbeddingInput.text('a2')],
        ),
        DeciderOption(
          'b',
          examples: [EmbeddingInput.text('b1'), EmbeddingInput.text('b2')],
        ),
      ];
      // A dry run counts how often the token is read: before the option
      // embedding, by its cancel listener (CancelToken.whenCancelled reads
      // isCancelled), before each of the 4 requests, as the fit starts, by
      // the fit's cancel listener, and after the fit — 9; the last is the
      // one after the fit.
      final dry = _CancelAtRead(null);
      await embedder.createDecider(
        options: options,
        embedderId: 'fake',
        cancelToken: dry,
      );
      expect(dry.reads, 9);
      await expectLater(
        embedder.createDecider(
          options: options,
          embedderId: 'fake',
          cancelToken: _CancelAtRead(dry.reads),
        ),
        throwsA(isA<DeciderCancelledException>()),
      );
    });

    test('an embedder closed during the fit, which core cannot replace, '
        'fails the call', () async {
      final embedder = FakeEmbedder(
        dimension: 2,
        table: {
          'a1': [1, 0],
          'a2': [0.9, 0.1],
          'b1': [0, 1],
          'b2': [0.1, 0.9],
        },
      );
      embedder.onEmbed = (input) {
        // Closed right after the last input is embedded (that request still
        // succeeds), so the embedder is closed while the fit runs.
        if (input.text == 'b2') {
          scheduleMicrotask(() => unawaited(embedder.close()));
        }
      };
      final created = embedder.createDecider(
        options: [
          DeciderOption(
            'a',
            examples: [EmbeddingInput.text('a1'), EmbeddingInput.text('a2')],
          ),
          DeciderOption(
            'b',
            examples: [EmbeddingInput.text('b1'), EmbeddingInput.text('b2')],
          ),
        ],
        embedderId: 'fake',
      );
      await expectLater(created, throwsA(isA<EmbedderClosedException>()));
    });
  });
}

/// Reads as cancelled from read [at] on (never when null), counting reads.
final class _CancelAtRead extends CancelToken {
  _CancelAtRead(this.at);

  final int? at;
  int reads = 0;

  @override
  bool get isCancelled {
    reads++;
    return at != null && reads >= at!;
  }
}
