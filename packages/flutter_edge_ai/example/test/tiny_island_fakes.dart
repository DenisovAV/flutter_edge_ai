// Fakes for the Tiny Island tests: a stand-in for core's embedder cache (one
// shared model, as getActiveEmbedder hands out), a bag-of-words embedder the
// real core Decider can fit on, a keyword decider and a scripted one for the
// view model's edge cases, and a stage that records what it played.

// The Decider API is @experimental.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_catalog.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_stage.dart';

/// Bag-of-words vectors: texts that share words point the same way. Not
/// built by core, so the decider needs an `embedderId` and cannot move to a
/// replacement when it is closed.
final class FakeEmbedder extends EmbeddingModel {
  FakeEmbedder(this.serial);

  /// 1 for the first model the fake core built, 2 for the next, ...
  final int serial;

  /// When set, every embed waits for it.
  Completer<void>? gate;
  int embeds = 0;
  final tasks = <TaskType>{};
  bool _closed = false;
  final _listeners = <void Function()>[];

  @override
  int get dimension => 128;

  @override
  PreferredBackend? get activeBackend => PreferredBackend.cpu;

  @override
  bool get isClosed => _closed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async {
    if (_closed) throw const EmbedderClosedException();
    if (gate case final gate?) await gate.future;
    // A request not started when the model closed never runs.
    if (_closed) throw const EmbedderClosedException();
    embeds++;
    tasks.add(taskType);
    final v = List<double>.filled(dimension, 0);
    v[dimension - 1] = 0.05;
    for (final word in RegExp(
      r'[\p{L}]+',
      unicode: true,
    ).allMatches(input.text!.toLowerCase())) {
      final w = word[0]!;
      if (const {'the', 'a', 'to', 'please', 'of'}.contains(w)) continue;
      v[w.hashCode.abs() % (dimension - 1)] += 1;
    }
    final norm = math.sqrt(v.fold(0.0, (s, x) => s + x * x));
    return [for (final x in v) x / norm];
  }

  @override
  void addCloseListener(void Function() listener) => _listeners.add(listener);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final listener in _listeners) {
      listener();
    }
  }
}

/// Core's embedder cache, as the screen meets it: one model per process,
/// the same instance to every caller until it is closed, then a new one.
/// Callers that ask while it is being built all get that build's model —
/// the order core's own cache may answer in, and the one in which a stale
/// screen closing "its" model hurts a newer screen.
final class FakeCore {
  FakeEmbedder? _current;
  Future<FakeEmbedder>? _building;

  /// When set, a build waits for it (a model still loading).
  Completer<void>? loadGate;

  /// Handed to the next model built as its [FakeEmbedder.gate].
  Completer<void>? nextEmbedGate;

  /// Every model built, in order.
  final built = <FakeEmbedder>[];

  Future<EmbeddingModel> getActiveEmbedder() {
    final current = _current;
    if (current != null && !current.isClosed) return Future.value(current);
    return _building ??= _build();
  }

  Future<FakeEmbedder> _build() async {
    try {
      await Future<void>.delayed(Duration.zero);
      if (loadGate case final gate?) await gate.future;
      final model = FakeEmbedder(built.length + 1)..gate = nextEmbedGate;
      nextEmbedGate = null;
      built.add(model);
      _current = model;
      return model;
    } finally {
      _building = null;
    }
  }
}

/// A model-free decider: each action's score is the best word overlap (Dice)
/// between the request and its examples and description. Deterministic and
/// instant; it knows no synonyms and no other language than the examples'.
final class KeywordDecider extends Decider {
  KeywordDecider(List<IslandAction> catalog, {this.threshold = 0.5})
    : options = List.unmodifiable([
        for (final action in catalog)
          DeciderOption(
            action.id,
            description: action.description,
            examples: [
              for (final example in action.examples)
                EmbeddingInput.text(example),
            ],
          ),
      ]),
      _phrases = {
        for (final action in catalog)
          action.id: [
            for (final text in [...action.examples, action.description])
              _words(text),
          ],
      };

  final double threshold;
  final Map<String, List<Set<String>>> _phrases;
  bool _closed = false;

  @override
  final List<DeciderOption> options;

  @override
  DeciderCapabilities get capabilities => const DeciderCapabilities(
    maxOptions: null,
    supportsContext: false,
    calibratedProbabilities: false,
    modalities: {EmbeddingModality.text},
  );

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async => _closed = true;

