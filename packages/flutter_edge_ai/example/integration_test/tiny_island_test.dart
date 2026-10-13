// Tiny Island on a device: the REAL screen — the flutter_scene island, the
// Decider over the active EmbeddingGemma 2 — driven by typed requests. Checks
// that each request picks the expected action (English, Russian, German),
// that chatter abstains, and that the island plays what was chosen; prints
// `[island]` lines with the choice, its score and the time it took.
//
// Model: EmbeddingGemma 2 Text (270M), installed first (a no-op once
// installed) and made the active embedder: --dart-define=
// TINY_ISLAND_EMBEDDER_FILE=<a local copy> (checked against the catalog's
// SHA-256; on macOS it must sit inside the app's container, e.g.
// ~/Library/Containers/dev.flutterberlin.flutterGemmaExample/Data/eg2_local/),
// else downloaded (165 MB, ungated).
//
// Options: TINY_ISLAND_SHOTS=true writes PNG screenshots into
// <documents>/tiny_island_shots; TINY_ISLAND_PHONE=true lays the desktop
// window out at phone size (390 x 844).
//
//   flutter test integration_test/tiny_island_test.dart -d macos \
//     --dart-define=TINY_ISLAND_EMBEDDER_FILE=... --dart-define=TINY_ISLAND_SHOTS=true
//
// The scene needs Flutter GPU, which this app's macOS, iOS and Android
// manifests turn on. No setUp/setUpAll (Rule 6b): the test body provisions
// first.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/services/embedding_catalog_install.dart';
import 'package:flutter_edge_ai_example/services/embedding_catalog_provenance.dart';
import 'package:flutter_edge_ai_example/tiny_island_screen.dart';
import 'package:flutter_scene/scene.dart' show SceneView;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _embedderFile = String.fromEnvironment('TINY_ISLAND_EMBEDDER_FILE');
const _shots = bool.fromEnvironment('TINY_ISLAND_SHOTS');
const _phone = bool.fromEnvironment('TINY_ISLAND_PHONE');
const _embedder = catalog.EmbeddingModel.embeddingGemma2Text270m;

bool get _desktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

final _boundary = GlobalKey();

void _log(String line) {
  // ignore: avoid_print
  print('[island] $line');
}

