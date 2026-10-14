// The Tiny Island screen's logic over FAKES: the action catalog and the
// requests it is measured and demonstrated with, the recipe and the store of
// fitted deciders, core's real Decider over a bag-of-words embedder, the
// view model (the shared embedder lane, failures, the scene gate) and the
// HUD widgets. The real EmbeddingGemma 2 and the 3D scene run in
// integration_test/tiny_island_test.dart, the calibration measurement in
// integration_test/tiny_island_calibration_test.dart.

// The Decider API is @experimental.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_catalog.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_decider_preparation.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_decider_recipe.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_decider_store.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_decider_store_io.dart'
    show FileIslandDeciderStore;
import 'package:flutter_edge_ai_example/tiny_island/island_held_out_requests.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_hud.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_suggestions.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_vocabulary.dart';
import 'package:flutter_edge_ai_example/tiny_island/tiny_island_dependencies.dart';
import 'package:flutter_edge_ai_example/tiny_island/tiny_island_platform.dart';
import 'package:flutter_edge_ai_example/tiny_island/tiny_island_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tiny_island_fakes.dart';

const _setup = TinyIslandEmbedderSetup(
  embedderName: 'EmbeddingGemma 2 Text (270M)',
  model: 'embeddingGemma2Text270m',
);

/// Lower-case, letters and digits only: "Open the chest." == "open the
/// chest".
String _norm(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// Every option text of the catalog, normalised.
Set<String> _optionTexts(List<IslandAction> catalog) => {
  for (final action in catalog) ...[
    _norm(action.description),
    for (final example in action.examples) _norm(example),
  ],
};

/// A recipe the bag-of-words embedder can satisfy: a fixed threshold.
IslandDeciderRecipe _testRecipe(List<IslandAction> catalog) =>
    IslandDeciderRecipe(
      options: islandDeciderOptions(catalog),
      method: DeciderMethod.centroid,
      calibration: const DeciderCalibration.minSimilarity(0.5),
    );

void main() {
  final catalog = buildIslandCatalog();

  group('catalog', () {
    test('has 184 actions with unique ids, 920 option texts', () {
      expect(catalog, hasLength(184));
      expect({for (final a in catalog) a.id}, hasLength(catalog.length));
      expect(catalog.fold(0, (n, a) => n + a.examples.length + 1), 920);
    });

    test('every action has 3 to 6 examples, placeholders filled in', () {
      for (final action in catalog) {
        expect(
          action.examples.length,
          inInclusiveRange(3, 6),
          reason: action.id,
        );
        expect(
          [action.description, ...action.examples].join(' '),
          isNot(contains('{')),
          reason: '${action.id} kept a template placeholder',
        );
      }
    });

    test('no option text belongs to two actions', () {
      final owner = <String, String>{};
      for (final action in catalog) {
        for (final text in {
          _norm(action.description),
          for (final example in action.examples) _norm(example),
        }) {
          final other = owner.putIfAbsent(text, () => action.id);
          expect(other, action.id, reason: '"$text" is in both');
        }
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

  group('held-out requests and suggestions', () {
    final ids = {for (final a in catalog) a.id};
    final verbOf = {for (final a in catalog) a.id: a.verb};
    final optionTexts = _optionTexts(catalog);

    test('two held-out requests per verb, each naming a catalog action', () {
      final perVerb = <IslandVerb, int>{};
      for (final row in islandHeldOutRequests) {
        expect(ids, contains(row.actionId), reason: row.text);
        perVerb.update(verbOf[row.actionId]!, (n) => n + 1, ifAbsent: () => 1);
      }
      expect(perVerb.keys.toSet(), IslandVerb.values.toSet());
      expect(perVerb.values.toSet(), {2});
      expect(
        {for (final row in islandHeldOutRequests) _norm(row.text)},
        hasLength(islandHeldOutRequests.length),
        reason: 'a held-out request is repeated',
      );
    });

    test('no held-out request is an option example or description', () {
      for (final row in islandHeldOutRequests) {
        expect(optionTexts, isNot(contains(_norm(row.text))), reason: row.text);
      }
    });

    test('no suggestion chip is an option text or a held-out request', () {
      final held = {for (final row in islandHeldOutRequests) _norm(row.text)};
      for (final chip in islandSuggestions) {
        expect(optionTexts, isNot(contains(_norm(chip))), reason: chip);
        expect(held, isNot(contains(_norm(chip))), reason: chip);
      }
    });

    test("core accepts the app's calibration rows (no leaked example)", () {
      // The embedder fails the first embed: reaching it means every check
      // before embedding passed, the leakage check among them.
      final recipe = islandDeciderRecipe(catalog);
      expect(recipe.calibration.kind, 'labelled');
      expect(recipe.method, DeciderMethod.centroid);
      expect(
        _ThrowingEmbedder().createDecider(
          options: recipe.options,
          method: recipe.method,
          calibration: recipe.calibration,
          embedderId: 'fake',
        ),
        throwsA(isA<_Reached>()),
      );
      // Control: a row that repeats an example is refused before that.
      expect(
        _ThrowingEmbedder().createDecider(
          options: recipe.options,
          calibration: DeciderCalibration.fromLabelled([
            (
              input: EmbeddingInput.text(catalog.first.examples.first),
              optionId: catalog.first.id,
            ),
          ]),
          embedderId: 'fake',
        ),
        throwsArgumentError,
      );
    });
  });

  group('recipe', () {
    test('the fingerprint follows the options and the calibration rows', () {
      final a = islandDeciderRecipe(catalog);
      expect(a.fingerprint, islandDeciderRecipe(catalog).fingerprint);
      expect(a.fingerprint, hasLength(8));
      final fewer = islandDeciderRecipe(catalog.take(183).toList());
      expect(fewer.fingerprint, isNot(a.fingerprint));
      final otherRows = IslandDeciderRecipe(
        options: a.options,
        method: a.method,
        calibration: a.calibration,
        calibrationRows: islandHeldOutRequests.skip(1).toList(),
      );
      expect(otherRows.fingerprint, isNot(a.fingerprint));
      expect(a.calibrationLabel, 'calibrated on 144 held-out requests');
    });
  });

  group('file store', () {
    late Directory dir;
    late FileIslandDeciderStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('tiny_island_store');
      store = FileIslandDeciderStore(() async => dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test("round-trips, and prunes only the same model's older ones", () async {
      expect(await store.read(model: 'm', fingerprint: 'aaaa'), isNull);
      await store.write(model: 'm', fingerprint: 'aaaa', artifact: {'x': 1});
      await store.write(model: 'other', fingerprint: 'cccc', artifact: {});
      expect(await store.read(model: 'm', fingerprint: 'aaaa'), {'x': 1});
      expect(
        await store.write(model: 'm', fingerprint: 'bbbb', artifact: {'x': 2}),
        isNull,
      );
      expect(await store.read(model: 'm', fingerprint: 'aaaa'), isNull);
      expect(await store.read(model: 'm', fingerprint: 'bbbb'), {'x': 2});
      expect(await store.read(model: 'other', fingerprint: 'cccc'), isEmpty);
      expect(dir.listSync().map((f) => f.uri.pathSegments.last).toSet(), {
        'm--bbbb.json',
        'other--cccc.json',
      });
    });

    test('a damaged file is an error to show, not an empty store', () async {
      File('${dir.path}/m--aaaa.json').writeAsStringSync('{"truncat');
      await expectLater(
        store.read(model: 'm', fingerprint: 'aaaa'),
        throwsFormatException,
      );
    });

    test('a write that cannot happen throws', () async {
      final blocked = FileIslandDeciderStore(
        () async => Directory('${dir.path}/file/sub'),
      );
      File('${dir.path}/file').writeAsStringSync('');
      await expectLater(
        blocked.write(model: 'm', fingerprint: 'a', artifact: {}),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('prepareIslandDecider over core', () {
    late FakeEmbedder embedder;
    late MemoryIslandDeciderStore store;
    final recipe = _testRecipe(catalog);

    setUp(() {
      embedder = FakeEmbedder(1);
      store = MemoryIslandDeciderStore();
    });

    Future<PreparedIslandDecider> prepare({
      String embedderId = 'fake',
      IslandDeciderStore? into,
      IslandDeciderRecipe? using,
      List<int>? progress,
    }) => prepareIslandDecider(
      embedder: embedder,
      model: 'm',
      recipe: using ?? recipe,
      store: into ?? store,
      embedderId: embedderId,
      cancelToken: CancelToken(),
      onProgress: (done, _) => progress?.add(done),
    );

    test(
      'fits with classification, stores, then loads without embedding',
      () async {
        final progress = <int>[];
        final first = await prepare(progress: progress);
        expect(first.loaded, isFalse);
        expect(first.stored, isTrue);
        expect(first.refitReason, isNull);
        expect(embedder.embeds, 920);
        expect(embedder.tasks, {TaskType.classification});
        expect(progress.first, 0);
        expect(progress.last, 920);
        final answer = await first.decider.choose(
          DeciderInput(EmbeddingInput.text('water the flowers')),
        );
        expect(answer.choice, 'water(flowers)');

        embedder.embeds = 0;
        final second = await prepare();
        expect(second.loaded, isTrue);
        expect(embedder.embeds, 0, reason: 'nothing embedded at load');
        expect(
          (await second.decider.choose(
            DeciderInput(EmbeddingInput.text('water the flowers')),
          )).choice,
          'water(flowers)',
        );
      },
    );

    test('another embedding space is fitted again, and says why', () async {
      await prepare();
      final again = await prepare(embedderId: 'another-space');
      expect(again.loaded, isFalse);
      expect(again.refitReason, contains('another embedding space'));
      expect(again.stored, isTrue);
    });

    test('a damaged artifact is fitted again, and says why', () async {
      await store.write(
        model: 'm',
        fingerprint: recipe.fingerprint,
        artifact: {'format': 'something else'},
      );
      final again = await prepare();
      expect(again.loaded, isFalse);
      expect(again.refitReason, contains('not readable'));
    });

    test('an artifact for other actions is fitted again', () async {
      final other = _testRecipe(catalog.take(10).toList());
      final fitted = await prepare(using: other);
      await store.write(
        model: 'm',
        fingerprint: recipe.fingerprint,
        artifact: fitted.decider.toArtifact(),
      );
      final again = await prepare();
      expect(again.loaded, isFalse);
      expect(again.refitReason, contains('other actions'));
    });

    test('a store that fails is reported; the decider still works', () async {
      final prepared = await prepare(into: _FailingStore());
      expect(prepared.stored, isFalse);
      expect(prepared.storeProblem, contains('could not be stored'));
      expect(prepared.refitReason, contains('could not be read'));
      expect(
        (await prepared.decider.choose(
          DeciderInput(EmbeddingInput.text('jump')),
        )).choice,
        'jump',
      );
    });
  });

  group('view model', () {
    late FakeCore core;
    late RecordingStage stage;
    late MemoryIslandDeciderStore store;
    late IslandEmbedderLane lane;
    late TinyIslandSetup setup;

    setUp(() {
      core = FakeCore();
      stage = RecordingStage();
      store = MemoryIslandDeciderStore();
      lane = IslandEmbedderLane();
      setup = _setup;
    });

    TinyIslandDependencies deps({PrepareIslandDecider? prepare}) =>
        TinyIslandDependencies(
          readSetup: () async => setup,
          loadEmbedder: (_) => core.getActiveEmbedder(),
          store: store,
          recipe: _testRecipe,
          prepare: prepare ?? prepareIslandDecider,
          embedderId: 'fake',
          lane: lane,
        );

    /// A view model whose scene has loaded, opened.
    Future<TinyIslandViewModel> openVm({PrepareIslandDecider? prepare}) async {
      final vm = TinyIslandViewModel(deps(prepare: prepare), stage);
      addTearDown(vm.dispose);
      vm.sceneLoaded();
      await vm.open();
      return vm;
    }

    test('opens the Decider and says how it was prepared', () async {
      final vm = await openVm();
      expect(vm.status, TinyIslandStatus.ready);
      expect(vm.error, isNull);
      expect(vm.embedderName, 'EmbeddingGemma 2 Text (270M)');
      expect(vm.backend, 'cpu');
      expect(vm.optionCount, 184);
      expect(vm.prepareNote, contains('fitted on this device'));
      expect(vm.prepareNote, contains('stored in memory'));
      expect(vm.prepareTime, isNotNull);

      // A second visit loads what the first stored.
      final again = await openVm();
      expect(again.status, TinyIslandStatus.ready);
      expect(again.prepareNote, startsWith('loaded from'));
    });

    test('plays the chosen action on the stage', () async {
      final vm = await openVm();
      await vm.submit('water the flowers');
      final turn = vm.lastTurn!;
      expect(turn.answer!.choice, 'water(flowers)');
      expect(turn.answer!.scoreKind, ScoreKind.cosine);
      expect(turn.answer!.ranked.first.probability, isNull);
      expect(turn.action!.verb, IslandVerb.water);
      expect(stage.performed, ['water(flowers)']);
      expect(stage.shrugs, 0);
      expect(turn.outcome!.performed, isTrue);
    });

    test('abstains on chatter: the character shrugs, nothing plays', () async {
      final vm = await openVm();
      await vm.submit('what is the capital of France');
      final answer = vm.lastTurn!.answer!;
      expect(answer.choice, isNull);
      expect(answer.abstainReason, AbstainReason.belowThreshold);
      expect(stage.performed, isEmpty);
      expect(stage.shrugs, 1);
    });

    test(
      'a setup problem is shown, with the model list when it helps',
      () async {
        setup = const TinyIslandSetupProblem('No embedding model is active.');
        final vm = await openVm();
        expect(vm.status, TinyIslandStatus.failed);
        expect(vm.error, 'No embedding model is active.');
        expect(vm.suggestModelList, isTrue);
        expect(core.built, isEmpty);

        setup = const TinyIslandSetupProblem(
          'This browser has no WebGPU.',
          modelListHelps: false,
        );
        await vm.open();
        expect(vm.suggestModelList, isFalse, reason: 'no model would load');
      },
    );

    test('a model that does not load is shown, never replaced', () async {
      final vm = TinyIslandViewModel(
        TinyIslandDependencies(
          readSetup: () async => _setup,
          loadEmbedder: (_) async => throw const EmbeddingLoadException(
            'No EmbeddingGemma 2 here.',
            engine: 'LiteRT-LM',
          ),
          store: store,
          lane: lane,
        ),
        stage,
      );
      addTearDown(vm.dispose);
      vm.sceneLoaded();
      await vm.open();
      expect(vm.status, TinyIslandStatus.failed);
      expect(vm.error, contains('No EmbeddingGemma 2 here.'));
      expect(vm.suggestModelList, isTrue);
      await vm.submit('jump');
      expect(vm.turns, isEmpty, reason: 'nothing decides without a decider');
    });

    test('input waits for the scene; a failed scene keeps it off', () async {
      final vm = TinyIslandViewModel(deps(), stage);
      addTearDown(vm.dispose);
      await vm.open();
      expect(vm.status, TinyIslandStatus.ready);
      expect(vm.canSend, isFalse, reason: 'the scene has not loaded');
      await vm.submit('jump');
      expect(vm.turns, isEmpty);
      expect(stage.performed, isEmpty);

      vm.sceneLoaded();
      expect(vm.canSend, isTrue);
      await vm.submit('jump');
      expect(stage.performed, ['jump']);

      vm.sceneFailed('The island stopped drawing: lost context');
      expect(vm.canSend, isFalse);
      expect(vm.sceneError, contains('lost context'));
    });

    test('a closed embedder mid-session fails the screen; Try again '
        'recovers', () async {
      final vm = await openVm();
      // Not a model core built: the decider cannot move to a replacement.
      await core.built.single.close();
      await vm.submit('jump');
      expect(vm.status, TinyIslandStatus.failed);
      expect(vm.error, contains('EmbedderClosedException'));
      expect(vm.lastTurn!.error, isNotNull);
      expect(vm.canSend, isFalse);

      await vm.open();
      expect(vm.status, TinyIslandStatus.ready);
      expect(core.built, hasLength(2));
      await vm.submit('jump');
      expect(vm.lastTurn!.answer!.choice, 'jump');
    });

    test('a DeciderException fails the screen, not just the turn', () async {
      late ScriptedDecider scripted;
      final vm = await openVm(prepare: _scripted(catalog, (d) => scripted = d));
      scripted.failNext = const DeciderSpaceMismatchException(
        'another space',
        expected: 'a',
        actual: 'b',
      );
      await vm.submit('jump');
      expect(vm.status, TinyIslandStatus.failed);
      expect(vm.suggestModelList, isTrue);
      expect(vm.deciding, isFalse);
    });

    test(
      'an input error stays on its turn; the Decider keeps working',
      () async {
        late ScriptedDecider scripted;
        final vm = await openVm(
          prepare: _scripted(catalog, (d) => scripted = d),
        );
        scripted.failNext = const EmbeddingInputTooLongException(
          'too long',
          maxInputTokens: 1024,
          actualTokens: 2000,
        );
        await vm.submit('jump');
        expect(vm.status, TinyIslandStatus.ready);
        expect(vm.lastTurn!.error, contains('too long'));
        await vm.submit('jump');
        expect(stage.performed, ['jump']);
      },
    );

    test('a choice outside the catalog is an error, not a no-op', () async {
      late ScriptedDecider scripted;
      final vm = await openVm(prepare: _scripted(catalog, (d) => scripted = d));
      scripted.answerWith = 'fly_to(moon)';
      await vm.submit('fly to the moon');
      expect(vm.lastTurn!.error, contains('fly_to(moon)'));
      expect(stage.performed, isEmpty);
    });

    test('nothing ranked does not wedge the screen', () async {
      late ScriptedDecider scripted;
      final vm = await openVm(prepare: _scripted(catalog, (d) => scripted = d));
      scripted.answerEmpty = true;
      await vm.submit('jump');
      expect(vm.deciding, isFalse);
      expect(vm.lastTurn!.answer!.ranked, isEmpty);
      expect(stage.shrugs, 1);
    });

    test('refuses new requests while four are still playing', () async {
      final vm = await openVm(prepare: _scripted(catalog, (_) {}));
      stage.hold = Completer<void>();
      for (final request in ['jump', 'dance', 'tell me a joke', 'wave']) {
        unawaited(vm.submit(request));
        while (vm.deciding) {
          await pumpEventQueue();
        }
      }
      expect(vm.playing, 4, reason: 'the shrug counts too');
      expect(stage.shrugs, 1);
      // Past the cap, neither an action nor a shrug is queued.
      await vm.submit('what is the capital of France');
      expect(vm.lastTurn!.error, contains('still playing 4 actions'));
      expect(stage.shrugs, 1);
      await vm.submit('nod');
      expect(vm.lastTurn!.error, contains('still playing 4 actions'));
      expect(stage.performed, ['jump', 'dance', 'wave']);
      stage.hold!.complete();
      await pumpEventQueue();
      expect(vm.playing, 0);
    });

    test('dispose closes the decider and the embedder', () async {
      late ScriptedDecider scripted;
      final vm = TinyIslandViewModel(
        deps(prepare: _scripted(catalog, (d) => scripted = d)),
        stage,
      );
      await vm.open();
      vm.dispose();
      await lane.run(() async {});
      expect(scripted.closed, isTrue);
      expect(core.built.single.isClosed, isTrue);
    });

    // The lane. Core's embedder is one per process: without the lane, the
    // two tests below fail — the stale open closes the model the newer one
    // got from core.

    test('a screen left while its model loads never closes the model a '
        'newer screen uses', () async {
      core.loadGate = Completer<void>();
      final left = TinyIslandViewModel(deps(), stage)..sceneLoaded();
      final leftOpen = left.open();
      await pumpEventQueue();
      left.dispose();
      final next = TinyIslandViewModel(deps(), stage)..sceneLoaded();
      addTearDown(next.dispose);
      final nextOpen = next.open();
      // Without the lane, the newer open now waits on the same model load.
      await pumpEventQueue();
      core.loadGate!.complete();
      core.loadGate = null;
      await Future.wait([leftOpen, nextOpen]);

      expect(next.status, TinyIslandStatus.ready, reason: '${next.error}');
      expect(core.built, hasLength(2));
      expect(core.built.first.isClosed, isTrue, reason: 'the left one');
      expect(core.built.last.isClosed, isFalse, reason: 'the newer one');
      await next.submit('jump');
      expect(next.lastTurn!.answer!.choice, 'jump');
    });

    test('an open superseded on the same screen never closes what the newer '
        'open got', () async {
      core.loadGate = Completer<void>();
      final vm = TinyIslandViewModel(deps(), stage)..sceneLoaded();
      addTearDown(vm.dispose);
      final first = vm.open();
      await pumpEventQueue();
      final second = vm.open();
      await pumpEventQueue();
      core.loadGate!.complete();
      core.loadGate = null;
      await Future.wait([first, second]);

      expect(vm.status, TinyIslandStatus.ready, reason: '${vm.error}');
      expect(core.built.last.isClosed, isFalse);
      await vm.submit('jump');
      expect(vm.lastTurn!.answer!.choice, 'jump');
    });

    test('leaving while the catalog is embedded cancels the fit', () async {
      // The first model's embeds never finish: only the cancel ends that
      // open, and the next screen's open waits for it in the lane.
      core.nextEmbedGate = Completer<void>();
      final left = TinyIslandViewModel(deps(), stage)..sceneLoaded();
      final leftOpen = left.open();
      while (left.status != TinyIslandStatus.preparing) {
        await pumpEventQueue();
      }
      left.dispose();
      await leftOpen.timeout(const Duration(seconds: 5));

      final next = await openVm();
      expect(next.status, TinyIslandStatus.ready);
      expect(core.built.first.isClosed, isTrue);
      expect(core.built.last.isClosed, isFalse);
    });
  });

  group('HUD', () {
    Future<TinyIslandViewModel> vmAfter(
      String request, {
      double? probability,
      bool empty = false,
    }) async {
      final deps = TinyIslandDependencies(
        readSetup: () async => _setup,
        loadEmbedder: (_) async => FakeEmbedder(1),
        store: MemoryIslandDeciderStore(),
        prepare: _scripted(catalog, (d) {
          d.probability = probability;
          d.answerEmpty = empty;
        }),
        embedderId: 'fake',
        lane: IslandEmbedderLane(),
      );
      final vm = TinyIslandViewModel(deps, RecordingStage())..sceneLoaded();
      await vm.open();
      await vm.submit(request);
      return vm;
    }

    Widget host(TinyIslandViewModel vm) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TinyIslandStatusBar(viewModel: vm, onChooseModel: () {}),
            TinyIslandHud(viewModel: vm),
          ],
        ),
      ),
    );

    String text(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(Key(key))).data!;

    testWidgets('a raw cosine is shown as a cosine, never as a percentage', (
      tester,
    ) async {
      final vm = await tester.runAsync(() => vmAfter('open the chest'));
      addTearDown(vm!.dispose);
      await tester.pumpWidget(host(vm));
      expect(text(tester, 'tiny-island-choice'), 'open(chest)');
      final score = text(tester, 'tiny-island-choice-score');
      expect(score, contains('cosine'));
      expect(score, isNot(contains('%')));
      for (var i = 0; i < 3; i++) {
        final alt = text(tester, 'tiny-island-alternative-$i');
        expect(alt, isNot(contains('%')));
      }
      expect(
        text(tester, 'tiny-island-timing'),
        startsWith('Chosen among 184 actions in '),
      );
      final status = text(tester, 'tiny-island-backend');
      expect(status, contains('backend cpu'));
      expect(status, contains('184 actions'));
      expect(status, contains('calibrated on 144 held-out requests'));
    });

    testWidgets('a calibrated probability is shown as one', (tester) async {
      final vm = await tester.runAsync(
        () => vmAfter('open the chest', probability: 0.87),
      );
      addTearDown(vm!.dispose);
      await tester.pumpWidget(host(vm));
      expect(text(tester, 'tiny-island-choice-score'), contains('p 87%'));
    });

    testWidgets('says why it abstained, with the threshold', (tester) async {
      final vm = await tester.runAsync(() => vmAfter('tell me a joke'));
      addTearDown(vm!.dispose);
      await tester.pumpWidget(host(vm));
      expect(find.byKey(const Key('tiny-island-abstain')), findsOneWidget);
      expect(
        text(tester, 'tiny-island-abstain-reason'),
        allOf(startsWith('Nothing on the island fits'), contains('0.500')),
      );
      expect(text(tester, 'tiny-island-timing'), startsWith('Weighed '));
    });

    testWidgets('an answer with nothing ranked renders', (tester) async {
      final vm = await tester.runAsync(() => vmAfter('jump', empty: true));
      addTearDown(vm!.dispose);
      await tester.pumpWidget(host(vm));
      expect(tester.takeException(), isNull);
      expect(
        text(tester, 'tiny-island-abstain-reason'),
        'There were no actions to choose among.',
      );
    });

    testWidgets('a store problem is on the status line', (tester) async {
      final vm = TinyIslandViewModel(
        TinyIslandDependencies(
          readSetup: () async => _setup,
          loadEmbedder: (_) async => FakeEmbedder(1),
          store: MemoryIslandDeciderStore(),
          prepare: _scripted(catalog, (_) {}, storeProblem: 'disk full'),
          embedderId: 'fake',
          lane: IslandEmbedderLane(),
        ),
        RecordingStage(),
      );
      addTearDown(vm.dispose);
      await tester.runAsync(vm.open);
      await tester.pumpWidget(host(vm));
      expect(
        text(tester, 'tiny-island-backend'),
        contains('disk full: the next visit fits it again'),
      );
    });

    testWidgets('a failed setup offers the model list and a retry', (
      tester,
    ) async {
      final vm = TinyIslandViewModel(
        TinyIslandDependencies(
          readSetup: () async =>
              const TinyIslandSetupProblem('No embedding model is active.'),
          loadEmbedder: (_) async => FakeEmbedder(1),
          store: MemoryIslandDeciderStore(),
          lane: IslandEmbedderLane(),
        ),
        RecordingStage(),
      );
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
      expect(find.byKey(const Key('tiny-island-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tiny-island-choose-model')));
      expect(chose, 1);
    });
  });

  group('platforms', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('Windows and Linux get a reason, the others none', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        final reason = tinyIslandUnsupportedReason();
        if (platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux) {
          expect(reason, contains('Flutter GPU'), reason: '$platform');
        } else {
          expect(reason, isNull, reason: '$platform');
        }
      }
    });

    test('the scene hint names the cause per platform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(tinyIslandSceneHint(), contains('Skia'));
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(tinyIslandSceneHint(), contains('FLTEnableFlutterGPU'));
    });
  });

  test('formatIslandDuration', () {
    expect(formatIslandDuration(const Duration(milliseconds: 36)), '36 ms');
    expect(formatIslandDuration(const Duration(microseconds: 4200)), '4.2 ms');
    expect(formatIslandDuration(const Duration(microseconds: 420)), '0.42 ms');
  });
}

/// A preparation that hands the view model a [ScriptedDecider] over the
/// keyword fake, as if fitted.
PrepareIslandDecider _scripted(
  List<IslandAction> catalog,
  void Function(ScriptedDecider decider) configure, {
  String? storeProblem,
}) =>
    ({
      required embedder,
      required model,
      required recipe,
      required store,
      required cancelToken,
      required onProgress,
      embedderId,
    }) async {
      final decider = ScriptedDecider(KeywordDecider(catalog));
      configure(decider);
      return PreparedIslandDecider(
        decider: decider,
        loaded: false,
        stored: storeProblem == null,
        storeProblem: storeProblem,
      );
    };

final class _Reached implements Exception {
  const _Reached();
}

/// Fails the first embed: proves a createDecider got that far.
final class _ThrowingEmbedder extends EmbeddingModel {
  @override
  int get dimension => 8;

  @override
  bool get isClosed => false;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) => Future.error(const _Reached());

  @override
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async {}
}

final class _FailingStore implements IslandDeciderStore {
  @override
  String get where => 'a broken disk';

  @override
  Future<Map<String, Object?>?> read({
    required String model,
    required String fingerprint,
  }) => Future.error(const FileSystemException('Input/output error'));

  @override
  Future<String?> write({
    required String model,
    required String fingerprint,
    required Map<String, Object?> artifact,
  }) => Future.error(const FileSystemException('No space left on device'));
}
