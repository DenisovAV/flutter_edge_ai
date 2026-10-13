// The Tiny Island screen's logic over FAKES: the action catalog, the view
// model with the keyword fake decider and a recording stage (action
// dispatch, the abstain path, the HUD's values, every failure it must show),
// the embedding stand-in over a fake embedder (scoring, abstention, the
// vector cache), and the HUD widgets. The real EmbeddingGemma 2 and the 3D
// scene run in integration_test/tiny_island_test.dart.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/tiny_island/embedding_island_decider.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_catalog.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_decider.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_hud.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_scoring.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_stage.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_vector_cache.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_vocabulary.dart';
import 'package:flutter_edge_ai_example/tiny_island/keyword_island_decider.dart';
import 'package:flutter_edge_ai_example/tiny_island/tiny_island_dependencies.dart';
import 'package:flutter_edge_ai_example/tiny_island/tiny_island_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _setup = TinyIslandSetup(
  embedderName: 'EmbeddingGemma 2 Text (270M)',
  profileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1',
);

void main() {
  group('catalog', () {
    final catalog = buildIslandCatalog();

    test('has 150 to 300 actions with unique ids', () {
      expect(catalog.length, inInclusiveRange(150, 300));
      expect({for (final a in catalog) a.id}.length, catalog.length);
    });

    test('every action has 3 to 6 examples, one of them Russian', () {
      final cyrillic = RegExp('[а-яё]');
      for (final action in catalog) {
        expect(
          action.examples.length,
          inInclusiveRange(3, 6),
          reason: action.id,
        );
        expect(
          action.examples.where(cyrillic.hasMatch),
          isNotEmpty,
          reason: '${action.id} has no Russian phrasing',
        );
        expect(action.description, isNotEmpty, reason: action.id);
        expect(
          action.examples.join(' '),
          isNot(contains('{')),
          reason: '${action.id} kept a template placeholder',
        );
      }
    });

    test('every verb is used and ids read verb(thing)', () {
      expect({for (final a in catalog) a.verb}, IslandVerb.values.toSet());
      expect(catalog.firstWhere((a) => a.id == 'walk_to(tree)').metadata, {
        'verb': 'walk_to',
        'thing': 'tree',
      });
      expect(catalog.firstWhere((a) => a.id == 'jump').thing, isNull);
    });
  });

  group('rankIslandOptions', () {
    test('ranks, gives probabilities and the margin', () {
      final d = rankIslandOptions(
        scores: {'a': 0.9, 'b': 0.8, 'c': 0.1},
        threshold: 0.5,
        minMargin: 0.05,
        temperature: 0.1,
        embedTime: const Duration(milliseconds: 3),
        scoreTime: const Duration(microseconds: 400),
      );
      expect(d.choice, 'a');
      expect([for (final o in d.ranked) o.id], ['a', 'b', 'c']);
      expect(d.margin, closeTo(0.1, 1e-9));
      final total = d.ranked.fold(0.0, (s, o) => s + o.probability!);
      expect(total, closeTo(1, 1e-9));
      expect(d.ranked.first.probability, greaterThan(0.7));
      expect(d.totalTime, const Duration(microseconds: 3400));
    });

    test('abstains out of scope under the threshold', () {
      final d = rankIslandOptions(
        scores: {'a': 0.4, 'b': 0.1},
        threshold: 0.5,
        minMargin: 0,
        temperature: 0.1,
        embedTime: Duration.zero,
        scoreTime: Duration.zero,
      );
      expect(d.choice, isNull);
      expect(d.abstainReason, IslandAbstainReason.outOfScope);
    });

    test('abstains as ambiguous on a near-tie', () {
      final d = rankIslandOptions(
        scores: {'a': 0.9, 'b': 0.899},
        threshold: 0.5,
        minMargin: 0.002,
        temperature: 0.1,
        embedTime: Duration.zero,
        scoreTime: Duration.zero,
      );
      expect(d.abstainReason, IslandAbstainReason.ambiguous);
    });
  });

  group('view model', () {
    late _RecordingStage stage;
    late _Rig rig;

    setUp(() {
      stage = _RecordingStage();
      rig = _Rig();
    });

    Future<TinyIslandViewModel> openVm() async {
      final vm = TinyIslandViewModel(rig.deps, stage);
      addTearDown(vm.dispose);
      await vm.open();
      return vm;
    }

    test('opens the decider and reports what the HUD shows', () async {
      final vm = await openVm();
      expect(vm.status, TinyIslandStatus.ready);
      expect(vm.error, isNull);
      expect(vm.embedderName, 'EmbeddingGemma 2 Text (270M)');
      expect(vm.deciderName, 'Keyword match (test fake)');
      expect(vm.optionCount, vm.catalog.length);
      expect(vm.prepareTime, isNotNull);
      expect(rig.progress, isNotEmpty, reason: 'progress is reported');
    });

    test('plays the chosen action on the stage', () async {
      final vm = await openVm();
      await vm.submit('water the flowers');
      final turn = vm.lastTurn!;
      expect(turn.decision!.choice, 'water(flowers)');
      expect(turn.action!.verb, IslandVerb.water);
      expect(turn.action!.thing, IslandThing.flowers);
      expect(stage.performed, ['water(flowers)']);
      expect(stage.shrugs, 0);
      expect(turn.outcome!.performed, isTrue);
      expect(turn.decision!.ranked.length, greaterThanOrEqualTo(4));
      expect(turn.decision!.optionCount, vm.catalog.length);
    });

    test('shows what the stage declined', () async {
      stage.outcome = const IslandOutcome.declined(
        'The chest is already open.',
      );
      final vm = await openVm();
      await vm.submit('open the chest');
      expect(vm.lastTurn!.outcome!.note, 'The chest is already open.');
      expect(vm.lastTurn!.outcome!.performed, isFalse);
    });

    test('abstains on chatter: the character shrugs, nothing plays', () async {
      final vm = await openVm();
      await vm.submit('what is the capital of France');
      final decision = vm.lastTurn!.decision!;
      expect(decision.choice, isNull);
      expect(decision.abstainReason, IslandAbstainReason.outOfScope);
      expect(vm.lastTurn!.action, isNull);
      expect(stage.performed, isEmpty);
      expect(stage.shrugs, 1);
    });

    test('keeps the newest request first and ignores blank ones', () async {
      final vm = await openVm();
      await vm.submit('   ');
      expect(vm.turns, isEmpty);
      await vm.submit('jump');
      await vm.submit('dance');
      expect([for (final t in vm.turns) t.request], ['dance', 'jump']);
    });

    test('a setup problem is shown with a way to the model list', () async {
      rig.setup = const TinyIslandSetup(
        problem: 'No embedding model is active.',
      );
      final vm = await openVm();
      expect(vm.status, TinyIslandStatus.failed);
      expect(vm.error, 'No embedding model is active.');
      expect(vm.suggestModelList, isTrue);
      expect(rig.opened, 0);
    });

    test('a model that does not load is shown, never replaced', () async {
      rig.openError = const EmbeddingLoadException(
        'No EmbeddingGemma 2 here.',
        engine: 'LiteRT-LM',
      );
      final vm = await openVm();
      expect(vm.status, TinyIslandStatus.failed);
      expect(vm.error, 'No EmbeddingGemma 2 here.');
      expect(vm.suggestModelList, isTrue);
      await vm.submit('jump');
      expect(vm.turns, isEmpty, reason: 'nothing decides without a decider');
    });

    test('a failed decision stays on its turn; nothing plays', () async {
      final vm = await openVm();
      rig.decider!.failNext = StateError('The embedder is closed.');
      await vm.submit('jump');
      expect(vm.lastTurn!.error, 'The embedder is closed.');
      expect(vm.deciding, isFalse);
      expect(stage.performed, isEmpty);
      expect(stage.shrugs, 0);
    });

    test(
      'a choice outside the catalog is an error, not a silent no-op',
      () async {
        final vm = await openVm();
        rig.decider!.answerWith = 'fly_to(moon)';
        await vm.submit('fly to the moon');
        expect(vm.lastTurn!.error, contains('fly_to(moon)'));
        expect(stage.performed, isEmpty);
      },
    );

    test('dispose closes the decider; reopening closes the old one', () async {
      final vm = TinyIslandViewModel(rig.deps, stage);
      await vm.open();
      final first = rig.decider!;
      await vm.open();
      expect(first.closed, isTrue);
      final second = rig.decider!;
      vm.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(second.closed, isTrue);
    });
  });

  group('embedding stand-in', () {
    late _WordEmbedder model;
    late MemoryIslandVectorCache cache;
    final catalog = buildIslandCatalog();

    setUp(() {
      model = _WordEmbedder();
      cache = MemoryIslandVectorCache();
    });

    Future<EmbeddingIslandDecider> create({List<int>? progress}) =>
        EmbeddingIslandDecider.create(
          model: model,
          name: 'fake',
          profileId: 'fake/profile:1',
          catalog: catalog,
          cache: cache,
          onProgress: (done, _) => progress?.add(done),
          closeModel: true,
          threshold: 0.8,
        );

    test('embeds every example and description once, then caches', () async {
      final progress = <int>[];
      final decider = await create(progress: progress);
      final texts = catalog.fold(0, (n, a) => n + a.examples.length + 1);
      expect(model.calls, texts);
      expect(progress.last, texts);
      expect(model.tasks, {TaskType.sentenceSimilarity});
      expect(decider.optionCount, catalog.length);

      model.calls = 0;
      await create();
      expect(model.calls, 0, reason: 'the second visit reads the cache');
    });

    test('chooses the closest action and abstains on chatter', () async {
      final decider = await create();
      final hit = await decider.decide('please water the flowers');
      expect(hit.choice, 'water(flowers)');
      expect(hit.ranked.first.score, greaterThan(0.8));
      expect(hit.embedTime, greaterThan(Duration.zero));

      final miss = await decider.decide('what is the capital of France');
      expect(miss.choice, isNull);
      expect(miss.abstainReason, IslandAbstainReason.outOfScope);
      expect(miss.threshold, 0.8);
    });

    test(
      'stops between batches when cancelled, and close closes the model',
      () async {
        await expectLater(
          EmbeddingIslandDecider.create(
            model: model,
            name: 'fake',
            profileId: 'p',
            catalog: catalog,
            cache: cache,
            isCancelled: () => true,
          ),
          throwsStateError,
        );
        final decider = await create();
        await decider.close();
        expect(model.isClosed, isTrue);
      },
    );
  });

  group('HUD', () {
    Future<TinyIslandViewModel> vmAfter(String request) async {
      final rig = _Rig();
      final vm = TinyIslandViewModel(rig.deps, _RecordingStage());
      await vm.open();
      await vm.submit(request);
      return vm;
    }

    testWidgets('shows the choice, three runners-up and the timing', (
      tester,
    ) async {
      final vm = await tester.runAsync(() => vmAfter('open the chest'));
      addTearDown(vm!.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TinyIslandStatusBar(viewModel: vm, onChooseModel: () {}),
                TinyIslandHud(viewModel: vm),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('tiny-island-choice')), findsOneWidget);
      expect(find.textContaining('open(chest)'), findsWidgets);
      expect(find.text('Open the treasure chest.'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(Key('tiny-island-alternative-$i')), findsOneWidget);
      }
      final timing = tester.widget<Text>(
        find.byKey(const Key('tiny-island-timing')),
      );
      expect(
        timing.data,
        startsWith('Chosen among ${vm.catalog.length} actions in '),
      );
      expect(timing.data, contains('embed '));
      expect(timing.data, contains('score '));
      final status = tester.widget<Text>(
        find.byKey(const Key('tiny-island-backend')),
      );
      expect(status.data, contains('backend unknown'));
      expect(status.data, contains('${vm.catalog.length} actions'));
    });

    testWidgets('shows why it abstained', (tester) async {
      final vm = await tester.runAsync(() => vmAfter('tell me a joke'));
      addTearDown(vm!.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TinyIslandHud(viewModel: vm)),
        ),
      );
      expect(find.byKey(const Key('tiny-island-abstain')), findsOneWidget);
      final reason = tester.widget<Text>(
        find.byKey(const Key('tiny-island-abstain-reason')),
      );
      expect(reason.data, startsWith('Nothing on the island matches'));
      expect(
        tester.widget<Text>(find.byKey(const Key('tiny-island-timing'))).data,
        startsWith('Weighed '),
      );
    });

    testWidgets('a failed setup offers the model list', (tester) async {
      final rig = _Rig()
        ..setup = const TinyIslandSetup(
          problem: 'No embedding model is active.',
        );
      final vm = TinyIslandViewModel(rig.deps, _RecordingStage());
      addTearDown(vm.dispose);
      await tester.runAsync(vm.open);
      var chose = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TinyIslandStatusBar(
              viewModel: vm,
              onChooseModel: () => chose++,
            ),
          ),
        ),
      );
      expect(find.text('No embedding model is active.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tiny-island-choose-model')));
      expect(chose, 1);
    });
  });

  test('formatIslandDuration', () {
    expect(formatIslandDuration(const Duration(milliseconds: 36)), '36 ms');
    expect(formatIslandDuration(const Duration(microseconds: 4200)), '4.2 ms');
    expect(formatIslandDuration(const Duration(microseconds: 420)), '0.42 ms');
  });
}

