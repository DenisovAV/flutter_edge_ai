// The decider API over a deterministic fake embedder: validation, ranking,
// margin, among/topK, abstaining, context refusal, failures that propagate,
// Decider.chooseAll's shared embedding, the InferenceModel default and the
// Jev JSON helpers.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

/// Three directions, near-duplicates of them, and requests between them.
final _table = <String, List<double>>{
  'a1': [1, 0, 0],
  'a2': [0.9, 0.1, 0],
  'b1': [0, 1, 0],
  'b2': [0.1, 0.9, 0],
  'c1': [0, 0, 1],
  'c2': [0, 0.1, 0.9],
  'about a': [1, 0.05, 0],
  'about b': [0.05, 1, 0],
  'a or b': [1, 0.98, 0],
  'nothing': [-1, -1, -1],
  'half': [1, 1, 0],
  'zero': [0, 0, 0],
  'nan': [double.nan, 0, 0],
  'short': [1, 0],
  'long': [1, 0, 0, 0],
  'option a': [1, 0.2, 0],
  'option b': [0.2, 1, 0],
};

FakeEmbedder _embedder({PreferredBackend? backend}) =>
    FakeEmbedder(dimension: 3, table: _table, activeBackend: backend);

EmbeddingInput _t(String text) => EmbeddingInput.text(text);
DeciderInput _in(String text) => DeciderInput(_t(text));

List<DeciderOption> _abc() => [
  DeciderOption('a', examples: [_t('a1'), _t('a2')]),
  DeciderOption('b', examples: [_t('b1'), _t('b2')]),
  DeciderOption('c', examples: [_t('c1'), _t('c2')]),
];

Future<Decider> _decider(
  EmbeddingModel embedder, {
  List<DeciderOption>? options,
  DeciderMethod method = DeciderMethod.centroid,
  EmbeddingDeciderCalibration calibration =
      const EmbeddingDeciderCalibration.none(),
}) => embedder.createDecider(
  options: options ?? _abc(),
  method: method,
  calibration: calibration,
  embedderId: 'fake',
);

/// A decider implemented outside core, for chooseAll: it extends Decider and
/// leaves toArtifact to the base class.
final class _OtherDecider extends Decider {
  int calls = 0;
  CancelToken? lastCancelToken;
  DeciderRequest? lastRequest;

  /// Runs inside decide, before it answers; a throw from it fails decide.
  void Function()? onDecide;
  bool _closed = false;

  @override
  DeciderCapabilities get capabilities => const DeciderCapabilities(
    modalities: {EmbeddingModality.text},
    calibratedProbabilities: false,
    supportsContext: true,
    supportsAmong: false,
    storable: false,
  );

  @override
  List<DeciderOption> get options => [DeciderOption('x', description: 'x')];

  @override
  bool get isClosed => _closed;

  @override
  Future<DeciderAnswer> decide(DeciderRequest request) async {
    final cancelToken = request.cancelToken;
    calls++;
    lastCancelToken = cancelToken;
    lastRequest = request;
    onDecide?.call();
    return DeciderAnswer(
      choice: 'x',
      ranked: const [RankedOption(id: 'x', score: 0)],
      scoreKind: ScoreKind.logprob,
      margin: double.infinity,
      provenance: const DeciderProvenance(
        method: DeciderMethod.centroid,
        calibration: 'none',
        spaceId: 'other',
        encodeTime: Duration.zero,
        scoreTime: Duration.zero,
      ),
    );
  }

  @override
  Future<void> close() async => _closed = true;
}

