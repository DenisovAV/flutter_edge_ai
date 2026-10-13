// The Multimodal RAG screen's scripted demo: drives the REAL screen, with the real
// models, at a human pace, for a screen recording (about a minute):
//
//   home → Multimodal RAG → index the library (notes by their words, photos by
//   their pixels, voice memos by their sound — nothing transcribed) → type
//   "my flight is delayed" → a VOICE MEMO comes first, and plays → tap "the
//   airport taxi receipt" → a PHOTO comes first → Ask "How much was the
//   airport taxi?" → Gemma 4 reads the amount off the receipt photo and
//   answers, citing it.
//
// It also checks what it shows: the memo and the photo rank first, the answer
// cites its sources, and it prints `[demo]` timing lines.
//
// Models (installed first, a no-op once installed; each becomes the active
// one of its kind):
// - EmbeddingGemma 2 Text + Vision + Audio (740M): --dart-define=
//   MULTIMODAL_RAG_EMBEDDER_FILE=<a local copy> (checked against the catalog's
//   SHA-256), else downloaded (485 MB, ungated);
// - Gemma 4 E2B: MULTIMODAL_RAG_LLM_FILE=<path to gemma-4-E2B-it.litertlm> (keep
//   that file name: it is how the catalog recognizes the model), else
//   downloaded (2.6 GB, ungated).
// Options: MULTIMODAL_RAG_DEMO_PACE=1.5 (slower; 1.0 by default),
// MULTIMODAL_RAG_DEMO_SHOTS=true (PNG screenshots into <documents>/knowledge_shots,
// or MULTIMODAL_RAG_DEMO_SHOTS_DIR — on the iOS Simulator a Mac path survives the
// app, which `flutter test` uninstalls at the end).
//
// Record it:
//   iOS Simulator (CPU there): xcrun simctl boot "iPhone 17 Pro"; then
//     xcrun simctl io booted recordVideo --codec h264 knowledge.mp4 &
//     flutter test integration_test/multimodal_rag_demo_test.dart -d <sim id> \
//       --dart-define=MULTIMODAL_RAG_LLM_FILE=... (a path the simulator can read)
//     and stop the recording (Ctrl-C / kill -INT) when the test passes.
//   Android emulator (arm64): adb push the model files to /data/local/tmp/,
//     adb shell screenrecord --time-limit 180 /sdcard/knowledge.mp4 &
//     flutter test integration_test/multimodal_rag_demo_test.dart -d emulator-5554 \
//       --dart-define=MULTIMODAL_RAG_LLM_FILE=/data/local/tmp/gemma-4-E2B-it.litertlm
//   macOS (phone-sized, 390 x 844, scaled into the window):
//     flutter test integration_test/multimodal_rag_demo_test.dart -d macos ...
//
// No setUp/setUpAll (Rule 6b): the test body provisions first.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_widgets.dart';
import 'package:flutter_edge_ai_example/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'multimodal_rag_models.dart';

const _paceDefine = String.fromEnvironment('MULTIMODAL_RAG_DEMO_PACE');
const _shots = bool.fromEnvironment('MULTIMODAL_RAG_DEMO_SHOTS');
const _shotsDir = String.fromEnvironment('MULTIMODAL_RAG_DEMO_SHOTS_DIR');
const _fresh = bool.fromEnvironment(
  'MULTIMODAL_RAG_DEMO_FRESH',
  defaultValue: true,
);

final double _pace = double.tryParse(_paceDefine) ?? 1.0;

/// Phone-sized on desktop, so screenshots and recordings show the phone
/// layout; the real size on a phone.
const _phone = Size(390, 844);

bool get _desktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

final _shotBoundary = GlobalKey();

void _log(String line) {
  // ignore: avoid_print
  print('[demo] $line');
}

// ── Driving ────────────────────────────────────────────────────────────────

Future<void> _pause(WidgetTester tester, int ms) =>
    tester.pump(Duration(milliseconds: (ms * _pace).round()));

