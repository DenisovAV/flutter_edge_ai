// Tiny Island on a device: the REAL screen — the flutter_scene island, core's
// Decider over the active EmbeddingGemma 2 — driven by typed requests.
//
// 1. First visit, no stored decider: the screen fits one (920 option texts
//    plus 144 calibration rows embedded) and stores it in the app's cache.
// 2. Every case below is sent and checked: the EXACT action id (or an
//    abstention), no error on the turn. All cases run before the test fails,
//    so the log shows each one; then "N of M" is the real count.
// 3. Second visit: the stored decider is loaded (the status line says so),
//    and the first request sent once the input is enabled plays.
//
// None of the requests is an option's example or description, nor a
// held-out calibration request (checked first). They check the screen's
// wiring end to end, not the Decider's accuracy: calibrated to keep its
// errors under 5 %, it abstains on about a third of in-scope paraphrases
// (measured by tiny_island_calibration_test.dart), so a paraphrase it
// declines is replaced here, not counted as a regression. The suggestion
// chips are sent last and only logged. Prints `[island]` lines: each
// decision with its score and timing, the fit, the first and warm decision
// times.
//
// The embedder: --dart-define=TINY_ISLAND_EMBEDDER_MODEL=<catalog name>
// (default the CPU 270m; a per-SoC bundle such as
// embeddingGemma2Text270mSm8850 must then report backend npu) and
// TINY_ISLAND_EMBEDDER_FILE=<local copy> — see tiny_island_support.dart.
// TINY_ISLAND_SHOTS=true writes PNG screenshots into
// <documents>/tiny_island_shots; TINY_ISLAND_PHONE=true lays the desktop
// window out at phone size (390 x 844).
//
//   flutter test integration_test/tiny_island_test.dart -d macos \
//     --dart-define=TINY_ISLAND_EMBEDDER_FILE=...
//
// The scene needs Flutter GPU, which this app's macOS, iOS and Android
// manifests turn on. No setUp/setUpAll (Rule 6b): the test body provisions
// first.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_catalog.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_held_out_requests.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_suggestions.dart';
import 'package:flutter_edge_ai_example/tiny_island_screen.dart';
import 'package:flutter_scene/scene.dart' show SceneView;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'tiny_island_support.dart';

const _shots = bool.fromEnvironment('TINY_ISLAND_SHOTS');
const _phone = bool.fromEnvironment('TINY_ISLAND_PHONE');

bool get _desktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

final _boundary = GlobalKey();

void _log(String line) {
  // ignore: avoid_print
  print('[island] $line');
}

/// A request, the action it must choose (null: it must abstain), and how
/// long the island needs to play it.
typedef _Case = ({String request, String? expect, double play, String? shot});