/// An InferenceModel that implements nothing but inherits the defaults.
class _Llm extends InferenceModel {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('options and their validation', () {
    test('DeciderOption refuses an empty id or description', () {
      expect(() => DeciderOption(''), throwsArgumentError);
      expect(() => DeciderOption('a', description: ''), throwsArgumentError);
    });

    test('DeciderOption copies its examples and metadata', () {
      final examples = [_t('a1')];
      final metadata = <String, Object?>{'tool': 'x'};
      final option = DeciderOption('a', examples: examples, metadata: metadata);
      examples.add(_t('a2'));
      metadata['tool'] = 'y';
      expect(option.examples, hasLength(1));
      expect(option.metadata, {'tool': 'x'});
      expect(() => option.examples.add(_t('a2')), throwsUnsupportedError);
    });

    final cases =
        <
          String,
          (
            List<DeciderOption>,
            DeciderMethod,
            EmbeddingDeciderCalibration,
            Pattern,
          )
        >{
          'no options': (
            [],
            DeciderMethod.centroid,
            const EmbeddingDeciderCalibration.none(),
            'must not be empty',
          ),
          'duplicate ids': (
            [
              DeciderOption('a', description: 'x'),
              DeciderOption('a', description: 'y'),
            ],
            DeciderMethod.centroid,
            const EmbeddingDeciderCalibration.none(),
            'share the id',
          ),
          'nothing to embed': (
            [DeciderOption('a')],
            DeciderMethod.centroid,
            const EmbeddingDeciderCalibration.none(),
            'nothing to embed',
          ),
          'linear with one option': (
            [
              DeciderOption('a', examples: [_t('a1'), _t('a2')]),
            ],
            DeciderMethod.linear,
            const EmbeddingDeciderCalibration.none(),
            'at least two options',
          ),
          'cross-fit with one input': (
            [
              DeciderOption('a', description: 'option a'),
              DeciderOption('b', examples: [_t('b1'), _t('b2')]),
            ],
            DeciderMethod.centroid,
            const EmbeddingDeciderCalibration.crossFit(),
            'EmbeddingDeciderCalibration.minSimilarity',
          ),
          'keep out of range': (
            _abc(),
            DeciderMethod.centroid,
            const EmbeddingDeciderCalibration.crossFit(keep: 0),
            '(0, 1]',
          ),
          'threshold out of range': (
            _abc(),
            DeciderMethod.centroid,
            const EmbeddingDeciderCalibration.minSimilarity(1.5),
            '[-1, 1]',
          ),
          'maxError out of range': (
            _abc(),
            DeciderMethod.centroid,
            EmbeddingDeciderCalibration.fromLabelled([
              (input: _t('about a'), optionId: 'a'),
            ], maxError: 1),
            '[0, 1)',
          ),
          'no labelled rows': (
            _abc(),
            DeciderMethod.centroid,
            EmbeddingDeciderCalibration.fromLabelled(const []),
            'needs labelled rows',
          ),
          'a labelled row for an unknown option': (
            _abc(),
            DeciderMethod.centroid,
            EmbeddingDeciderCalibration.fromLabelled([
              (input: _t('about a'), optionId: 'z'),
            ]),
            'does not have',
          ),
          'a labelled row repeating an example': (
            _abc(),
            DeciderMethod.centroid,
            EmbeddingDeciderCalibration.fromLabelled([
              (input: _t('a1'), optionId: 'a'),
            ]),
            'repeats an option input',
          ),
        };
    for (final MapEntry(
          key: name,
          value: (options, method, calibration, message),
        )
        in cases.entries) {
      test('refused: $name', () async {
        final embedder = _embedder();
        await expectLater(
          _decider(
            embedder,
            options: options,
            method: method,
            calibration: calibration,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '${e.message} ${e.invalidValue}',
              'message',
              contains(message),
            ),
          ),
        );
        expect(embedder.calls, isEmpty, reason: 'refused before embedding');
      });
    }

    test('labelled rows the decider gets wrong at every threshold are '
        'refused, not turned into an always-abstaining decider', () async {
      await expectLater(
        _decider(
          _embedder(),
          calibration: EmbeddingDeciderCalibration.fromLabelled([
            (input: _t('about a'), optionId: 'b'),
            (input: _t('about b'), optionId: 'a'),
          ]),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('no threshold keeps the error'),
          ),
        ),
      );
    });

