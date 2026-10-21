// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart' hide Message, ModelResponse;
import 'package:genkit/genkit.dart' as g show Message, ModelResponse;
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

/// A decider whose answer and failure each test sets.
final class _FakeDecider extends Decider {
  _FakeDecider({this.answer, this.questionType = DeciderQuestionType.choice});

  DeciderAnswer Function(DeciderRequest request)? answer;
  final DeciderQuestionType questionType;
  Object? throws;
  bool closeOnChoose = false;
  int calls = 0;
  DeciderRequest? lastRequest;
  Completer<void>? gate;
  bool _closed = false;

  @override
  DeciderCapabilities get capabilities => DeciderCapabilities(
    modalities: const {EmbeddingModality.text},
    calibratedProbabilities: false,
    supportsContext: false,
    supportsAmong: false,
    storable: false,
    questionType: questionType,
  );

  @override
  List<DeciderOption> get options => [
    DeciderOption('easy', description: 'easy'),
    DeciderOption('hard', description: 'hard'),
  ];

  @override
  bool get isClosed => _closed;

  @override
  Future<DeciderAnswer> decide(DeciderRequest request) async {
    calls++;
    lastRequest = request;
    if (gate case final g?) await g.future;
    if (closeOnChoose) {
      _closed = true;
      throw const DeciderCancelledException('The decider was closed.');
    }
    if (throws case final e?) throw e;
    return answer!(request);
  }

  @override
  Future<void> close() async => _closed = true;
}

DeciderAnswer _chose(String id, {double signal = 0.8, double margin = 0.3}) =>
    DeciderAnswer(
      choice: id,
      ranked: [
        RankedOption(id: id, score: -0.2),
        const RankedOption(id: 'other', score: -1.5),
      ],
      scoreKind: ScoreKind.logprob,
      margin: margin,
      provenance: DeciderProvenance(
        method: DeciderMethod.centroid,
        calibration: 'crossFit',
        spaceId: 'eg2-270m-cpu',
        encodeTime: const Duration(milliseconds: 12),
        scoreTime: const Duration(microseconds: 300),
        threshold: 0.5,
        abstainSignal: signal,
        abstainSignalKind: AbstainSignalKind.topCosine,
      ),
    );

DeciderAnswer _abstained() => DeciderAnswer(
  choice: null,
  abstainReason: AbstainReason.belowThreshold,
  ranked: const [RankedOption(id: 'easy', score: 0.1)],
  scoreKind: ScoreKind.cosine,
  margin: 0.01,
  provenance: const DeciderProvenance(
    method: DeciderMethod.centroid,
    calibration: 'crossFit',
    spaceId: 'eg2-270m-cpu',
    encodeTime: Duration.zero,
    scoreTime: Duration.zero,
    threshold: 0.5,
    abstainSignal: 0.1,
    abstainSignalKind: AbstainSignalKind.topCosine,
  ),
);

RouteRequest _request(String? text) => RouteRequest(
  GenerateActionOptions(
    messages: [
      if (text != null)
        g.Message(
          role: Role.user,
          content: [TextPart(text: text)],
        ),
    ],
  ),
);

