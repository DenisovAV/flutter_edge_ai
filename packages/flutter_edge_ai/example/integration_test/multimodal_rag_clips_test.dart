// Short Multimodal RAG clips for a screen recording, driven on the real screen
// with the real models. Everything up to the `[clip] … start` line is setup
// (index the library, load Gemma 4, open the tab); cut the recording there.
//
//   --dart-define=MULTIMODAL_RAG_CLIP=search  search as it is typed: "the airport
//       taxi receipt" finds the receipt photo, then "Find similar" searches
//       the photos with it.
//   --dart-define=MULTIMODAL_RAG_CLIP=ask   "How much was the airport taxi?": the
//       amount is only in the receipt photo; EmbeddingGemma 2 finds the
//       uncaptioned photo by meaning, Gemma 4 reads the total off it, and a
//       citation card shows the photo.
//   --dart-define=MULTIMODAL_RAG_CLIP=askvoice  the same question SPOKEN (the
//       bundled recording, as if from the microphone): its sound is the query
//       (EmbeddingGemma 2 audio → the receipt photo) and Gemma 4 hears it with
//       the photo. Nothing is transcribed.
//   --dart-define=MULTIMODAL_RAG_CLIP=live  the bundled two-voice meeting is fed
//       as if from the microphone, cut into utterance windows; EmbeddingGemma
//       2 embeds each window's sound once — what it is about surfaces from
//       the library (the Q3 note and chart, the kitchen memo, the receipt) —
//       and Gemma 4 hears it, catching "Wait, how much did the airport taxi
//       cost?"; the question is answered with the receipt card. Then "When did we talk about the kitchen?" lands on the
//       window where the kitchen came up. If Gemma 4 names no question by
//       the end of the meeting, the clip presses "Answer what was just said"
//       and says so.
//
// `[clip] <epoch ms> <event>` lines mark the moments, on the clock the
// recording host shares with the iOS Simulator, for cutting and for laying
// the meeting's audio back under the video (simctl records no sound).
// Models: see multimodal_rag_models.dart. No setUp (Rule 6b).
//
//   xcrun simctl status_bar <udid> override --time 9:41 --batteryState charged \
//     --batteryLevel 100 --cellularBars 4 --wifiBars 3
//   xcrun simctl io <udid> recordVideo --codec h264 clip.mp4 &
//   flutter test integration_test/multimodal_rag_clips_test.dart -d <udid> \
//     --dart-define=MULTIMODAL_RAG_CLIP=live --dart-define=MULTIMODAL_RAG_EMBEDDER_FILE=… \
//     --dart-define=MULTIMODAL_RAG_LLM_FILE=…/gemma-4-E2B-it.litertlm

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_widgets.dart';
import 'package:flutter_edge_ai_example/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'multimodal_rag_models.dart';

const _clip = String.fromEnvironment(
  'MULTIMODAL_RAG_CLIP',
  defaultValue: 'ask',
);
const _shotsDir = String.fromEnvironment('MULTIMODAL_RAG_DEMO_SHOTS_DIR');
final _shotBoundary = GlobalKey();
int _shot = 0;

/// A PNG of the app (3x) into MULTIMODAL_RAG_DEMO_SHOTS_DIR, when set.
Future<void> _screenshot(String name) async {
  if (_shotsDir.isEmpty) return;
  final boundary =
      _shotBoundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 3);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File(
    '${(await Directory(_shotsDir).create(recursive: true)).path}/'
    '${_clip}_${(++_shot).toString().padLeft(2, '0')}_$name.png',
  );
  await file.writeAsBytes(png!.buffer.asUint8List());
  _log('screenshot ${file.path}');
}

const _paceDefine = String.fromEnvironment('MULTIMODAL_RAG_DEMO_PACE');
final double _pace = double.tryParse(_paceDefine) ?? 1.0;

bool get _desktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

void _log(String line) {
  // ignore: avoid_print
  print('[clip] $line');
}

void _mark(String event) =>
    _log('${DateTime.now().millisecondsSinceEpoch} $event');

Future<void> _pause(WidgetTester tester, int ms) =>
    tester.pump(Duration(milliseconds: (ms * _pace).round()));

Future<Duration> _waitUntil(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration timeout = const Duration(minutes: 4),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > timeout) fail('timed out waiting for $what');
    await tester.pump(const Duration(milliseconds: 100));
  }
  return watch.elapsed;
}

bool _found(Finder finder) => finder.evaluate().isNotEmpty;