  @override
  Future<DeciderAnswer> choose(
    DeciderInput input, {
    Iterable<String>? among,
    int topK = 5,
  }) async {
    if (_closed) throw StateError('The decider is closed.');
    final watch = Stopwatch()..start();
    final words = _words(input.input.text!);
    final scored = [
      for (final MapEntry(key: id, value: phrases) in _phrases.entries)
        (
          id: id,
          score: phrases.fold(0.0, (best, phrase) {
            final dice = _dice(words, phrase);
            return dice > best ? dice : best;
          }),
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final best = scored.first.score;
    final abstain = best < threshold;
    return DeciderAnswer(
      choice: abstain ? null : scored.first.id,
      ranked: [
        for (final s in scored.take(topK))
          RankedOption(id: s.id, score: s.score),
      ],
      scoreKind: ScoreKind.cosine,
      margin: best - scored[1].score,
      abstainReason: abstain ? AbstainReason.belowThreshold : null,
      provenance: DeciderProvenance(
        method: DeciderMethod.centroid,
        calibration: 'minSimilarity',
        spaceId: 'keyword',
        embedTime: const Duration(milliseconds: 3),
        scoreTime: watch.elapsed,
        threshold: threshold,
        similarity: best,
      ),
    );
  }

  static const _stopWords = {'the', 'a', 'an', 'to', 'please', 'of', 'on'};

  static Set<String> _words(String text) => {
    for (final match in RegExp(
      r'[\p{L}\p{N}]+',
      unicode: true,
    ).allMatches(text.toLowerCase()))
      if (!_stopWords.contains(match[0])) match[0]!,
  };

  static double _dice(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    return 2 * a.intersection(b).length / (a.length + b.length);
  }
}

/// The keyword decider with a failure or an answer that can be forced.
final class ScriptedDecider extends Decider {
  ScriptedDecider(this._inner);

  final KeywordDecider _inner;

  /// Thrown by the next choose.
  Object? failNext;

  /// Answer with this id (scored 1), whatever was asked.
  String? answerWith;

  /// Abstain with nothing ranked (AbstainReason.noCandidates).
  bool answerEmpty = false;

  /// Give calibrated probabilities: the best option gets this one.
  double? probability;

  @override
  List<DeciderOption> get options => _inner.options;

  @override
  DeciderCapabilities get capabilities => _inner.capabilities;

  @override
  bool get isClosed => _inner.isClosed;

  bool get closed => _inner.isClosed;

  @override
  Future<void> close() => _inner.close();

  @override
  Future<DeciderAnswer> choose(
    DeciderInput input, {
    Iterable<String>? among,
    int topK = 5,
  }) async {
    if (failNext case final error?) {
      failNext = null;
      throw error;
    }
    final answer = await _inner.choose(input, topK: topK);
    if (answerEmpty) {
      return DeciderAnswer(
        choice: null,
        ranked: const [],
        scoreKind: ScoreKind.cosine,
        margin: 0,
        abstainReason: AbstainReason.noCandidates,
        provenance: answer.provenance,
      );
    }
    if (answerWith case final id?) {
      return DeciderAnswer(
        choice: id,
        ranked: [RankedOption(id: id, score: 1)],
        scoreKind: ScoreKind.cosine,
        margin: double.infinity,
        provenance: answer.provenance,
      );
    }
    if (probability case final p?) {
      final ranked = answer.ranked;
      final rest = (1 - p) / (options.length - 1);
      final probabilities = {
        for (final option in options) option.id: rest,
        ranked.first.id: p,
      };
      return DeciderAnswer(
        choice: answer.choice,
        ranked: [
          for (final r in ranked)
            RankedOption(
              id: r.id,
              score: r.score,
              probability: probabilities[r.id],
            ),
        ],
        scoreKind: answer.scoreKind,
        margin: answer.margin,
        abstainReason: answer.abstainReason,
        probabilities: probabilities,
        confidence: 0.9,
        provenance: answer.provenance,
      );
    }
    return answer;
  }
}

/// Records what was played; [hold] keeps every action playing until it
/// completes.
final class RecordingStage implements IslandStage {
  final performed = <String>[];
  int shrugs = 0;
  IslandOutcome outcome = const IslandOutcome.done();
  Completer<void>? hold;

  @override
  Future<IslandOutcome> perform(IslandAction action) async {
    performed.add(action.id);
    if (hold case final hold?) await hold.future;
    return outcome;
  }

  @override
  Future<void> shrug() async {
    shrugs++;
    if (hold case final hold?) await hold.future;
  }
}