/// Installs EmbeddingGemma 2 Text (270M) and records it as the catalog entry,
/// as an install from the Embedding Models list would.
Future<void> _ensureEmbedder() async {
  await bootstrapGemma();
  if (_embedderFile.isNotEmpty) {
    final digest = await sha256.bind(File(_embedderFile).openRead()).first;
    expect(
      '$digest',
      _embedder.sha256,
      reason: '$_embedderFile is not the pinned ${_embedder.filename}',
    );
    await FlutterEdgeAi.installEmbedder()
        .modelFromFile(_embedderFile, filename: _embedder.filename)
        .install();
    await persistVerifiedEmbeddingCatalogSelection(
      _embedder,
      spec: EmbeddingModelSpec(
        name: _embedder.filename,
        modelSource: ModelSource.network(_embedder.url),
        modelFilename: _embedder.filename,
      ),
    );
  } else {
    await withCatalogEmbedderSources(
      FlutterEdgeAi.installEmbedder(),
      _embedder,
    ).install();
  }
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration timeout = const Duration(minutes: 4),
}) async {
  final watch = Stopwatch()..start();
  var reported = 0;
  while (!done()) {
    if (watch.elapsed > timeout) {
      _log('HUD when $what timed out: ${_hud(tester)}');
      fail('timed out waiting for $what');
    }
    if (watch.elapsed.inSeconds ~/ 10 > reported) {
      reported = watch.elapsed.inSeconds ~/ 10;
      _log('still waiting for $what after ${watch.elapsed.inSeconds} s');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Every text in the HUD, for a failure message.
String _hud(WidgetTester tester) {
  final hud = find.byKey(const Key('tiny-island-hud'));
  if (hud.evaluate().isEmpty) return '(no HUD)';
  return [
    for (final element
        in find.descendant(of: hud, matching: find.byType(Text)).evaluate())
      (element.widget as Text).data ??
          (element.widget as Text).textSpan?.toPlainText() ??
          '',
  ].join(' | ');
}

Future<void> _play(WidgetTester tester, double seconds) async {
  final end = DateTime.now().add(
    Duration(milliseconds: (seconds * 1000).round()),
  );
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _text(WidgetTester tester, Key key) {
  final widget = tester.widget<Text>(find.byKey(key));
  return widget.data ?? widget.textSpan?.toPlainText() ?? '';
}

int _shot = 0;

Future<void> _screenshot(String name) async {
  if (!_shots) return;
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final directory = await Directory(
    '${(await getApplicationDocumentsDirectory()).path}/tiny_island_shots',
  ).create(recursive: true);
  final file = File(
    '${directory.path}/${(++_shot).toString().padLeft(2, '0')}_$name.png',
  );
  await file.writeAsBytes(png!.buffer.asUint8List());
  _log('screenshot ${file.path}');
}

/// A request, the action it must choose (null: it must abstain), and how
/// long the island needs to play it.
typedef _Case = ({String request, String? expect, double play, String? shot});

const _cases = <_Case>[
  (
    request: 'walk over to the well',
    expect: 'walk_to(well)',
    play: 4,
    shot: null,
  ),
  (
    request: 'open the treasure chest',
    expect: 'open(chest)',
    play: 6,
    shot: 'chest',
  ),
  (
    request: 'water the flower bed',
    expect: 'water(flowers)',
    play: 5,
    shot: null,
  ),
  (
    request: 'what is the capital of France?',
    expect: null,
    play: 1.2,
    shot: 'abstain',
  ),
  (request: 'make it night time', expect: 'make_night', play: 2.5, shot: null),
  (
    request: 'switch on the lantern',
    expect: 'turn_on(lamp)',
    play: 6,
    shot: null,
  ),
  (request: 'light a fire', expect: 'light(campfire)', play: 5, shot: 'night'),
  (request: 'сядь на лавочку', expect: 'sit_on(bench)', play: 5, shot: null),
  (request: 'geh zum Baum', expect: 'walk_to(tree)', play: 5, shot: null),
  (request: 'make it rain', expect: 'start_rain', play: 3, shot: 'rain'),
  (request: 'dance for me', expect: 'dance', play: 6, shot: null),
  (request: 'tell me a joke', expect: null, play: 2.5, shot: null),
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Every frame the app asks for, so the scene animates between pumps.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Tiny Island: EmbeddingGemma 2 picks the action, the island '
      'plays it', (tester) async {
    await _ensureEmbedder();
    if (_desktop) {
      await binding.setSurfaceSize(
        _phone ? const Size(390, 844) : const Size(1000, 760),
      );
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(brightness: Brightness.dark),
          home: const TinyIslandScreen(),
        ),
      ),
    );

    final open = Stopwatch()..start();
    await _waitUntil(
      tester,
      () =>
          find.byKey(const Key('tiny-island-backend')).evaluate().isNotEmpty ||
          find.byKey(const Key('tiny-island-error')).evaluate().isNotEmpty,
      what: 'the Decider',
    );
    expect(
      find.byKey(const Key('tiny-island-error')),
      findsNothing,
      reason: 'the Decider did not start',
    );
    _log(
      'Decider ready in ${open.elapsedMilliseconds} ms: '
      '${_text(tester, const Key('tiny-island-backend'))}',
    );
    await _waitUntil(
      tester,
      () =>
          find.byType(SceneView).evaluate().isNotEmpty ||
          find
              .byKey(const Key('tiny-island-scene-error'))
              .evaluate()
              .isNotEmpty,
      what: 'the scene',
    );
    expect(
      find.byKey(const Key('tiny-island-scene-error')),
      findsNothing,
      reason: 'the 3D scene did not load',
    );
    await _play(tester, 2);
    await _screenshot('start');

    final input = find.byKey(const Key('tiny-island-input'));
    var right = 0;
    for (final c in _cases) {
      // Tapping send unfocuses the field on desktop (tap outside), so it is
      // tapped first: enterText alone would type into a closed connection.
      await tester.tap(input);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(input, c.request);
      await tester.tap(find.byKey(const Key('tiny-island-send')));
      await _waitUntil(
        tester,
        () =>
            find.byKey(const Key('tiny-island-timing')).evaluate().isNotEmpty &&
            _text(tester, const Key('tiny-island-request')) == '"${c.request}"',
        what: 'a decision for "${c.request}"',
        timeout: const Duration(seconds: 90),
      );
      final timing = _text(tester, const Key('tiny-island-timing'));
      if (c.expect case final expected?) {
        final choice = _text(tester, const Key('tiny-island-choice'));
        _log('"${c.request}" -> $choice | $timing');
        expect(choice, startsWith(expected), reason: c.request);
        right++;
      } else {
        expect(
          find.byKey(const Key('tiny-island-abstain')),
          findsOneWidget,
          reason: '"${c.request}" should abstain',
        );
        _log(
          '"${c.request}" -> abstained: '
          '${_text(tester, const Key('tiny-island-abstain-reason'))} | $timing',
        );
        right++;
      }
      await _play(tester, c.play);
      if (c.shot case final shot?) await _screenshot(shot);
    }
    _log('$right of ${_cases.length} requests decided as expected');
    expect(find.byKey(const Key('tiny-island-turn-error')), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
