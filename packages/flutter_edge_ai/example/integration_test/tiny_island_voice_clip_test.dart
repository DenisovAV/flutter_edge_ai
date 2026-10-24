// Tiny Island spoken to, for a demo recording: the REAL screen with
// EmbeddingGemma 2 740M (audio), its mic button held for each prepared clip
// in turn. The microphone is replaced by the clips (a recorder that returns
// the next clip on release), so the video's sound is mixed in afterwards
// from the same files, at the times this test prints:
//
//   [clip] <epoch ms> ready
//   [clip] <epoch ms> press <file>      the mic goes down; the clip starts
//   [clip] <epoch ms> release <file>    held for the clip's length
//   [clip] <epoch ms> decided <file> -> <action or abstained> <score>
//   [clip] <epoch ms> end
//
// The clips: <TINY_ISLAND_CLIP_DIR, default <documents>/island_demo>/
// clips.tsv, tab-separated `file`, `voice`, `text`, `expect` (an action id,
// or empty when the island should shrug), with the WAV files beside it
// (16 kHz mono; e.g. macOS `say` + `afconvert -f WAVE -d LEI16@16000 -c 1`).
// The expected action is printed next to the decision, never asserted: a
// spoken request the Decider declines is a shrug on screen, as in the app.
//
//   flutter test integration_test/tiny_island_voice_clip_test.dart -d <device>
//     --dart-define=TINY_ISLAND_EMBEDDER_MODEL=embeddingGemma2TextVisionAudio740m
//     --dart-define=TINY_ISLAND_EMBEDDER_FILE=<a local copy of that bundle>
//
// On the iOS Simulator pass both as host paths (TINY_ISLAND_CLIP_DIR and
// TINY_ISLAND_EMBEDDER_FILE): `flutter test` installs the app into a new
// data container and removes it at the end, so files copied into the
// container are gone.
//
// Without clips.tsv the test is skipped. No setUp/setUpAll (Rule 6b).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_voice.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_voice_recorder.dart';
import 'package:flutter_edge_ai_example/tiny_island/tiny_island_app_dependencies.dart';
import 'package:flutter_edge_ai_example/tiny_island_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'tiny_island_support.dart';

const _clipDir = String.fromEnvironment('TINY_ISLAND_CLIP_DIR');

void _log(String line) {
  // ignore: avoid_print
  print('[clip] ${DateTime.now().millisecondsSinceEpoch} $line');
}

typedef _Clip = ({String file, String voice, String text, String? expect});

/// Hands the screen the next clip when the mic is let go.
final class _ClipRecorder implements IslandVoiceRecorder {
  Uint8List? next;

  @override
  Future<void> start() async {}

  @override
  Future<Uint8List?> stop() async => next;

  @override
  Future<void> dispose() async {}
}

bool _has(Key key) => find.byKey(key).evaluate().isNotEmpty;

String _text(WidgetTester tester, Key key) =>
    switch (tester.widget(find.byKey(key))) {
      Text(:final data?) => data,
      Text(:final textSpan?) => textSpan.toPlainText(),
      SelectableText(:final data?) => data,
      final widget => '$widget',
    };