const _cases = <_Case>[
  (
    request: 'stroll over to the well',
    expect: 'walk_to(well)',
    play: 4,
    shot: null,
  ),
  (
    request: 'crack open the treasure chest',
    expect: 'open(chest)',
    play: 6,
    shot: 'chest',
  ),
  (
    request: 'pour some water on the flowers',
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
  (request: 'устрой закат', expect: 'make_sunset', play: 2.5, shot: null),
  (
    request: 'turn the lantern on',
    expect: 'turn_on(lamp)',
    play: 6,
    shot: null,
  ),
  (
    request: 'build a campfire',
    expect: 'light(campfire)',
    play: 5,
    shot: 'night',
  ),
  (request: 'сядь на лавочку', expect: 'sit_on(bench)', play: 5, shot: null),
  (request: 'geh zum Baum', expect: 'walk_to(tree)', play: 5, shot: null),
  (request: 'I want it to rain', expect: 'start_rain', play: 3, shot: 'rain'),
  (request: 'dance a little jig', expect: 'dance', play: 6, shot: null),
  (
    request: 'do a dance at the fire pit',
    expect: 'dance_by(campfire)',
    play: 6,
    shot: null,
  ),
  (request: 'tell me a joke', expect: null, play: 2.5, shot: null),
  (
    request: 'climb up the oak tree',
    expect: 'climb(tree)',
    play: 5,
    shot: null,
  ),
  (request: 'how much is two plus two', expect: null, play: 2.5, shot: null),
  (
    request: 'close the lid of the chest',
    expect: 'close(chest)',
    play: 5,
    shot: null,
  ),
  (
    request: 'выключи свет в домике',
    expect: 'lights_off(house)',
    play: 4,
    shot: null,
  ),
];

String _norm(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

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
      _log('HUD when $what timed out: ${_texts(tester)}');
      fail('timed out waiting for $what');
    }
    if (watch.elapsed.inSeconds ~/ 10 > reported) {
      reported = watch.elapsed.inSeconds ~/ 10;
      _log('still waiting for $what after ${watch.elapsed.inSeconds} s');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Every text on screen, for a failure message.
String _texts(WidgetTester tester) => [
  for (final element in find.byType(Text).evaluate())
    (element.widget as Text).data ??
        (element.widget as Text).textSpan?.toPlainText() ??
        '',
].where((t) => t.isNotEmpty).join(' | ');

Future<void> _play(WidgetTester tester, double seconds) async {
  final end = DateTime.now().add(
    Duration(milliseconds: (seconds * 1000).round()),
  );
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

bool _has(Key key) => find.byKey(key).evaluate().isNotEmpty;

String _text(WidgetTester tester, Key key) {
  final widget = tester.widget(find.byKey(key));
  return switch (widget) {
    Text(:final data?) => data,
    Text(:final textSpan?) => textSpan.toPlainText(),
    SelectableText(:final data?) => data,
    _ => '$widget',
  };
}

bool _inputEnabled(WidgetTester tester) =>
    _has(const Key('tiny-island-input')) &&
    tester
            .widget<TextField>(find.byKey(const Key('tiny-island-input')))
            .enabled !=
        false;

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

Widget _app(Key key) => RepaintBoundary(
  key: _boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark),
    home: TinyIslandScreen(key: key),
  ),
);

/// Waits for the Decider (fails on its error), then the scene and the
/// enabled input; returns the status line.
Future<String> _waitReady(WidgetTester tester) async {
  await _waitUntil(
    tester,
    () =>
        _has(const Key('tiny-island-backend')) ||
        _has(const Key('tiny-island-error')),
    what: 'the Decider',
  );
  if (_has(const Key('tiny-island-error'))) {
    fail(
      'the Decider did not start: '
      '${_text(tester, const Key('tiny-island-error'))}',
    );
  }
  final status = _text(tester, const Key('tiny-island-backend'));
  await _waitUntil(
    tester,
    () =>
        find.byType(SceneView).evaluate().isNotEmpty ||
        _has(const Key('tiny-island-scene-error')),
    what: 'the scene',
  );
  if (_has(const Key('tiny-island-scene-error'))) {
    fail(
      'the 3D scene did not load: '
      '${_text(tester, const Key('tiny-island-scene-error'))}',
    );
  }
  await _waitUntil(
    tester,
    () => _inputEnabled(tester),
    what: 'the input',
    timeout: const Duration(seconds: 30),
  );
  return status;
}

typedef _Outcome = ({String got, String timing, String? error, double? ms});

/// Sends [request] and waits for its decision on the HUD.
Future<_Outcome> _send(WidgetTester tester, String request) async {
  final input = find.byKey(const Key('tiny-island-input'));
  // Tapping send unfocuses the field on desktop (tap outside), so it is
  // tapped first: enterText alone would type into a closed connection.
  await tester.tap(input);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.enterText(input, request);
  await tester.tap(find.byKey(const Key('tiny-island-send')));
  bool mine() =>
      _has(const Key('tiny-island-request')) &&
      _text(tester, const Key('tiny-island-request')) == '"$request"';
  await _waitUntil(
    tester,
    () =>
        mine() &&
        (_has(const Key('tiny-island-timing')) ||
            _has(const Key('tiny-island-turn-error'))),
    what: 'a decision for "$request"',
    timeout: const Duration(seconds: 90),
  );
  final error = _has(const Key('tiny-island-turn-error'))
      ? _text(tester, const Key('tiny-island-turn-error'))
      : null;
  final timing = _has(const Key('tiny-island-timing'))
      ? _text(tester, const Key('tiny-island-timing'))
      : '';
  final got = _has(const Key('tiny-island-choice'))
      ? _text(tester, const Key('tiny-island-choice'))
      : _has(const Key('tiny-island-abstain'))
      ? 'abstained'
      : 'nothing';
  final score = _has(const Key('tiny-island-choice-score'))
      ? _text(tester, const Key('tiny-island-choice-score')).trim()
      : _has(const Key('tiny-island-abstain-reason'))
      ? _text(tester, const Key('tiny-island-abstain-reason'))
      : '';
  _log(
    '"$request" -> $got  $score | $timing'
    '${error == null ? '' : ' | ERROR $error'}',
  );
  final ms = RegExp(r' in ([\d.]+) ms').firstMatch(timing)?.group(1);
  return (
    got: got,
    timing: timing,
    error: error,
    ms: ms == null ? null : double.parse(ms),
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Every frame the app asks for, so the scene animates between pumps.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Tiny Island: the Decider picks the action, the island plays '
      'it', (tester) async {
    final model = await ensureTinyIslandEmbedder();

    // The cases are new sentences, not the Decider's own data.
    final known = {
      for (final action in buildIslandCatalog()) ...[
        _norm(action.description),
        for (final example in action.examples) _norm(example),
      ],
      for (final row in islandHeldOutRequests) _norm(row.text),
    };
    for (final c in _cases) {
      expect(
        known,
        isNot(contains(_norm(c.request))),
        reason: '"${c.request}" is an option text or a calibration row',
      );
    }

    // First visit: no stored decider, so the screen fits one.
    final store = Directory(
      '${(await getApplicationCacheDirectory()).path}'
      '${Platform.pathSeparator}tiny_island_deciders',
    );
    if (store.existsSync()) store.deleteSync(recursive: true);

    if (_desktop) {
      await binding.setSurfaceSize(
        _phone ? const Size(390, 844) : const Size(1000, 760),
      );
    }
    final fit = Stopwatch()..start();
    await tester.pumpWidget(_app(const ValueKey('first')));
    final status = await _waitReady(tester);
    _log('first visit ready in ${fit.elapsedMilliseconds} ms: $status');
    expect(status, contains('fitted on this device'));
    expect(status, contains("stored in the app's cache directory"));
    if (tinyIslandExpectsNpu()) {
      expect(
        status,
        contains('backend npu'),
        reason: '${model.name} runs on the NPU only',
      );
    }
    await _play(tester, 2);
    await _screenshot('start');

    final outcomes = <(_Case, _Outcome)>[];
    for (final c in _cases) {
      final outcome = await _send(tester, c.request);
      outcomes.add((c, outcome));
      await _play(tester, c.play);
      if (c.shot case final shot?) await _screenshot(shot);
    }
    final wrong = [
      for (final (c, o) in outcomes)
        if (o.error != null || o.got != (c.expect ?? 'abstained'))
          '"${c.request}": want ${c.expect ?? 'abstained'}, got ${o.got}'
              '${o.error == null ? '' : ' (error: ${o.error})'}',
    ];
    final times = [for (final (_, o) in outcomes) ?o.ms];
    final warm = times.skip(1).toList()..sort();
    _log(
      '${outcomes.length - wrong.length} of ${outcomes.length} requests '
      'decided as expected',
    );
    if (times.isNotEmpty) {
      _log(
        'decision time (embed + score): first ${times.first} ms, warm '
        'median ${warm.isEmpty ? '-' : warm[warm.length ~/ 2]} ms, max '
        '${warm.isEmpty ? '-' : warm.last} ms (n=${warm.length})',
      );
    }
    for (final line in wrong) {
      _log('WRONG $line');
    }

    // Second visit: the stored decider loads; the first request plays.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    final load = Stopwatch()..start();
    await tester.pumpWidget(_app(const ValueKey('second')));
    final second = await _waitReady(tester);
    _log('second visit ready in ${load.elapsedMilliseconds} ms: $second');
    expect(second, contains('loaded from'));
    final first = await _send(tester, 'stroll over to the well');
    expect(first.error, isNull, reason: 'the first request after a load');
    expect(first.got, 'walk_to(well)');
    await _play(tester, 1);
    expect(
      find.byKey(const Key('tiny-island-note')),
      findsNothing,
      reason: 'the island played it (no "still loading" remark)',
    );
    await _play(tester, 4);

    // The chips, as a user would tap them: logged, not asserted.
    for (final (i, chip) in islandSuggestions.indexed) {
      final chipButton = find.byKey(Key('tiny-island-suggestion-$i'));
      await tester.scrollUntilVisible(
        chipButton,
        150,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('tiny-island-suggestions')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(chipButton);
      await _waitUntil(
        tester,
        () =>
            _has(const Key('tiny-island-request')) &&
            _text(tester, const Key('tiny-island-request')) == '"$chip"' &&
            (_has(const Key('tiny-island-timing')) ||
                _has(const Key('tiny-island-turn-error'))),
        what: 'a decision for the chip "$chip"',
        timeout: const Duration(seconds: 90),
      );
      final got = _has(const Key('tiny-island-choice'))
          ? _text(tester, const Key('tiny-island-choice'))
          : 'abstained';
      final score = _has(const Key('tiny-island-choice-score'))
          ? _text(tester, const Key('tiny-island-choice-score')).trim()
          : _has(const Key('tiny-island-abstain-reason'))
          ? _text(tester, const Key('tiny-island-abstain-reason'))
          : '';
      _log('chip "$chip" -> $got  $score');
      await _play(tester, 4);
    }

    expect(wrong, isEmpty, reason: wrong.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
