// FFI openSession sessions on the REAL libLiteRtLm, in the host VM (L3, core
// 2.6.0 design §1.1, §6.4b): the checks of the example's
// litertlm_open_sessions_test.dart where an app cannot be staged — macOS
// keeps another app's container closed to a shell. The integration suite is
// what runs on phones and the desktop VMs.
//
// Opt-in, skipped unless LITERTLM_LLM is set:
// - LITERTLM_LLM=<a .litertlm LLM> (Gemma 4 E2B for the image case);
//   LITERTLM_LLM_TYPE=<ModelType name, default gemma4>;
// - LITERTLM_BACKEND=cpu|gpu (default cpu), LITERTLM_MAX_TOKENS (4096),
//   LITERTLM_MEDIA=1 to run the image case, LITERTLM_SWITCHES (100);
// - a libLiteRtLm with §1-§25 (native-v0.19.0-a), e.g. the L1 build staged
//   in native/litert_lm/prebuilt/macos_arm64/.
//
//   LITERTLM_LLM=…/gemma-4-E2B-it.litertlm LITERTLM_MEDIA=1 \
//     flutter test test/ffi/open_sessions_native_test.dart
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine.dart';
import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine_host.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;
final _modelPath = _env['LITERTLM_LLM'];
final _backend = PreferredBackend.values.byName(
  _env['LITERTLM_BACKEND'] ?? 'cpu',
);
final _maxTokens = int.parse(_env['LITERTLM_MAX_TOKENS'] ?? '4096');
final _media = _env['LITERTLM_MEDIA'] == '1';
final _switches = int.parse(_env['LITERTLM_SWITCHES'] ?? '100');
final _idle = int.parse(_env['LITERTLM_IDLE'] ?? '4');
final _skip = _modelPath == null || !File(_modelPath!).existsSync()
    ? 'LITERTLM_LLM is not set'
    : null;

class _Host extends LiteRtLmEngineHost {
  _Host(this.dir);
  final String dir;
  @override
  Future<String> cacheDir() async => dir;
}

final _log = <String>[];

void _result(String line) =>
    // ignore: avoid_print
    print('RESULT open_sessions/${_backend.name} $line');

Future<String> _ask(InferenceModelSession s, String text) async {
  await s.addQueryChunk(Message(text: text, isUser: true));
  final reply = await s.getResponse();
  // ignore: avoid_print
  print('[open] "${_short(text)}" -> "${_short(reply)}"');
  return reply;
}

String _short(String s) {
  final one = s.replaceAll('\n', ' ');
  return one.length > 80 ? '${one.substring(0, 80)}…' : one;
}

Future<(String, TurnEnd)> _turn(InferenceModelSession s, String text) async {
  await s.addQueryChunk(Message(text: text, isUser: true));
  // ignore: invalid_use_of_protected_member
  final turn = s.startTurn();
  final reply = await turn.text.join();
  final end = await turn.end!;
  // ignore: avoid_print
  print('[open] turn of ${text.length} chars -> $end "${_short(reply)}"');
  return (reply, end);
}