/// Pumps frames for [duration] of wall-clock time: the scene animates.
Future<void> _play(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 33));
  }
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration timeout = const Duration(minutes: 6),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > timeout) fail('timed out waiting for $what');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Tiny Island: spoken requests, for a demo recording', (
    tester,
  ) async {
    final dir = _clipDir.isNotEmpty
        ? Directory(_clipDir)
        : Directory(
            '${(await getApplicationDocumentsDirectory()).path}/island_demo',
          );
    final manifest = File('${dir.path}/clips.tsv');
    if (!manifest.existsSync()) {
      markTestSkipped('no clips: ${manifest.path} does not exist');
      return;
    }
    final lines = manifest.readAsLinesSync().where((l) => l.isNotEmpty);
    expect(lines.first, 'file\tvoice\ttext\texpect');
    final clips = <_Clip>[
      for (final line in lines.skip(1))
        switch (line.split('\t')) {
          [final file, final voice, final text, final expect] => (
            file: file,
            voice: voice,
            text: text,
            expect: expect.isEmpty ? null : expect,
          ),
          final cells => throw FormatException('bad clips.tsv row: $cells'),
        },
    ];

    await ensureTinyIslandEmbedder();
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      await binding.setSurfaceSize(const Size(390, 844));
    }
    // Each decision as the view model logs it: two clips of one length get
    // the same label on the HUD, so the HUD alone cannot tell a new turn
    // from the last one.
    final decisions = <String>[];
    final forward = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null && message.startsWith('[TinyIsland] "spoken')) {
        decisions.add(message);
      }
      forward(message, wrapWidth: wrapWidth);
    };
    addTearDown(() => debugPrint = forward);
    final recorder = _ClipRecorder();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark),
        home: TinyIslandScreen(
          dependencies: tinyIslandAppDependencies(recorder: () => recorder),
        ),
      ),
    );
    final watch = Stopwatch()..start();
    await _waitUntil(
      tester,
      () =>
          (_has(const Key('tiny-island-voice')) &&
              _text(
                tester,
                const Key('tiny-island-voice'),
              ).startsWith('Voice: ')) ||
          _has(const Key('tiny-island-error')) ||
          (_has(const Key('tiny-island-voice')) &&
              _text(
                tester,
                const Key('tiny-island-voice'),
              ).startsWith('Voice off')),
      what: 'the voice Decider',
    );
    if (_has(const Key('tiny-island-error'))) {
      fail(
        'the screen failed: ${_text(tester, const Key('tiny-island-error'))}',
      );
    }
    final voice = _text(tester, const Key('tiny-island-voice'));
    _log('status ${_text(tester, const Key('tiny-island-backend'))}');
    _log('voice $voice (${watch.elapsedMilliseconds} ms)');
    expect(voice, startsWith('Voice: '), reason: 'speaking must be on');
    final mic = find.byKey(const Key('tiny-island-mic'));
    await _waitUntil(
      tester,
      () =>
          tester
              .widget<TextField>(find.byKey(const Key('tiny-island-input')))
              .enabled ??
          true,
      what: 'the scene',
    );
    await _play(tester, const Duration(seconds: 2));
    _log('ready');

    var right = 0;
    for (final clip in clips) {
      final wav = File('${dir.path}/${clip.file}').readAsBytesSync();
      final length = islandWavDuration(wav);
      recorder.next = wav;
      final before = decisions.length;
      // The mic button's own handlers, called without a pointer: a real
      // gesture makes the test binding draw a crosshair over the video.
      final at = tester.getCenter(mic);
      tester.widget<Listener>(mic).onPointerDown!(
        PointerDownEvent(position: at),
      );
      _log('press ${clip.file}');
      await _play(tester, length + const Duration(milliseconds: 250));
      tester.widget<Listener>(mic).onPointerUp!(PointerUpEvent(position: at));
      _log('release ${clip.file}');
      await _waitUntil(
        tester,
        () =>
            decisions.length > before ||
            _has(const Key('tiny-island-turn-error')),
        what: 'a decision for ${clip.file}',
        timeout: const Duration(seconds: 60),
      );
      if (decisions.length == before) {
        fail(
          '${clip.file}: '
          '${_text(tester, const Key('tiny-island-turn-error'))}',
        );
      }
      // `"spoken request, 1.4 s" -> climb(tree) cosine 0.800 in 208 ms`, or
      // `-> abstained (belowThreshold) cosine 0.654 ...`.
      final decision = decisions.last;
      final got = RegExp(r'-> (\S+)').firstMatch(decision)!.group(1)!;
      final want = clip.expect ?? 'abstained';
      if (got == want) right++;
      _log(
        'decided ${clip.file} -> $got (want $want) | $decision | '
        '${clip.voice}: "${clip.text}"',
      );
      await _play(tester, const Duration(milliseconds: 3500));
    }
    _log('end: $right of ${clips.length} as expected');
  });
}