void main() {
  test('a choice is a label scored by the abstain signal', () async {
    final decider = _FakeDecider(answer: (_) => _chose('hard'));
    final verdict = await deciderRouteClassifier(
      () => decider,
    ).classify(_request('Write a sonnet'));
    expect(verdict, isA<LabelVerdict>());
    verdict as LabelVerdict;
    expect(verdict.label, 'hard');
    expect(verdict.score, 0.8);
    expect(verdict.margin, 0.3);
    expect(verdict.details['spaceId'], 'eg2-270m-cpu');
    expect(verdict.details['topScore'], -0.2);
    expect(
      (decider.lastRequest!.input.input).text,
      'Write a sonnet',
      reason: 'the last user message is classified',
    );
  });

  test('an infinite margin (one option) becomes null', () async {
    final verdict =
        await deciderRouteClassifier(
              () => _FakeDecider(
                answer: (_) => _chose('easy', margin: double.infinity),
              ),
            ).classify(_request('hi'))
            as LabelVerdict;
    expect(verdict.margin, isNull);
  });

  test('an abstain is an abstain verdict', () async {
    final verdict = await deciderRouteClassifier(
      () => _FakeDecider(answer: (_) => _abstained()),
    ).classify(_request('hi'));
    expect(verdict, isA<AbstainVerdict>());
    expect((verdict as AbstainVerdict).reason, 'belowThreshold');
  });

  test('no text abstains without asking the decider', () async {
    var asked = 0;
    final classifier = deciderRouteClassifier(() {
      asked++;
      return null;
    });
    expect(await classifier.classify(_request(null)), isA<AbstainVerdict>());
    expect(await classifier.classify(_request('  ')), isA<AbstainVerdict>());
    expect(asked, 0);
  });

  test('a null provider is unavailable', () {
    expect(
      deciderRouteClassifier(() => null).classify(_request('hi')),
      throwsA(isA<RouteClassifierUnavailableException>()),
    );
  });

  test('a pending decider is waited for', () async {
    final loading = Completer<Decider?>();
    final result = deciderRouteClassifier(
      () => loading.future,
    ).classify(_request('hi'));
    loading.complete(_FakeDecider(answer: (_) => _chose('easy')));
    expect(await result, isA<LabelVerdict>());
  });

  test('a Genkit cancel ends the wait for a pending decider', () async {
    final controller = CancellationController();
    final result = deciderRouteClassifier(
      () => Completer<Decider?>().future,
    ).classify(_request('hi'), cancel: controller.token);
    controller.cancel('stop');
    await expectLater(result, throwsA(isA<CancelledException>()));
  });

  test('a Genkit cancel reaches the decider and is not unavailable', () async {
    final decider = _FakeDecider(answer: (_) => _chose('easy'))
      ..gate = Completer<void>();
    final controller = CancellationController();
    final result = deciderRouteClassifier(
      () => decider,
    ).classify(_request('hi'), cancel: controller.token);
    await Future<void>.delayed(Duration.zero);
    controller.cancel('stop');
    expect(decider.lastRequest!.cancelToken!.isCancelled, isTrue);
    decider.gate!.complete();
    await expectLater(result, throwsA(isA<DeciderCancelledException>()));
  });

  test('a closed decider asks the provider once more', () async {
    final old = _FakeDecider(answer: (_) => _chose('easy'));
    await old.close();
    final fresh = _FakeDecider(answer: (_) => _chose('hard'));
    var asked = 0;
    final verdict =
        await deciderRouteClassifier(
              () => ++asked == 1 ? old : fresh,
            ).classify(_request('hi'))
            as LabelVerdict;
    expect(verdict.label, 'hard');
    expect(asked, 2);
  });

  test('the same closed decider twice is unavailable', () async {
    final old = _FakeDecider(answer: (_) => _chose('easy'));
    await old.close();
    expect(
      deciderRouteClassifier(() => old).classify(_request('hi')),
      throwsA(isA<RouteClassifierUnavailableException>()),
    );
  });

  test('closed mid-choose without a Genkit cancel is unavailable', () {
    final decider = _FakeDecider(answer: (_) => _chose('easy'))
      ..closeOnChoose = true;
    expect(
      deciderRouteClassifier(() => decider).classify(_request('hi')),
      throwsA(isA<RouteClassifierUnavailableException>()),
    );
  });

  test('any other error propagates, never an abstain', () {
    final decider = _FakeDecider(answer: (_) => _chose('easy'))
      ..throws = const EmbeddingInputTooLongException(
        'too long',
        maxInputTokens: 1024,
        actualTokens: 2000,
      );
    expect(
      deciderRouteClassifier(() => decider).classify(_request('hi')),
      throwsA(isA<EmbeddingInputTooLongException>()),
    );
    final broken = _FakeDecider(answer: (_) => _chose('easy'))
      ..throws = StateError('a bug');
    expect(
      deciderRouteClassifier(() => broken).classify(_request('hi')),
      throwsA(isA<StateError>()),
    );
  });

  test('a decider that is not a choice is refused', () {
    final noul = _FakeDecider(questionType: DeciderQuestionType.noul);
    expect(
      deciderRouteClassifier(() => noul).classify(_request('hi')),
      throwsArgumentError,
    );
  });

  test('routes a hybrid router call end to end', () async {
    final ai = Genkit(isDevEnv: false, promptDir: null);
    addTearDown(ai.shutdown);
    ai.defineModel(
      name: 'local',
      fn: (req, _) async => g.ModelResponse(
        finishReason: FinishReason.stop,
        message: g.Message(
          role: Role.model,
          content: [TextPart(text: 'local')],
        ),
      ),
    );
    final router = defineHybridRouter(
      ai,
      targets: {kOnDevice: HybridTarget.onDevice(modelRef('local'))},
      policies: {
        'smart': RoutePolicy(
          classifier: deciderRouteClassifier(
            () => _FakeDecider(answer: (_) => _chose('easy')),
          ),
          labels: const {'easy': kOnDevice},
        ),
      },
      defaultPolicy: 'smart',
    );
    final r = await router.generate(prompt: 'hello');
    expect(r.text, 'local');
    expect(r.route!.label, 'easy');
    expect(r.route!.classifier, 'flutter-edge-ai/decider');
  });
}