String _mib(num bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

void main() {
  late FfiInferenceModel model;
  late Directory cache;

  setUpAll(() async {
    if (_skip != null) return;
    final printer = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.startsWith('[FfiInferenceModel]')) {
        _log.add(message);
      }
      printer(message, wrapWidth: wrapWidth);
    };
    cache = Directory.systemTemp.createTempSync('open_sessions_');
    debugLiteRtLmEngineHost = _Host(cache.path);
    model =
        await const LiteRtLmEngine().createModel(
              InferenceModelSpec(
                name: 'open-sessions',
                modelSource: FileSource(_modelPath!),
                modelType: ModelType.values.byName(
                  _env['LITERTLM_LLM_TYPE'] ?? 'gemma4',
                ),
                fileType: ModelFileType.litertlm,
              ),
              RuntimeConfig(
                maxTokens: _maxTokens,
                modelPath: _modelPath!,
                preferredBackend: _backend,
                supportImage: _media,
              ),
            )
            as FfiInferenceModel;
  });

  tearDownAll(() async {
    if (_skip != null) return;
    await model.close();
    debugLiteRtLmEngineHost = null;
    cache.deleteSync(recursive: true);
  });

  Future<InferenceModelSession> open() => model.openSession(topK: 1);

  test('the load chose native backing', () {
    _result(
      'backing=${model.openSessionBacking.name} '
      'active=${model.activeBackend?.name} noRewind=${model.noRewindReason} '
      'maxTokens=${model.maxTokens}',
    );
    expect(model.openSessionBacking, OpenSessionBacking.native);
  }, skip: _skip);

  test('three interleaved sessions each recall only their own word', () async {
    final words = ['PELICAN', 'TURNIP', 'GRANITE'];
    final sessions = [for (final _ in words) await open()];
    try {
      for (var i = 0; i < words.length; i++) {
        await _ask(
          sessions[i],
          'Remember this code word: ${words[i]}. Reply with OK only.',
        );
      }
      var passed = 0;
      for (var i = words.length - 1; i >= 0; i--) {
        final reply = (await _ask(
          sessions[i],
          'What is the code word? Answer with the word only.',
        )).toUpperCase();
        final foreign = [
          for (var j = 0; j < words.length; j++)
            if (j != i && reply.contains(words[j])) j,
        ];
        if (reply.contains(words[i]) && foreign.isEmpty) passed++;
      }
      _result('multiconv=$passed/${words.length}');
      expect(passed, words.length);
    } finally {
      for (final s in sessions) {
        await s.close();
      }
    }
  }, skip: _skip);

  test('an image stays in its session across a turn on another', () async {
    final a = await open();
    final b = await open();
    try {
      await a.addQueryChunk(
        Message.withImage(
          text: 'Look at this picture. Reply with OK only.',
          imageBytes: File(
            '../flutter_edge_ai/example/assets/eg2_vision/circle.png',
          ).readAsBytesSync(),
          isUser: true,
        ),
      );
      await a.getResponse();
      await _ask(b, 'Name a fruit. One word.');
      final shape = (await _ask(
        a,
        'What shape is in the picture I showed you? Answer in one word.',
      )).toLowerCase();
      _result('media=${shape.contains('circle') ? 'PASS' : 'FAIL'}');
      expect(shape, contains('circle'));
    } finally {
      await a.close();
      await b.close();
    }
  }, skip: _skip ?? (_media ? null : 'LITERTLM_MEDIA is not 1'));

  test('a stop in one session, a turn on another, and the stopped session '
      'still recalls its turns', () async {
    _log.clear();
    final a = await open();
    final b = await open();
    try {
      await _ask(a, 'My name is Zorblax. Greet me in five words.');
      await a.addQueryChunk(
        const Message(
          text:
              'Write a long story about the sea, at least ten paragraphs. By '
              'the way, my favourite colour is purple.',
          isUser: true,
        ),
      );
      var chunks = 0;
      await for (final _ in a.getResponseAsync()) {
        if (++chunks == 1) await a.stopGeneration();
      }
      await _ask(b, 'Name a colour of the sky. One word.');
      final colour = (await _ask(
        a,
        'What is my favourite colour? One word.',
      )).toLowerCase();
      final name = (await _ask(
        a,
        'What is my name? Answer with the name only.',
      )).toLowerCase();
      final rewound = _log.where((l) => l.contains('rewound the conversation'));
      final rebuilt = _log.where((l) => l.contains('rebuilt the conversation'));
      final ended = _log.where((l) => l.contains('ended natively before'));
      expect(
        ended,
        isEmpty,
        reason: 'the stop must reach a running turn to test its recovery',
      );
      _result(
        'stoprewind colour=${colour.contains('purple')} '
        'name=${name.contains('zorblax')} rewound=${rewound.length} '
        'rebuilt=${rebuilt.length}',
      );
      expect(name, contains('zorblax'));
      expect(colour, contains('purple'));
      if (model.noRewindReason == null) {
        expect(rewound, hasLength(1));
        expect(rebuilt, isEmpty);
      } else {
        expect(rebuilt, hasLength(1));
      }
    } finally {
      await a.close();
      await b.close();
    }
  }, skip: _skip);

  test('a full context ends contextLimit, the session answers again, and '
      'nothing of its history is dropped', () async {
    final s = await open();
    try {
      await _ask(s, 'My name is Zorblax. Reply with OK only.');
      final tooLong = List.filled(model.maxTokens + 200, 'lorem').join(' ');
      final (_, endTooLong) = await _turn(s, 'Summarise: $tooLong');
      expect(endTooLong, TurnEnd.contextLimit);
      final name1 = (await _ask(
        s,
        'What is my name? Answer with the name only.',
      )).toLowerCase();
      expect(name1, contains('zorblax'));

      final chunk = List.filled(300, 'blue').join(' ');
      TurnEnd? end;
      var turns = 0;
      while (turns < 40) {
        turns++;
        (_, end) = await _turn(s, 'Reply with OK only. $chunk');
        if (end == TurnEnd.contextLimit) break;
      }
      expect(end, TurnEnd.contextLimit, reason: 'the window never filled');
      // Then smaller inputs, until even those do not fit: what is left is
      // then below the bundle's smallest prefill signature.
      final small = List.filled(40, 'blue').join(' ');
      for (var i = 0; i < 80; i++) {
        turns++;
        (_, end) = await _turn(s, 'Reply with OK only. $small');
        if (end == TurnEnd.contextLimit) break;
      }
      final (shortReply, shortEnd) = await _turn(s, 'What is my name?');
      TurnEnd? again;
      if (shortEnd == TurnEnd.contextLimit) {
        (_, again) = await _turn(s, 'Hi');
      }
      _result(
        'contextfull tooLong=$endTooLong recalled=${name1.contains('zorblax')} '
        'filledAfter=$turns short=$shortEnd again=$again',
      );
      if (shortEnd == TurnEnd.contextLimit) {
        expect(again, TurnEnd.contextLimit);
      } else {
        expect(shortReply.toLowerCase(), contains('zorblax'));
      }
    } finally {
      await s.close();
    }
  }, skip: _skip);

  test('measures the memory one idle open session adds, and drift over '
      'switches (RESULT lines, no assertion)', () async {
    final first = await open();
    await _ask(first, 'Reply with OK only.');
    final base = ProcessInfo.currentRss;
    final extra = _idle;
    final idle = <InferenceModelSession>[];
    final deltas = <int>[];
    var previous = base;
    try {
      for (var i = 0; i < extra; i++) {
        final s = await open();
        idle.add(s);
        await _ask(s, 'Reply with OK only.');
        await _ask(first, 'Reply with OK only.');
        final now = ProcessInfo.currentRss;
        deltas.add(now - previous);
        previous = now;
      }
      _result(
        'idle_session_rss_mib=${_mib((previous - base) / extra)} '
        'maxTokens=${model.maxTokens} deltas_mib=${deltas.map(_mib).join(',')}',
      );
      final b = idle.first;
      final before = ProcessInfo.currentRss;
      final sw = Stopwatch()..start();
      for (var i = 0; i < _switches; i++) {
        await _ask(i.isEven ? first : b, 'Reply with OK only.');
        if ((i + 1) % 50 == 0) {
          debugPrint(
            '[open] after ${i + 1} switches: '
            '${_mib(ProcessInfo.currentRss - before)} MiB',
          );
        }
      }
      _result(
        'switches=$_switches turn_ms='
        '${(sw.elapsedMilliseconds / _switches).toStringAsFixed(0)} '
        'drift_rss_mib=${_mib(ProcessInfo.currentRss - before)}',
      );
    } finally {
      for (final s in idle) {
        await s.close();
      }
      await first.close();
    }
  }, skip: _skip);
}