String _texts(Finder finder) => [
  for (final e
      in find.descendant(of: finder, matching: find.byType(Text)).evaluate())
    (e.widget as Text).data ??
        (e.widget as Text).textSpan?.toPlainText(includePlaceholders: false) ??
        '',
].join(' | ');

Future<void> _type(WidgetTester tester, Finder field, String text) async {
  await tester.tap(field);
  await _pause(tester, 250);
  for (var i = 1; i <= text.length; i++) {
    await tester.enterText(field, text.substring(0, i));
    await tester.pump(Duration(milliseconds: (55 * _pace).round()));
  }
}

/// Opens Multimodal RAG, indexes the library and waits for Gemma 4 to load.
Future<void> _setUpScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotBoundary,
      child: const ChatApp(debugBanner: false),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  final card = find.byKey(const Key('home-multimodal-rag'));
  await tester.scrollUntilVisible(
    card,
    400,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(card);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(card);
  await _waitUntil(
    tester,
    () => _found(find.byKey(const Key('multimodal-rag-tab-search'))),
    what: 'the indexes to open',
  );
  final index = find.byKey(const Key('multimodal-rag-index'));
  if (_found(index)) {
    await tester.tap(index);
    final took = await _waitUntil(
      tester,
      () => !_found(find.byKey(const Key('multimodal-rag-pending'))),
      what: 'indexing',
    );
    _log('indexed in ${took.inMilliseconds} ms');
  }
  final loaded = await _waitUntil(
    tester,
    () => _found(find.textContaining('loaded in')),
    what: 'Gemma 4 to load',
  );
  _log('language model ready ${loaded.inMilliseconds} ms after indexing');
}

Future<void> _askClip(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('multimodal-rag-tab-ask')));
  await _pause(tester, 800);
  _mark('start');
  await _pause(tester, 1200);
  final field = find.descendant(
    of: find.byKey(const Key('multimodal-rag-ask-field')),
    matching: find.byType(EditableText),
  );
  await _type(tester, field, kMultimodalRagQuestions[0]);
  await _pause(tester, 350);
  await tester.tap(find.byKey(const Key('multimodal-rag-ask-send')));
  _mark('asked');
  await _waitUntil(
    tester,
    () =>
        _found(find.byKey(const Key('multimodal-rag-citation-1'))) ||
        (_found(find.byKey(const Key('multimodal-rag-ask-send'))) &&
            _found(find.byKey(const Key('multimodal-rag-answer-stats'))) &&
            _texts(
              find.byKey(const Key('multimodal-rag-answer')),
            ).contains('tok/s')),
    what: 'the answer',
  );
  _mark('answered');
  await _pause(tester, 1200);
  await _screenshot('answer');
  final answer = _texts(find.byKey(const Key('multimodal-rag-answer')));
  _log('answer: $answer');
  expect(answer, contains('26.50'), reason: 'read off the receipt photo');
  expect(
    find.byKey(const Key('multimodal-rag-citation-1')),
    findsOneWidget,
    reason: 'the receipt is cited',
  );
  await _pause(tester, 4000);
  _mark('end');
}

/// Search as it is typed: a query finds the receipt photo by meaning, then
/// "Find similar" searches the photos with it.
Future<void> _searchClip(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('multimodal-rag-tab-search')));
  await _pause(tester, 800);
  _mark('start');
  await _pause(tester, 1200);
  final field = find.descendant(
    of: find.byKey(const Key('multimodal-rag-search-field')),
    matching: find.byType(EditableText),
  );
  Future<String> searchFor(String text) async {
    await _type(tester, field, text);
    await _pause(tester, 600);
    await _waitUntil(
      tester,
      () =>
          _found(find.byKey(const Key('multimodal-rag-result-0'))) &&
          _found(find.byKey(const Key('multimodal-rag-search-go'))),
      what: '"$text"',
    );
    final first = _texts(find.byKey(const Key('multimodal-rag-result-0')));
    _mark('searched "$text" → $first');
    await _pause(tester, 1800);
    return first;
  }

  expect(await searchFor('the airport taxi receipt'), contains('IMG_0412'));
  await _screenshot('receipt');
  final similar = find.byKey(const Key('multimodal-rag-similar-photo-0412'));
  await tester.ensureVisible(similar);
  await _pause(tester, 400);
  await tester.tap(similar);
  _mark('similar');
  await _waitUntil(
    tester,
    () =>
        _found(find.textContaining('image → image')) &&
        _found(find.byKey(const Key('multimodal-rag-result-0'))),
    what: 'similar photos',
  );
  _mark('similar ${_texts(find.byKey(const Key('multimodal-rag-result-0')))}');
  await _pause(tester, 1500);
  await _screenshot('similar');
  await _pause(tester, 2500);
  _mark('end');
}

