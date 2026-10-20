// The Tiny Island voice clips, spoken by macOS `say` voices and converted to
// 16 kHz mono 16-bit WAV (`afconvert`) — the clips
// integration_test/tiny_island_voice_test.dart measures with:
// - every held-out request, every out-of-scope request and every screen-test
//   request (the spoken queries);
// - every example phrasing of every island action (the spoken option
//   examples a decider may learn from).
//
// SYNTHETIC speech (text-to-speech), not human voices. The clips are NOT
// committed: the macOS licence allows its system voices' output for personal,
// non-commercial use only, which a public repository is not. Generate them
// locally (macOS only), then copy the directory into the example app's
// container — the macOS app is sandboxed and reads nothing outside it:
//
//   cd packages/flutter_edge_ai/example
//   dart run integration_test/tools/generate_island_voice_clips.dart <out-dir>
//   mkdir -p ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/island_voice
//   cp <out-dir>/* ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/island_voice/
//
// A clip's file name ends in a hash of its voice and text, so a rerun into the
// same directory keeps the clips it already has and makes only the new ones.
//
// Voices: the English requests are spoken by three English voices (Samantha
// en_US, Daniel en_GB, Karen en_AU), the German ones by Anna (de_DE); the
// screen-test requests by one voice each (Samantha, or Anna for German). The
// option examples are spoken by a fourth English voice that speaks no
// request (Moira en_IE), so a decider that learns from them has never heard
// the voices it is asked in. A voice that is not installed fails the run.
//
// <out-dir>/manifest.tsv — the manifest format: one header line, then one
// line per clip, tab-separated, UTF-8:
//
//   file  set  voice  language  action  text
//
// - file: the WAV's name in <out-dir>;
// - set: held_out (lib/tiny_island/island_held_out_requests.dart),
//   out_of_scope or screen (integration_test/tiny_island_requests.dart), or
//   example (an option example of lib/tiny_island/island_catalog.dart);
// - language: en or de;
// - action: the action id the request means (or the example belongs to);
//   empty when it must abstain (every out_of_scope row, and the screen
//   test's abstentions);
// - text: the request or example, as written in its list.

import 'dart:convert' show utf8;
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter_edge_ai_example/tiny_island/island_catalog.dart';
import 'package:flutter_edge_ai_example/tiny_island/island_held_out_requests.dart';

import '../tiny_island_requests.dart';

const _englishVoices = ['Samantha', 'Daniel', 'Karen'];
const _germanVoice = 'Anna';
const _exampleVoice = 'Moira';

/// `say` runs this many at a time.
const _workers = 4;

typedef _Clip = ({
  String file,
  String set,
  String voice,
  String language,
  String action,
  String text,
});

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'usage: dart run integration_test/tools/'
      'generate_island_voice_clips.dart <out-dir>',
    );
    exit(64);
  }
  if (!Platform.isMacOS) {
    stderr.writeln('needs macOS (say, afconvert)');
    exit(69);
  }
  final out = Directory(args.single)..createSync(recursive: true);

  final installed = (await _run('say', ['-v', '?'])).split('\n');
  for (final voice in [..._englishVoices, _germanVoice, _exampleVoice]) {
    if (!installed.any((line) => line.startsWith('$voice '))) {
      stderr.writeln('macOS voice "$voice" is not installed');
      exit(69);
    }
  }
  final unknownGerman = tinyIslandGermanRequests.difference({
    for (final row in islandHeldOutRequests) row.text,
    ...tinyIslandOutOfScopeRequests,
    for (final c in tinyIslandScreenCases) c.request,
  });
  if (unknownGerman.isNotEmpty) {
    stderr.writeln(
      'tinyIslandGermanRequests names unknown requests: $unknownGerman',
    );
    exit(65);
  }

  final clips = <_Clip>[];
  void add(
    String set,
    String index,
    String text,
    String? action, {
    List<String>? voices,
  }) {
    final german = tinyIslandGermanRequests.contains(text);
    for (final voice
        in german ? const [_germanVoice] : voices ?? _englishVoices) {
      final hash = '${sha1.convert(utf8.encode('$voice\n$text'))}'.substring(
        0,
        8,
      );
      clips.add((
        file: '${set}_${index}_${voice.toLowerCase()}_$hash.wav',
        set: set,
        voice: voice,
        language: german ? 'de' : 'en',
        action: action ?? '',
        text: text,
      ));
    }
  }

  String pad(int i) => i.toString().padLeft(3, '0');
  for (final (i, row) in islandHeldOutRequests.indexed) {
    add('held_out', pad(i), row.text, row.actionId);
  }
  for (final (i, text) in tinyIslandOutOfScopeRequests.indexed) {
    add('out_of_scope', pad(i), text, null);
  }
  for (final (i, c) in tinyIslandScreenCases.indexed) {
    add('screen', pad(i), c.request, c.expect, voices: [_englishVoices.first]);
  }
  for (final (i, action) in buildIslandCatalog().indexed) {
    for (final (j, example) in action.examples.indexed) {
      add(
        'example',
        '${pad(i)}_$j',
        example,
        action.id,
        voices: const [_exampleVoice],
      );
    }
  }

  final todo = [
    for (final clip in clips)
      if (!File('${out.path}/${clip.file}').existsSync()) clip,
  ];
  stdout.writeln(
    '${clips.length} clips, ${clips.length - todo.length} already there',
  );
  final scratch = Directory.systemTemp.createTempSync('island_voice_');
  var done = 0;
  Future<void> worker(int id) async {
    final aiff = '${scratch.path}/clip_$id.aiff';
    while (todo.isNotEmpty) {
      final clip = todo.removeLast();
      await _run('say', ['-v', clip.voice, '-o', aiff, clip.text]);
      await _run('afconvert', [
        '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', //
        aiff, '${out.path}/${clip.file}',
      ]);
      if (++done % 100 == 0) stdout.writeln('$done clips made');
    }
  }

  await Future.wait([for (var i = 0; i < _workers; i++) worker(i)]);
  for (var i = 0; i < _workers; i++) {
    final aiff = File('${scratch.path}/clip_$i.aiff');
    if (aiff.existsSync()) aiff.deleteSync();
  }
  scratch.deleteSync();

  final manifest = StringBuffer('file\tset\tvoice\tlanguage\taction\ttext\n');
  for (final c in clips) {
    for (final field in [c.text, c.action]) {
      if (field.contains('\t') || field.contains('\n')) {
        throw StateError('"$field" cannot be written to a TSV field');
      }
    }
    manifest.writeln(
      [c.file, c.set, c.voice, c.language, c.action, c.text].join('\t'),
    );
  }
  File('${out.path}/manifest.tsv').writeAsStringSync('$manifest');
  stdout.writeln(
    'made $done clips; manifest.tsv lists ${clips.length} in ${out.path}',
  );
}

Future<String> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stderr}',
      result.exitCode,
    );
  }
  return '${result.stdout}';
}