/// Pumps until [done], or fails after [timeout].
Future<Duration> _waitUntil(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration timeout = const Duration(minutes: 3),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > timeout) fail('timed out waiting for $what');
    await tester.pump(const Duration(milliseconds: 100));
  }
  return watch.elapsed;
}

/// Types [text] into [field] a character at a time.
Future<void> _type(WidgetTester tester, Finder field, String text) async {
  await tester.tap(field);
  await _pause(tester, 300);
  for (var i = 1; i <= text.length; i++) {
    await tester.enterText(field, text.substring(0, i));
    await tester.pump(Duration(milliseconds: (55 * _pace).round()));
  }
}

String _textOf(WidgetTester tester, Finder finder) {
  final texts = find.descendant(of: finder, matching: find.byType(Text));
  return [
    for (final element in texts.evaluate())
      (element.widget as Text).data ??
          (element.widget as Text).textSpan?.toPlainText() ??
          '',
  ].join(' | ');
}

int _shot = 0;

Future<void> _screenshot(WidgetTester tester, String name) async {
  if (!_shots) return;
  final boundary =
      _shotBoundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 3);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final directory = await Directory(
    _shotsDir.isNotEmpty
        ? _shotsDir
        : '${(await getApplicationDocumentsDirectory()).path}/knowledge_shots',
  ).create(recursive: true);
  final file = File(
    '${directory.path}/${(++_shot).toString().padLeft(2, '0')}_$name.png',
  );
  await file.writeAsBytes(png!.buffer.asUint8List());
  _log('screenshot ${file.path}');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Every frame the app asks for, so animations play between pumps.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'Multimodal RAG demo: index, find a memo and a photo by text, ask',
    (tester) async {
      await ensureMultimodalRagModels(log: _log, fresh: _fresh);
      if (_desktop) await binding.setSurfaceSize(_phone);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shotBoundary,
          child: const ChatApp(debugBanner: false),
        ),
      );
      final run = Stopwatch()..start();
      await _pause(tester, 1200);

      // Home → Multimodal RAG.
      final card = find.byKey(const Key('home-multimodal-rag'));
      await tester.scrollUntilVisible(
        card,
        300,
        scrollable: find.byType(Scrollable).first,
        duration: const Duration(milliseconds: 400),
      );
      await _pause(tester, 500);
      await tester.tap(card);
      final opened = await _waitUntil(
        tester,
        () => find
            .byKey(const Key('multimodal-rag-tab-search'))
            .evaluate()
            .isNotEmpty,
        what: 'the indexes to open',
      );
      _log('screen ready ${opened.inMilliseconds} ms after the tap');
      await _pause(tester, 1500);
      await _screenshot(tester, 'library');

      // Index the library: notes, photos, memos. Skipped
      // when a kept library is already indexed (MULTIMODAL_RAG_DEMO_FRESH=false).
      final indexButton = find.byKey(const Key('multimodal-rag-index'));
      if (indexButton.evaluate().isNotEmpty) {
        await tester.tap(indexButton);
        await _pause(tester, 1800);
        final library = find.byKey(const Key('multimodal-rag-library'));
        await tester.timedDrag(
          library,
          const Offset(0, -420),
          const Duration(milliseconds: 900),
        );
        await _pause(tester, 1500);
        await tester.timedDrag(
          library,
          const Offset(0, -520),
          const Duration(milliseconds: 900),
        );
        final indexed = await _waitUntil(
          tester,
          () => find
              .byKey(const Key('multimodal-rag-pending'))
              .evaluate()
              .isEmpty,
          what: 'indexing (an item that failed stays pending)',
          // The arm64 emulator embeds about 30x slower than the Mac it runs on.
          timeout: const Duration(minutes: 8),
        );
        _log('indexed ${indexed.inMilliseconds} ms after the scroll');
        await _pause(tester, 1200);
        await _screenshot(tester, 'indexed');
        await tester.timedDrag(
          library,
          const Offset(0, 1400),
          const Duration(milliseconds: 700),
        );
        await _pause(tester, 600);
        expect(
          find.textContaining(RegExp(r'^(\d+) of \1 indexed$')),
          findsOneWidget,
          reason: 'every item indexed',
        );
      }

      // Search: a voice memo, found by what is SAID in it.
      await tester.tap(find.byKey(const Key('multimodal-rag-tab-search')));
      await _pause(tester, 900);
      final field = find.descendant(
        of: find.byKey(const Key('multimodal-rag-search-field')),
        matching: find.byType(EditableText),
      );
      // It searches as it is typed, once typing pauses: no button to press.
      await _type(tester, field, kMultimodalRagSuggestions[0]);
      await _pause(tester, 600);
      await _waitUntil(
        tester,
        () =>
            find
                .byKey(const Key('multimodal-rag-result-0'))
                .evaluate()
                .isNotEmpty &&
            find
                .byKey(const Key('multimodal-rag-search-go'))
                .evaluate()
                .isNotEmpty,
        what: 'the first search',
      );
      await _pause(tester, 1400);
      final first = _textOf(
        tester,
        find.byKey(const Key('multimodal-rag-result-0')),
      );
      _log('"${kMultimodalRagSuggestions[0]}" → $first');
      expect(first, contains('VOICE MEMO'), reason: 'a memo ranks first');
      await _screenshot(tester, 'search_memo');
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('multimodal-rag-result-0')),
          matching: find.byKey(const Key('multimodal-rag-play-memo-flight')),
        ),
      );
      await _pause(tester, 5200); // the memo plays (4.5 s)

      // A photo, found by what is IN it.
      await tester.tap(find.byKey(const Key('multimodal-rag-suggestion-1')));
      await _waitUntil(
        tester,
        () => _textOf(
          tester,
          find.byKey(const Key('multimodal-rag-result-0')),
        ).contains('PHOTO'),
        what: 'the photo search',
      );
      await _pause(tester, 3200);
      _log(
        '"${kMultimodalRagSuggestions[1]}" → '
        '${_textOf(tester, find.byKey(const Key('multimodal-rag-result-0')))}',
      );
      await _screenshot(tester, 'search_photo');

      // Ask: retrieval across the three kinds, then Gemma 4 with the photo.
      await tester.tap(find.byKey(const Key('multimodal-rag-tab-ask')));
      await _pause(tester, 900);
      final ask = find.descendant(
        of: find.byKey(const Key('multimodal-rag-ask-field')),
        matching: find.byType(EditableText),
      );
      await _type(tester, ask, kMultimodalRagQuestions[0]);
      await _pause(tester, 400);
      await tester.tap(find.byKey(const Key('multimodal-rag-ask-send')));
      final answered = await _waitUntil(
        tester,
        () =>
            find
                .byKey(const Key('multimodal-rag-ask-send'))
                .evaluate()
                .isNotEmpty &&
            find
                .byKey(const Key('multimodal-rag-citation-1'))
                .evaluate()
                .isNotEmpty,
        what: 'the answer',
        timeout: const Duration(minutes: 6),
      );
      final answerText = find.byKey(const Key('multimodal-rag-answer-text'));
      final answer = tester
          .widget<Text>(answerText)
          .textSpan!
          .toPlainText(includePlaceholders: false);
      final citations = find.descendant(
        of: answerText,
        matching: find.byWidgetPredicate(
          (w) => w is Text && RegExp(r'^\d+$').hasMatch(w.data ?? ''),
        ),
      );
      _log(
        'answered in ${answered.inMilliseconds} ms, '
        '${citations.evaluate().length} citations: $answer',
      );
      expect(citations, findsWidgets, reason: 'the answer cites its sources');
      await _pause(tester, 4500);
      await _screenshot(tester, 'answer');
      _log('demo ran ${run.elapsed.inSeconds} s');
    },
  );
}