/// S2b: the question is spoken (the bundled recording, as if from the
/// microphone); its sound is the query.
Future<void> _askVoiceClip(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('multimodal-rag-tab-ask')));
  await _pause(tester, 800);
  _mark('start');
  await _pause(tester, 1500);
  await tester.tap(find.byKey(const Key('multimodal-rag-ask-voice')));
  await _pause(tester, 700);
  await tester.tap(find.byKey(const Key('multimodal-rag-ask-voice-sample')));
  _mark('question-audio');
  await _waitUntil(
    tester,
    () => _found(find.byKey(const Key('multimodal-rag-citation-1'))),
    what: 'the answer',
  );
  _mark('answered');
  await _pause(tester, 1200);
  await _screenshot('answer');
  final answer = _texts(find.byKey(const Key('multimodal-rag-answer')));
  _log('answer: $answer');
  expect(answer, contains('26.50'), reason: 'read off the receipt photo');
  await _pause(tester, 3000);
  _mark('end');
}

/// S3: the meeting, heard live.
Future<void> _liveClip(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('multimodal-rag-tab-live')));
  await _pause(tester, 800);
  _mark('start');
  await _pause(tester, 1500);
  await tester.tap(find.byKey(const Key('multimodal-rag-live-start')));
  _mark('meeting');
  final question = find.byKey(const Key('multimodal-rag-live-question'));
  // The meeting is over (every window processed) when its search opens.
  final search = find.byKey(const Key('multimodal-rag-meeting-search'));
  bool finishedNow() =>
      _found(search) && tester.widget<IconButton>(search).onPressed != null;
  // A question heard and answered, or the meeting over without one.
  await _waitUntil(
    tester,
    () =>
        (_found(question) &&
            _found(find.byKey(const Key('multimodal-rag-citation-1')))) ||
        finishedNow(),
    what: 'the meeting',
  );
  if (!_found(question)) {
    _mark('no-question-heard');
    _log('Gemma 4 named no question: "Answer what was just said"');
    await tester.tap(find.byKey(const Key('multimodal-rag-live-menu')));
    await _pause(tester, 600);
    await tester.tap(find.byKey(const Key('multimodal-rag-live-just-said')));
    _mark('fallback');
  } else {
    _mark('question ${_texts(question)}');
  }
  await _screenshot('question');
  await _waitUntil(
    tester,
    () => _found(find.byKey(const Key('multimodal-rag-citation-1'))),
    what: 'the answer',
  );
  _mark('answered');
  await _pause(tester, 1200);
  await _screenshot('answer');
  final answer = _texts(find.byKey(const Key('multimodal-rag-live-answer')));
  _log('answer: $answer');
  expect(answer, contains('26.50'), reason: 'read off the receipt photo');
  await _waitUntil(tester, finishedNow, what: 'the meeting end');
  _mark('meeting-heard');
  await _pause(tester, 2500);

  // The second beat: when did we talk about the kitchen?
  _mark('beat2');
  await tester.tap(find.byKey(const Key('multimodal-rag-meeting-search')));
  await _pause(tester, 700);
  await _type(
    tester,
    find.descendant(
      of: find.byKey(const Key('multimodal-rag-meeting-field')),
      matching: find.byType(EditableText),
    ),
    'When did we talk about the kitchen?',
  );
  await tester.tap(find.byKey(const Key('multimodal-rag-meeting-go')));
  await _waitUntil(
    tester,
    () => _found(find.byKey(const Key('multimodal-rag-live-found'))),
    what: 'the meeting search',
  );
  _mark('found');
  await _pause(tester, 1200);
  await _screenshot('found');
  await _pause(tester, 2300);
  _mark('end');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Multimodal RAG clip: $_clip', (tester) async {
    await ensureMultimodalRagModels(log: _log);
    if (_desktop) await binding.setSurfaceSize(const Size(390, 844));
    await _setUpScreen(tester);
    switch (_clip) {
      case 'search':
        await _searchClip(tester);
      case 'ask':
        await _askClip(tester);
      case 'askvoice':
        await _askVoiceClip(tester);
      case 'live':
        await _liveClip(tester);
      default:
        fail(
          'MULTIMODAL_RAG_CLIP is search, ask, askvoice or live, not $_clip',
        );
    }
  });
}