    test('a model core did not build needs an embedderId', () async {
      await expectLater(
        _embedder().createDecider(options: _abc()),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'embedderId'),
        ),
      );
    });
  });

  group('embedding', () {
    test('every option input and every request is embedded with '
        'TaskType.sentenceSimilarity, description first', () async {
      final embedder = _embedder();
      final decider = await _decider(
        embedder,
        options: [
          DeciderOption('a', description: 'option a', examples: [_t('a1')]),
          DeciderOption('b', description: 'option b'),
        ],
      );
      await decider.choose(_in('about a'));
      expect(embedder.calls, [
        ('option a', TaskType.sentenceSimilarity),
        ('a1', TaskType.sentenceSimilarity),
        ('option b', TaskType.sentenceSimilarity),
        ('about a', TaskType.sentenceSimilarity),
      ]);
    });

    test('a zero-shot option set from descriptions alone', () async {
      final decider = await _decider(
        _embedder(),
        options: [
          DeciderOption('a', description: 'option a'),
          DeciderOption('b', description: 'option b'),
        ],
        calibration: const EmbeddingDeciderCalibration.minSimilarity(0.5),
      );
      expect((await decider.choose(_in('about b'))).choice, 'b');
      expect((await decider.choose(_in('nothing'))).choice, isNull);
    });

    test('a vector that is not finite, not unit-able or of the wrong '
        'length is refused, never decided on', () async {
      final decider = await _decider(_embedder());
      for (final text in ['nan', 'zero', 'short', 'long']) {
        await expectLater(
          decider.choose(_in(text)),
          throwsStateError,
          reason: text,
        );
      }
      await expectLater(
        _decider(
          _embedder(),
          options: [
            DeciderOption('a', examples: [_t('nan'), _t('a1')]),
          ],
        ),
        throwsStateError,
      );
    });

    test('the embedder\'s failures arrive unchanged', () async {
      final embedder = _embedder();
      final decider = await _decider(embedder);
      embedder.failNext = const EmbeddingInputTooLongException(
        'too long',
        maxInputTokens: 1024,
        actualTokens: 2000,
      );
      await expectLater(
        decider.choose(_in('about a')),
        throwsA(isA<EmbeddingInputTooLongException>()),
      );
      await embedder.close();
      await expectLater(
        decider.choose(_in('about a')),
        throwsA(isA<EmbedderClosedException>()),
      );
    });

    test('cancelling the option embedding fails createDecider', () async {
      final token = CancelToken()..cancel();
      await expectLater(
        _embedder().createDecider(
          options: _abc(),
          embedderId: 'fake',
          cancelToken: token,
        ),
        throwsA(isA<DeciderCancelledException>()),
      );
    });
  });

  group('choose', () {
    test(
      'ranks every candidate by cosine, best first, with the margin',
      () async {
        final decider = await _decider(_embedder());
        final answer = await decider.choose(_in('a or b'));
        expect(answer.choice, 'a');
        expect(answer.scoreKind, ScoreKind.cosine);
        expect(answer.ranked.map((r) => r.id), ['a', 'b', 'c']);
        final scores = answer.ranked.map((r) => r.score).toList();
        expect(scores[0], greaterThan(scores[1]));
        expect(scores[1], greaterThan(scores[2]));
        expect(answer.margin, closeTo(scores[0] - scores[1], 1e-12));
        expect(answer.abstainReason, isNull);
        expect(answer.probabilities, isNull);
        expect(answer.confidence, isNull);
        expect(answer.ranked.every((r) => r.probability == null), isTrue);
        expect(answer.provenance.abstainSignal, closeTo(scores[0], 1e-12));
        expect(answer.provenance.threshold, isNull);
        expect(answer.provenance.calibration, 'none');
        expect(answer.provenance.method, DeciderMethod.centroid);
      },
    );

    test('topK caps ranked; the margin still compares the top two', () async {
      final decider = await _decider(_embedder());
      final answer = await decider.choose(_in('a or b'), topK: 1);
      expect(answer.ranked.map((r) => r.id), ['a']);
      final full = await decider.choose(_in('a or b'));
      expect(answer.margin, full.margin);
      await expectLater(
        decider.choose(_in('a or b'), topK: 0),
        throwsArgumentError,
      );
    });

    test('a tie ranks the option given first first', () async {
      final decider = await _decider(
        _embedder(),
        options: [
          DeciderOption('b', examples: [_t('b1')]),
          DeciderOption('a', examples: [_t('a1')]),
        ],
      );
      final answer = await decider.choose(_in('half'));
      expect(answer.ranked.map((r) => r.id), ['b', 'a']);
      expect(answer.margin, 0);
      // among names candidates; their order is the options', not among's.
      final three = await _decider(
        _embedder(),
        options: [
          DeciderOption('b', examples: [_t('b1')]),
          DeciderOption('c', examples: [_t('c1')]),
          DeciderOption('a', examples: [_t('a1')]),
        ],
      );
      final among = await three.choose(_in('half'), among: const ['a', 'b']);
      expect(among.ranked.map((r) => r.id), ['b', 'a']);
    });

    test('among restricts the candidates', () async {
      final decider = await _decider(_embedder());
      final answer = await decider.choose(
        _in('a or b'),
        among: ['c', 'b', 'b'],
      );
      expect(answer.choice, 'b');
      expect(answer.ranked.map((r) => r.id), ['b', 'c']);
      final single = await decider.choose(_in('a or b'), among: ['c']);
      expect(single.choice, 'c');
      expect(single.margin, double.infinity);
      await expectLater(
        decider.choose(_in('a or b'), among: ['b', 'z']),
        throwsA(
          isA<ArgumentError>().having((e) => e.invalidValue, 'value', 'z'),
        ),
      );
    });

    test('an empty among abstains without embedding', () async {
      final embedder = _embedder();
      final decider = await _decider(embedder);
      final before = embedder.calls.length;
      final answer = await decider.choose(_in('a or b'), among: const []);
      expect(answer.choice, isNull);
      expect(answer.abstainReason, AbstainReason.noCandidates);
      expect(answer.ranked, isEmpty);
      expect(answer.margin, 0);
      expect(answer.provenance.abstainSignal, isNull);
      expect(embedder.calls.length, before);
    });

    test(
      'minSimilarity abstains below the threshold and answers at it',
      () async {
        final embedder = _embedder();
        final probe = await _decider(embedder);
        final atA = (await probe.choose(
          _in('about a'),
        )).provenance.abstainSignal!;
        final decider = await _decider(
          embedder,
          calibration: EmbeddingDeciderCalibration.minSimilarity(atA),
        );
        final answered = await decider.choose(_in('about a'));
        expect(answered.choice, 'a');
        expect(answered.provenance.threshold, atA);
        final refused = await decider.choose(_in('nothing'));
        expect(refused.choice, isNull);
        expect(refused.abstainReason, AbstainReason.belowThreshold);
        expect(refused.ranked, isNotEmpty, reason: 'still ranked');
        expect(refused.provenance.abstainSignal, lessThan(atA));
      },
    );

    test(
      'the cross-fit threshold keeps that share of held-out inputs',
      () async {
        // Two options, two inputs each: every input is scored against a
        // centroid made of its option's other input only.
        final decider = await _decider(
          _embedder(),
          options: [
            DeciderOption('a', examples: [_t('a1'), _t('a2')]),
            DeciderOption('b', examples: [_t('b1'), _t('b2')]),
          ],
          calibration: const EmbeddingDeciderCalibration.crossFit(keep: 1),
        );
        // keep 1: the threshold is the lowest held-out signal. Every input's
        // nearest held-in centroid is its option's other input: a1·unit(a2) =
        // 0.9 / sqrt(0.82), and the same for the other three.
        final threshold = (await decider.choose(
          _in('about a'),
        )).provenance.threshold!;
        expect(threshold, closeTo(0.9 / math.sqrt(0.82), 1e-12));
      },
    );

    test('a decider takes no context and says so', () async {
      final decider = await _decider(_embedder());
      expect(decider.capabilities.supportsContext, isFalse);
      await expectLater(
        decider.choose(
          DeciderInput(
            _t('about a'),
            context: [const Message(text: 'earlier', isUser: true)],
          ),
        ),
        throwsA(isA<DeciderUnsupportedException>()),
      );
    });

    test('capabilities', () async {
      final decider = await _decider(_embedder());
      final capabilities = decider.capabilities;
      expect(capabilities.calibratedProbabilities, isFalse);
      expect(capabilities.supportsContext, isFalse);
      expect(capabilities.supportsAmong, isTrue);
      expect(capabilities.storable, isTrue);
      expect(capabilities.modalities, {EmbeddingModality.text});
      expect(decider.options.map((o) => o.id), ['a', 'b', 'c']);
    });

    test('close stops the decider and leaves the embedder open', () async {
      final embedder = _embedder();
      final decider = await _decider(embedder);
      expect(decider.isClosed, isFalse);
      await decider.close();
      await decider.close();
      expect(decider.isClosed, isTrue);
      expect(embedder.isClosed, isFalse);
      await expectLater(decider.choose(_in('about a')), throwsStateError);
    });

    test(
      'a cancelled token fails choose before anything is embedded',
      () async {
        final embedder = _embedder();
        final decider = await _decider(embedder);
        embedder.calls.clear();
        await expectLater(
          decider.choose(_in('about a'), cancelToken: CancelToken()..cancel()),
          throwsA(isA<DeciderCancelledException>()),
        );
        expect(embedder.calls, isEmpty);
      },
    );

    test('a cancel while the input is embedded drops the result', () async {
      final embedder = _embedder();
      final decider = await _decider(embedder);
      final token = CancelToken();
      embedder.hold = Completer<void>();
      final answer = decider.choose(_in('about a'), cancelToken: token);
      await pumpEventQueue();
      expect(embedder.calls.last.$1, 'about a', reason: 'the embedding runs');
      token.cancel();
      embedder.hold!.complete();
      await expectLater(answer, throwsA(isA<DeciderCancelledException>()));
    });

    test('a close while the input is embedded fails choose as a cancel, and '
        'leaves the embedder open', () async {
      final embedder = _embedder();
      final decider = await _decider(embedder);
      embedder.hold = Completer<void>();
      final answer = decider.choose(_in('about a'));
      await pumpEventQueue();
      await decider.close();
      embedder.hold!.complete();
      await expectLater(answer, throwsA(isA<DeciderCancelledException>()));
      expect(embedder.isClosed, isFalse);
    });

    test('the abstain signal is the top cosine, and says so', () async {
      final decider = await _decider(
        _embedder(),
        calibration: const EmbeddingDeciderCalibration.minSimilarity(0.5),
      );
      final answer = await decider.choose(_in('about a'));
      expect(answer.provenance.abstainSignalKind, AbstainSignalKind.topCosine);
      expect(
        answer.provenance.abstainSignal,
        closeTo(answer.ranked.first.score, 1e-12),
      );
      expect(answer.provenance.threshold, 0.5);
      expect(answer.provenance.method, DeciderMethod.centroid);
      final none = await decider.choose(_in('about a'), among: const []);
      expect(none.provenance.abstainSignal, isNull);
      expect(none.provenance.abstainSignalKind, isNull);
    });

    test('linear ranks by log-probability; calibrated probabilities over '
        'among renormalise', () async {
      final decider = await _decider(
        _embedder(),
        method: DeciderMethod.linear,
        // 'a or b' is nearly a tie, labelled the runner-up: rows answered
        // right with room to spare cannot calibrate a temperature.
        calibration: EmbeddingDeciderCalibration.fromLabelled([
          (input: _t('about a'), optionId: 'a'),
          (input: _t('about b'), optionId: 'b'),
          (input: _t('a or b'), optionId: 'b'),
        ], maxError: 0.4),
      );
      final answer = await decider.choose(_in('about b'));
      expect(answer.scoreKind, ScoreKind.logprob);
      expect(answer.choice, 'b');
      expect(answer.ranked.every((r) => r.score <= 0), isTrue);
      final p = answer.probabilities!;
      expect(p.keys, unorderedEquals(['a', 'b', 'c']));
      expect(p.values.fold(0.0, (s, v) => s + v), closeTo(1, 1e-12));
      expect(answer.confidence, inInclusiveRange(0, 1));
      for (final r in answer.ranked) {
        expect(r.probability, p[r.id]);
      }
      final two = await decider.choose(_in('about b'), among: ['a', 'b']);
      expect(two.probabilities!.keys, unorderedEquals(['a', 'b']));
      expect(
        two.probabilities!.values.fold(0.0, (s, v) => s + v),
        closeTo(1, 1e-12),
      );
      final one = await decider.choose(_in('about b'), among: ['b']);
      expect(one.probabilities, {'b': 1.0});
      expect(one.confidence, isNull);
    });
  });

  group('Decider.chooseAll', () {
    test('one embedding per embedder, answers in order', () async {
      final shared = _embedder();
      final first = await _decider(shared);
      final second = await _decider(
        shared,
        options: [
          DeciderOption('b', examples: [_t('b1')]),
          DeciderOption('c', examples: [_t('c1')]),
        ],
      );
      final apart = _embedder();
      final third = await _decider(apart);
      final other = _OtherDecider();
      shared.calls.clear();
      apart.calls.clear();

      final answers = await Decider.chooseAll(_in('about a'), [
        first,
        other,
        second,
        third,
      ]);
      expect(answers.map((a) => a.choice), ['a', 'x', 'b', 'a']);
      expect(shared.calls, [('about a', TaskType.sentenceSimilarity)]);
      expect(apart.calls, hasLength(1));
      expect(other.calls, 1);
      expect(
        answers[2].provenance.encodeTime,
        answers[0].provenance.encodeTime,
      );
    });

    test('a cancelled token fails it before embedding anything', () async {
      final embedder = _embedder();
      final decider = await _decider(embedder);
      embedder.calls.clear();
      await expectLater(
        Decider.chooseAll(_in('about a'), [
          decider,
        ], cancelToken: CancelToken()..cancel()),
        throwsA(isA<DeciderCancelledException>()),
      );
      expect(embedder.calls, isEmpty);
    });

    test(
      'its cancel token reaches a decider implemented outside core',
      () async {
        final other = _OtherDecider();
        final token = CancelToken();
        await Decider.chooseAll(_in('about a'), [other], cancelToken: token);
        expect(other.lastCancelToken, same(token));
      },
    );

    test('a cancel while the shared embedding runs drops it', () async {
      final embedder = _embedder();
      final first = await _decider(embedder);
      final second = await _decider(embedder);
      final token = CancelToken();
      embedder.hold = Completer<void>();
      final answers = Decider.chooseAll(_in('about a'), [
        first,
        second,
      ], cancelToken: token);
      await pumpEventQueue();
      token.cancel();
      embedder.hold!.complete();
      await expectLater(answers, throwsA(isA<DeciderCancelledException>()));
    });

    test('a member closed while the shared embedding runs fails it as a '
        'cancel', () async {
      final embedder = _embedder();
      final first = await _decider(embedder);
      final second = await _decider(embedder);
      embedder.hold = Completer<void>();
      final answers = Decider.chooseAll(_in('about a'), [first, second]);
      await pumpEventQueue();
      await second.close();
      embedder.hold!.complete();
      await expectLater(answers, throwsA(isA<DeciderCancelledException>()));
      expect(embedder.isClosed, isFalse);
    });

    test('refuses context before embedding anything', () async {
      final embedder = _embedder();
      final decider = await _decider(embedder);
      embedder.calls.clear();
      await expectLater(
        Decider.chooseAll(
          DeciderInput(
            _t('about a'),
            context: [const Message(text: 'x', isUser: true)],
          ),
          [decider],
        ),
        throwsA(isA<DeciderUnsupportedException>()),
      );
      expect(embedder.calls, isEmpty);
    });
  });

  group('choose checks every decider\'s request before decide runs', () {
    test('among, for a decider without supportsAmong', () async {
      final other = _OtherDecider();
      await expectLater(
        other.choose(_in('about a'), among: const ['x']),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('supportsAmong'),
          ),
        ),
      );
      expect(other.calls, 0);
    });

    test('a modality the decider does not take', () async {
      final other = _OtherDecider();
      await expectLater(
        other.choose(DeciderInput(EmbeddingInput.audio(Uint8List(4)))),
        throwsA(isA<DeciderUnsupportedException>()),
      );
      expect(other.calls, 0);
    });

    test('a topK below 1, and a token already cancelled', () async {
      final other = _OtherDecider();
      await expectLater(other.choose(_in('a'), topK: 0), throwsArgumentError);
      await expectLater(
        other.choose(_in('a'), cancelToken: CancelToken()..cancel()),
        throwsA(isA<DeciderCancelledException>()),
      );
      expect(other.calls, 0);
    });

    test('what it supports reaches decide: context, every candidate, the '
        'token', () async {
      final other = _OtherDecider();
      final token = CancelToken();
      await other.choose(
        DeciderInput(
          EmbeddingInput.text('a'),
          context: [const Message(text: 'earlier', isUser: true)],
        ),
        topK: 2,
        cancelToken: token,
      );
      final request = other.lastRequest!;
      expect(request.input.context, hasLength(1));
      expect(request.candidates, ['x']);
      expect(request.topK, 2);
      expect(request.cancelToken, same(token));
    });

    test('among reaches decide as known ids, each once, in option '
        'order', () async {
      final embedder = _embedder();
      final decider = await _decider(embedder);
      final answer = await decider.choose(
        _in('about a'),
        among: const ['c', 'a', 'c'],
      );
      expect(answer.ranked.map((r) => r.id).toSet(), {'a', 'c'});
      expect(answer.ranked, hasLength(2));
    });
  });

  group('a cancel during decide', () {
    test('drops the answer of a decider that ignores the token', () async {
      final token = CancelToken();
      final other = _OtherDecider()..onDecide = token.cancel;
      await expectLater(
        other.choose(_in('a'), cancelToken: token),
        throwsA(isA<DeciderCancelledException>()),
      );
      expect(other.calls, 1);
    });

    test('turns an exception that follows it into the cancel', () async {
      final token = CancelToken();
      final other = _OtherDecider()
        ..onDecide = () {
          token.cancel();
          throw const FormatException('the model failed after the cancel');
        };
      await expectLater(
        other.choose(_in('a'), cancelToken: token),
        throwsA(isA<DeciderCancelledException>()),
      );
    });

    test('lets an error (a bug) through', () async {
      final token = CancelToken();
      final other = _OtherDecider()
        ..onDecide = () {
          token.cancel();
          throw StateError('a bug');
        };
      await expectLater(
        other.choose(_in('a'), cancelToken: token),
        throwsStateError,
      );
    });

    test('an exception without a cancel arrives unchanged', () async {
      final other = _OtherDecider()
        ..onDecide = () => throw const FormatException('the model failed');
      await expectLater(other.choose(_in('a')), throwsFormatException);
    });
  });

  group('a decider implemented outside core', () {
    test('extends Decider; without an artifact, toArtifact throws '
        'DeciderUnsupportedException', () async {
      final other = _OtherDecider();
      expect(
        other.toArtifact,
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('_OtherDecider'),
          ),
        ),
      );
      expect(other.isClosed, isFalse);
      await other.close();
      expect(other.isClosed, isTrue);
    });
  });

  group('InferenceModel.createDecider', () {
    test('no engine scores options: it refuses, as a failed future', () async {
      final created = _Llm().createDecider(
        question: 'Which one?',
        options: _abc(),
        calibration: const InferenceDeciderCalibration(
          temperature: 1.3,
          abstainBelow: 0.6,
          noneOption: 'c',
        ),
        cancelToken: CancelToken(),
      );
      await expectLater(
        created,
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('EmbeddingModel.createDecider'),
          ),
        ),
      );
    });
  });

  group('optionScoring is an InferenceModel method', () {
    test('EmbeddingModel.createDecider refuses it', () async {
      await expectLater(
        _decider(_embedder(), method: DeciderMethod.optionScoring),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('InferenceModel'),
          ),
        ),
      );
    });

    test('an artifact naming it is refused', () async {
      final artifact = (await _decider(_embedder())).toArtifact()
        ..['method'] = 'optionScoring';
      await expectLater(
        _embedder().loadDecider(artifact, embedderId: 'fake'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('optionScoring'),
          ),
        ),
      );
    });
  });

  group('Jev', () {
    test('a Choice question becomes options', () {
      final options = DeciderOption.fromJevChoice({
        'type': 'choice',
        'instructions': 'Which department?',
        'criteria': {
          'returns': 'Exchanges, wrong or damaged items',
          'billing': null,
          'shipping': '',
          'other': {'hint': 'anything else'},
        },
      });
      expect(options.map((o) => o.id), [
        'returns',
        'billing',
        'shipping',
        'other',
      ]);
      expect(options.map((o) => o.description), [
        'Exchanges, wrong or damaged items',
        'billing',
        'shipping',
        '{"hint":"anything else"}',
      ]);
      expect(options.every((o) => o.examples.isEmpty), isTrue);
    });

    test('only Choice questions, with criteria', () {
      for (final question in [
        {'type': 'noul', 'instructions': 'x'},
        {
          'type': 'score',
          'criteria': ['low', 'high'],
        },
        {'type': 'choice'},
        {'type': 'choice', 'criteria': <String, Object?>{}},
      ]) {
        expect(
          () => DeciderOption.fromJevChoice(question),
          throwsArgumentError,
          reason: '$question',
        );
      }
    });

    test('toJevJson: choice only, or with calibrated probabilities', () async {
      final plain = await (await _decider(_embedder())).choose(_in('about a'));
      expect(plain.toJevJson(), {'type': 'choice', 'choice': 'a'});

      final calibrated = await (await _decider(
        _embedder(),
        calibration: EmbeddingDeciderCalibration.fromLabelled([
          (input: _t('about a'), optionId: 'a'),
          (input: _t('about b'), optionId: 'b'),
          (input: _t('a or b'), optionId: 'b'),
        ], maxError: 0.4),
      )).choose(_in('about b'));
      final json = calibrated.toJevJson();
      expect(json['type'], 'choice');
      expect(json['choice'], 'b');
      expect(json['confidence'], calibrated.confidence);
      expect(
        (json['probabilities']! as Map).keys,
        unorderedEquals(['a', 'b', 'c']),
      );

      final abstained = await (await _decider(
        _embedder(),
        calibration: const EmbeddingDeciderCalibration.minSimilarity(0.99),
      )).choose(_in('nothing'));
      expect(abstained.toJevJson(), {'type': 'choice', 'choice': null});
    });

    test('a Jev Choice question decided end to end', () async {
      final options = DeciderOption.fromJevChoice({
        'type': 'choice',
        'criteria': {'option a': null, 'option b': null},
      });
      final decider = await _decider(
        _embedder(),
        options: options,
        calibration: const EmbeddingDeciderCalibration.minSimilarity(0.5),
      );
      expect(
        (await decider.choose(_in('about b'))).toJevJson()['choice'],
        'option b',
      );
    });
  });
}