/// The screen's dependencies, with knobs.
final class _Rig {
  TinyIslandSetup setup = _setup;
  Object? openError;
  int opened = 0;
  final progress = <int>[];
  _ScriptedDecider? decider;

  late final deps = TinyIslandDependencies(
    readSetup: () async => setup,
    openDecider:
        (setup, catalog, {required onProgress, required isCancelled}) async {
          opened++;
          if (openError case final error?) throw error;
          onProgress(1, 2);
          progress.add(1);
          onProgress(2, 2);
          progress.add(2);
          return decider = _ScriptedDecider(KeywordIslandDecider(catalog));
        },
  );
}

/// The keyword fake, with a failure or an answer that can be forced.
final class _ScriptedDecider implements IslandDecider {
  _ScriptedDecider(this._inner);

  final KeywordIslandDecider _inner;
  Object? failNext;
  String? answerWith;
  bool closed = false;

  @override
  String get name => _inner.name;

  @override
  String? get backend => _inner.backend;

  @override
  int get optionCount => _inner.optionCount;

  @override
  Future<IslandDecision> decide(String request) async {
    if (failNext case final error?) {
      failNext = null;
      throw error;
    }
    final decision = await _inner.decide(request);
    if (answerWith case final id?) {
      return IslandDecision(
        choice: id,
        ranked: [IslandRankedOption(id: id, score: 1)],
        margin: 1,
        embedTime: decision.embedTime,
        scoreTime: decision.scoreTime,
        optionCount: decision.optionCount,
      );
    }
    return decision;
  }

  @override
  Future<void> close() async {
    closed = true;
    await _inner.close();
  }
}

final class _RecordingStage implements IslandStage {
  final performed = <String>[];
  int shrugs = 0;
  IslandOutcome outcome = const IslandOutcome.done();

  @override
  Future<IslandOutcome> perform(IslandAction action) async {
    performed.add(action.id);
    return outcome;
  }

  @override
  Future<void> shrug() async => shrugs++;
}

/// Bag-of-words vectors: texts that share words point the same way.
final class _WordEmbedder extends EmbeddingModel {
  int calls = 0;
  final tasks = <TaskType>{};
  bool _closed = false;

  @override
  int get dimension => 128;

  @override
  bool get isClosed => _closed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async {
    if (_closed) throw const EmbedderClosedException();
    calls++;
    tasks.add(taskType);
    // A visible cost, so the stand-in's embed timing is above zero.
    await Future<void>.delayed(const Duration(microseconds: 50));
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
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async => _closed = true;
}
